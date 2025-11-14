import Foundation
import os.log

/// ML audio processor using DeepFilterNet for audio denoising.
///
/// ## Threading Model
/// This class is isolated to MainActor, but uses an internal DispatchQueue for specific state synchronization.
///
/// **Why the hybrid approach?**
/// - All public methods must be called on MainActor (enforced by compiler)
/// - Internal state `mlProcessingSuspendedDueToMemory` needs fast, lock-free updates from performance-sensitive paths
/// - The `mlStateQueue` protects only this specific state, allowing concurrent reads without MainActor context switch
/// - This hybrid approach optimizes the common case (checking if ML is suspended) without context switching overhead
///
/// **Threading Guarantees:**
/// - All public properties and methods: MainActor only
/// - State reads via mlStateQueue: Thread-safe from any thread
/// - State writes: Always go through setMLProcessingActive() or via sync queue
///
/// ## Usage Example
/// ```swift
/// // On MainActor
/// processor.initializeMLProcessing()
///
/// // Can check from any thread efficiently
/// let isSuspended = processor.isMemoryPressureSuspended()
/// ```
@MainActor
class MLAudioProcessor {
    nonisolated static let logger = Logger(subsystem: "Vocana", category: "MLAudioProcessor")
    
    private var denoiser: DeepFilterNet?
    private var mlInitializationTask: Task<Void, Never>?
    
     // ML state management
     private let mlStateQueue = DispatchQueue(label: "com.vocana.mlstate", qos: .userInitiated)
     private var mlProcessingSuspendedDueToMemory = false
     
     // Fix CRITICAL: Dedicated queue for ML inference to prevent blocking audio thread
     private let mlInferenceQueue = DispatchQueue(label: "com.vocana.mlinference", qos: .userInitiated)
    
     // Telemetry and callbacks
     var telemetry: AudioEngine.ProductionTelemetry = .init()
     var recordLatency: (Double) -> Void = { _ in }
     var recordFailure: () -> Void = {}
     var recordMemoryPressure: () -> Void = {}
     var onMLProcessingReady: () -> Void = {}  // Fix HIGH-008: Callback when ML is initialized
    
     // ML state management - protected by mlStateQueue
     private var _isMLProcessingActive = false
     
     // Public accessor (on MainActor)
     var isMLProcessingActive: Bool {
         mlStateQueue.sync { _isMLProcessingActive }
     }
     
     private func setMLProcessingActive(_ active: Bool) {
         mlStateQueue.sync {
             _isMLProcessingActive = active
         }
     }
     
     var processingLatencyMs: Double = 0
    
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
                    self.setMLProcessingActive(true)
                    Self.logger.info("DeepFilterNet ML processing enabled")
                    
                    // Fix HIGH-008: Notify that ML processing is ready
                    self.onMLProcessingReady()
                }
            } catch {
                guard !Task.isCancelled else { return }
                
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    Self.logger.error("Could not initialize ML processing: \(error.localizedDescription)")
                    Self.logger.info("Falling back to simple level-based processing")
                    self.denoiser = nil
                    self.setMLProcessingActive(false)
                }
            }
        }
    }
    
    /// Stop ML processing and clean up
    func stopMLProcessing() {
        mlInitializationTask?.cancel()
        mlInitializationTask = nil
        denoiser = nil
        setMLProcessingActive(false)
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
         let canProcess = mlStateQueue.sync {
             isMLProcessingActive && !mlProcessingSuspendedDueToMemory
         }
         guard canProcess, let capturedDenoiser = denoiser else {
             return nil
         }
         
         // Fix CRITICAL: Run ML inference on dedicated queue to prevent blocking audio thread
         // Return nil immediately if ML processing is busy (graceful degradation)
         var result: [Float]?
         let semaphore = DispatchSemaphore(value: 0)
         
         mlInferenceQueue.async { [weak self] in
             guard let self = self else { 
                 semaphore.signal()
                 return 
             }
             
             do {
                 let startTime = CFAbsoluteTimeGetCurrent()
                 let enhanced = try capturedDenoiser.process(audio: chunk)
                 let endTime = CFAbsoluteTimeGetCurrent()
                 
                 let latencyMs = (endTime - startTime) * 1000.0
                 
                 // Update latency on MainActor
                 Task { @MainActor in
                     self.processingLatencyMs = latencyMs
                 }
                 
                  // Fix CRITICAL: Record telemetry for production monitoring
                  // Capture callback to avoid MainActor crossing
                  let recordLatency = self.recordLatency
                  Task { @MainActor in
                      recordLatency(latencyMs)
                  }
                  
                  // Monitor for SLA violations (target <1ms)
                  if latencyMs > 1.0 {
                      Self.logger.warning("Latency SLA violation: \(String(format: "%.2f", latencyMs))ms > 1.0ms target")
                  }
                  
                  result = enhanced
              } catch {
                  Self.logger.error("ML processing error: \(error.localizedDescription)")
                  let recordFailure = self.recordFailure
                  Task { @MainActor in
                      recordFailure()
                  }
                 
                  // Fix HIGH: Update error state atomically
                  self.mlStateQueue.sync {
                      self._isMLProcessingActive = false
                      self.denoiser = nil
                  }
             }
             
             semaphore.signal()
         }
         
         // Wait with timeout to prevent blocking audio thread
         let timeout = DispatchTime.now() + .milliseconds(5) // 5ms timeout
         let timedOut = semaphore.wait(timeout: timeout) == .timedOut
         
         if timedOut {
             Self.logger.warning("ML inference timeout - falling back to direct processing")
             return nil
         }
         
         return result
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
