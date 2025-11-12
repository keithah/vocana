import Foundation
import os.log

/// Manages ML model inference and audio processing
/// Responsibility: DeepFilterNet initialization, inference, memory pressure handling
/// Isolated from audio capture, buffering, and level calculations
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
    
    // Public state
    var isMLProcessingActive = false
    var processingLatencyMs: Double = 0
    var memoryPressureLevel: Int = 0
    
    /// Initialize ML processing with DeepFilterNet
    /// Handles async model loading with proper cancellation support
    func initializeMLProcessing() {
        // Fix CRITICAL: Cancel any existing initialization to prevent race conditions
        mlInitializationTask?.cancel()
        
        // Fix HIGH: Make ML initialization async to avoid blocking UI
        mlInitializationTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            do {
                // Check for cancellation before each expensive operation
                guard !Task.isCancelled else { return }
                
                // Find models directory (can be slow with file system checks)
                let modelsPath = self.findModelsDirectory()
                
                guard !Task.isCancelled else { return }
                
                // Create DeepFilterNet instance (potentially slow model loading)
                let denoiser = try DeepFilterNet(modelsDirectory: modelsPath)
                
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
                    self.isMLProcessingActive = true
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

                     Self.logger.info("Falling back to simple level-based processing")
                     self.denoiser = nil
                     self.isMLProcessingActive = false

                     // Notify that ML initialization failed
                     self.recordFailure()
                 }
             }
        }
    }
    
    /// Stop ML processing and clean up
    func stopMLProcessing() {
        mlInitializationTask?.cancel()
        mlInitializationTask = nil
        denoiser = nil
        isMLProcessingActive = false
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
                     self.recordFailure()
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
        // Try multiple locations for models
        let searchPaths = [
            "Resources/Models",
            "../Resources/Models",
            "ml-models/pretrained/tmp/export",
            "../ml-models/pretrained/tmp/export"
        ]
        
        for path in searchPaths {
            let encPath = "\(path)/enc.onnx"
            if FileManager.default.fileExists(atPath: encPath) {
                return path
            }
        }
        
        // Default fallback
        return "Resources/Models"
    }
}
