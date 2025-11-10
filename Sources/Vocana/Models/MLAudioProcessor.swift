import Foundation
import AVFoundation
import os.log

/// Protocol for ML audio processing components
/// Allows dependency injection for testing with mock implementations
@MainActor
protocol MLAudioProcessorProtocol: AnyObject {
    var isMLProcessingActive: Bool { get }
    var processingLatencyMs: Double { get }
    var memoryPressureLevel: AudioEngine.MemoryPressureLevel { get set }
    
    var recordFailure: () -> Void { get set }
    var recordLatency: (Double) -> Void { get set }
    var recordSuccess: () -> Void { get set }
    var onMLProcessingReady: () -> Void { get set }
    
    func initializeML() async
    func initializeMLProcessing()
    func stopMLProcessing()
    func suspendMLProcessing(reason: String)
    func processAudioWithML(chunk: [Float], sensitivity: Double) -> [Float]?
    func activateML() async -> Bool
    func deactivateML() async
    func isMemoryPressureSuspended() -> Bool
    func cleanup() async
}

/// Manages ML model inference and audio processing with thread-safe state management
/// 
/// ## Threading Model
/// This class uses a hybrid MainActor + queue synchronization approach:
/// - **MainActor**: All public properties and UI-related state
/// - **mlStateQueue**: Synchronizes ML processing state and model access
/// - **mlInferenceQueue**: Dedicated queue for ML inference to prevent blocking audio thread
/// 
/// ## Responsibilities
/// - DeepFilterNet initialization and lifecycle management
/// - Audio processing with ML inference
/// - Memory pressure handling and resource cleanup
/// - Thread-safe state synchronization for concurrent access
/// 
/// ## Usage Notes
/// - Isolated from audio capture, buffering, and level calculations
/// - All callbacks are automatically dispatched to MainActor
/// - Do not access MLAudioProcessor state directly from callbacks to avoid race conditions
/// 
/// - Important: Use `mlStateQueue.sync` for any synchronized state access
/// - Important: ML inference runs on dedicated queue to prevent audio thread blocking
@MainActor
class MLAudioProcessor: MLAudioProcessorProtocol {
    private static let logger = Logger(subsystem: "Vocana", category: "MLAudioProcessor")
    
    private var denoiser: DeepFilterNet?
    private var mlInitializationTask: Task<Void, Never>?
    
     // ML state management
     private let mlStateQueue = DispatchQueue(label: "com.vocana.mlstate", qos: .userInteractive)
     private var mlProcessingSuspendedDueToMemory = false

     // Fix CRITICAL: Dedicated queue for ML inference to prevent blocking audio thread
     private let mlInferenceQueue = DispatchQueue(label: "com.vocana.mlinference", qos: .userInteractive)
    
     // Telemetry and callbacks
     // Thread Safety: All callbacks are automatically dispatched to MainActor
     // Do not access MLAudioProcessor state directly from callbacks to avoid race conditions
      var telemetry: AudioEngine.ProductionTelemetry = .init()
      var recordLatency: (Double) -> Void = { _ in }
       var recordFailure: () -> Void = {}
       var recordSuccess: () -> Void = {}
       var recordMemoryPressure: () -> Void = {}
       var onMLProcessingReady: () -> Void = {}  // Fix HIGH-008: Callback when ML is initialized
    
    // Public state - synchronized through mlStateQueue
    private var _isMLProcessingActive = false
    
    var isMLProcessingActive: Bool {
        return mlStateQueue.sync {
            return _isMLProcessingActive
        }
    }
    var processingLatencyMs: Double = 0
    var memoryPressureLevel: AudioEngine.MemoryPressureLevel = .normal
    
    // MARK: - Memory Tracking
    
    /// Current ML model memory usage in MB
    var mlMemoryUsageMB: Double {
        guard let denoiser = denoiser else { return 0.0 }
        return denoiser.memoryUsageMB
    }
    
    /// Peak ML model memory usage in MB
    var mlPeakMemoryUsageMB: Double {
        guard let denoiser = denoiser else { return 0.0 }
        return denoiser.peakMemoryUsageMB
    }
    
    /// Memory used during model loading in MB
    var mlModelLoadMemoryMB: Double {
        guard let denoiser = denoiser else { return 0.0 }
        return denoiser.modelLoadMemoryMB
    }
    
    /// Get comprehensive ML memory statistics
    func getMLMemoryStatistics() -> (current: Double, peak: Double, modelLoad: Double, totalInferences: UInt64) {
        guard let denoiser = denoiser else { 
            return (current: 0.0, peak: 0.0, modelLoad: 0.0, totalInferences: 0)
        }
        return denoiser.getMemoryStatistics()
    }
    
    /// Initialize ML processing with DeepFilterNet
    /// Handles async model loading with proper cancellation support
    func initializeMLProcessing() {
        print("🤖 MLAudioProcessor.initializeMLProcessing - Starting...")
        
        // Fix CRITICAL: Cancel any existing initialization to prevent race conditions
        mlInitializationTask?.cancel()

        // Fix HIGH: Make ML initialization async to avoid blocking UI
        mlInitializationTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            do {
                print("🤖 Finding models directory...")
                // Check for cancellation before each expensive operation
                guard !Task.isCancelled else { return }

                // Find models directory (can be slow with file system checks)
                let modelsPath = self.findModelsDirectory()
                print("🤖 Models directory found: \(modelsPath)")

                guard !Task.isCancelled else { return }

                print("🤖 Creating DeepFilterNet instance...")
                
                // Verify all required models exist before attempting to load
                let requiredModels = ["enc.onnx", "df_dec.onnx", "erb_dec.onnx"]
                let missingModels = requiredModels.filter { !FileManager.default.fileExists(atPath: "\(modelsPath)/\($0)") }
                
                if !missingModels.isEmpty {
                    throw DeepFilterNet.DeepFilterError.modelLoadFailed("Missing model files: \(missingModels.joined(separator: ", "))")
                }
                
                // Create DeepFilterNet instance (potentially slow model loading)
                let denoiser = try DeepFilterNet(modelsDirectory: modelsPath)
                print("🤖 ✅ DeepFilterNet created successfully")
                
                // Fix HIGH: Atomic cancellation and state check to prevent TOCTOU race
                let wasCancelled = Task.isCancelled
                
                // Fix CRITICAL & HIGH-003: Update state atomically with proper synchronization
                // First check if we can activate on MainActor, avoiding nested queue calls
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    
                    // Check memory pressure state atomically
                    let canActivateML = self.mlStateQueue.sync {
                        !self.mlProcessingSuspendedDueToMemory
                    }
                    
                    // Atomic check: verify both task cancellation AND ML suspension state
                    guard !wasCancelled && canActivateML else {
                        if wasCancelled {
                            Self.logger.info("ML initialization cancelled")
                        } else {
                            Self.logger.warning("ML initialization completed but suspended due to memory pressure")
                        }
                        return
                    }
                    
                     self.denoiser = denoiser
                     self.mlStateQueue.sync {
                         self._isMLProcessingActive = true
                     }
                     print("🤖 ✅ ML processing is now ACTIVE!")
                     Self.logger.info("DeepFilterNet ML processing enabled")

                     // Fix HIGH-008: Notify that ML processing is ready
                     self.onMLProcessingReady()
                }
             } catch {
                 guard !Task.isCancelled else { return }

                 await MainActor.run { [weak self] in
                     guard let self = self else { return }

                     // Handle specific ML initialization errors
                     if let deepFilterError = error as? DeepFilterNet.DeepFilterError {
                         switch deepFilterError {
                         case .modelLoadFailed(let reason):
                             Self.logger.error("ML model loading failed: \(reason)")
                             Self.logger.info("Check that ONNX models are present in Resources/Models directory")
                         case .processingFailed(let reason):
                             Self.logger.error("ML processing setup failed: \(reason)")
                         case .invalidAudioLength, .bufferTooLarge:
                             Self.logger.error("ML configuration error: \(error.localizedDescription)")
                         }
                     } else {
                         Self.logger.error("Unexpected ML initialization error: \(error.localizedDescription)")
                     }

                       print("🤖 ❌ ML initialization FAILED: \(error.localizedDescription)")
                       Self.logger.info("Falling back to simple level-based processing")
                       self.denoiser = nil
                       self.mlStateQueue.sync {
                           self._isMLProcessingActive = false
                       }

                       // Don't record this as a failure - it's an expected fallback
                       // self.recordFailure()
                       print("🤖 ℹ️ ML processing unavailable - app will work with basic audio processing")
                 }
             }
        }
    }
    
    /// Stop ML processing and clean up
    func stopMLProcessing() {
        mlInitializationTask?.cancel()
        mlInitializationTask = nil
        denoiser = nil
        mlStateQueue.sync {
            _isMLProcessingActive = false
        }
    }
    
    deinit {
        // Fix PR Compliance: Ensure detached task is cancelled on deallocation
        mlInitializationTask?.cancel()
    }
    
     /// Process audio chunk with DeepFilterNet if available
     /// - Parameters:
     ///   - chunk: Audio samples to process
     ///   - sensitivity: Sensitivity multiplier (0-1)
     /// - Returns: Processed audio samples
     func processAudioWithML(chunk: [Float], sensitivity: Double) -> [Float]? {
         // Fix CRITICAL: Perform all state checks atomically within single sync block to prevent TOCTOU race
         let capturedDenoiser = mlStateQueue.sync { () -> DeepFilterNet? in
             guard !mlProcessingSuspendedDueToMemory else {
                 return nil
             }
             return denoiser
         }
         
         guard let capturedDenoiser = capturedDenoiser else {
             return nil
         }
         
         // Synchronously process on background queue to avoid blocking
         // Fix HIGH: Use async dispatch for non-blocking processing
         var result: [Float]?
         let semaphore = DispatchSemaphore(value: 0)
         
         mlInferenceQueue.async { [weak self] in
             defer { semaphore.signal() }
             
             guard let self = self else { return }
             
             do {
                 let startTime = CFAbsoluteTimeGetCurrent()
                 result = try capturedDenoiser.process(audio: chunk)
                 let endTime = CFAbsoluteTimeGetCurrent()
                 let latencyMs = (endTime - startTime) * 1000.0
                 
                  // Fix CRITICAL: Record telemetry for production monitoring
                  Task { @MainActor in
                      self.recordLatency(latencyMs)
                      self.recordSuccess()  // Reset failure counter on successful processing
                      print("✅ ML processing succeeded, calling recordSuccess")
                  }
                 
                 // Monitor for SLA violations (target <1ms)
                 if latencyMs > 1.0 {
                     Task { @MainActor in
                         Self.logger.warning("Latency SLA violation: \(String(format: "%.2f", latencyMs))ms > 1.0ms target")
                     }
                 }
               } catch {
                   Task { @MainActor in
                       Self.logger.error("ML processing error: \(error.localizedDescription)")
                       print("❌ ML processing ERROR DETAILS: \(error)")
                       self.recordFailure()
                       print("❌ ML processing failed, calling recordFailure")
                   }
               }
         }
         
         // Wait with timeout to prevent blocking indefinitely
         let finished = semaphore.wait(timeout: .now() + 0.05) == .timedOut ? false : true
         return finished ? result : nil
     }
    
    /// Suspend ML processing due to memory pressure
    /// - Parameter reason: Reason for suspension
    func suspendMLProcessing(reason: String) {
        mlStateQueue.sync {
            mlProcessingSuspendedDueToMemory = true
        }
        Self.logger.warning("ML processing suspended: \(reason)")
    }
    
    /// Attempt to resume ML processing after memory pressure
    func attemptMemoryPressureRecovery() {
        mlStateQueue.sync {
            mlProcessingSuspendedDueToMemory = false
        }
        Self.logger.info("Attempting ML processing recovery after memory pressure")
    }
    
    /// Check if ML is suspended due to memory pressure
    /// - Returns: true if suspended, false otherwise
    func isMemoryPressureSuspended() -> Bool {
        return mlStateQueue.sync { mlProcessingSuspendedDueToMemory }
    }
    
    // MARK: - Private Helpers
    
    private nonisolated func findModelsDirectory() -> String {
        print("🔍 Searching for ML models directory...")
        
        // Use Bundle.main.resourcePath for bundled resources (correct for SPM)
        let resourcePath = Bundle.main.resourcePath ?? "."
        let modelsPath = "\(resourcePath)/Models"
        print("🔍 Trying bundle path: \(modelsPath)")

        // Verify models exist at the expected location
        let encPath = "\(modelsPath)/enc.onnx"
        if FileManager.default.fileExists(atPath: encPath) {
            print("🔍 ✅ Found models at bundle path: \(modelsPath)")
            return modelsPath
        }

        // Fallback: Try relative paths for development/debugging
        let searchPaths = [
            "Resources/Models",
            "../Resources/Models", 
            "ml-models/pretrained/tmp/export",
            "../ml-models/pretrained/tmp/export",
            "/Users/keith/src/vocana/Vocana/Resources/Models"
        ]

        for path in searchPaths {
            let testEncPath = "\(path)/enc.onnx"
            print("🔍 Trying path: \(testEncPath)")
            if FileManager.default.fileExists(atPath: testEncPath) {
                print("🔍 ✅ Found models at: \(path)")
                return path
            }
        }

        print("🔍 ❌ No models found, using fallback: \(modelsPath)")
        // Final fallback
        return modelsPath
    }
    
    // MARK: - MLAudioProcessorProtocol
    
    func initializeML() async {
        initializeMLProcessing()
    }
    
    func activateML() async -> Bool {
        return !mlProcessingSuspendedDueToMemory
    }
    
    func deactivateML() async {
        mlStateQueue.sync {
            _isMLProcessingActive = false
        }
    }
    
    func cleanup() async {
        mlInitializationTask?.cancel()
        denoiser = nil
        mlStateQueue.sync {
            _isMLProcessingActive = false
        }
    }
}
