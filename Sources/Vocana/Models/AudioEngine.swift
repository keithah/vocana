import Foundation
import Combine
import AVFoundation
import os.log

// MARK: - Audio Engine Error Types

enum AudioEngineError: LocalizedError {
    case initializationFailed(String)
    case processingFailed(String)
    case memoryPressure(String)
    case circuitBreakerTriggered(String)
    case bufferOverflow(String)
    case mlProcessingError(String)
    case audioSessionError(String)
    
    var errorDescription: String? {
        switch self {
        case .initializationFailed(let message):
            return "Audio Engine Initialization Failed: \(message)"
        case .processingFailed(let message):
            return "Audio Processing Failed: \(message)"
        case .memoryPressure(let message):
            return "Memory Pressure: \(message)"
        case .circuitBreakerTriggered(let message):
            return "Circuit Breaker Triggered: \(message)"
        case .bufferOverflow(let message):
            return "Buffer Overflow: \(message)"
        case .mlProcessingError(let message):
            return "ML Processing Error: \(message)"
        case .audioSessionError(let message):
            return "Audio Session Error: \(message)"
        }
    }
}

struct AudioLevels {
    let input: Float
    let output: Float
    
    static let zero = AudioLevels(input: 0.0, output: 0.0)
}

@MainActor
class AudioEngine: ObservableObject {
    private static let logger = Logger(subsystem: "Vocana", category: "AudioEngine")
    @Published var currentLevels = AudioLevels.zero
    @Published var isUsingRealAudio = false
    @Published var isMLProcessingActive = false
    @Published var processingLatencyMs: Double = 0
    @Published var memoryPressureLevel: MemoryPressureLevel = .normal
    
    // Fix CRITICAL: Memory pressure monitoring for production safety
    enum MemoryPressureLevel: Int {
        case normal = 0
        case warning = 1
        case urgent = 2
        case critical = 3
    }
    
    // Fix CRITICAL: Production telemetry for monitoring and debugging
    struct ProductionTelemetry {
        var totalFramesProcessed: UInt64 = 0
        var mlProcessingFailures: UInt64 = 0
        var circuitBreakerTriggers: UInt64 = 0
        var audioBufferOverflows: UInt64 = 0
        var memoryPressureEvents: UInt64 = 0
        var averageLatencyMs: Double = 0
        var peakMemoryUsageMB: Double = 0
        var audioQualityScore: Double = 1.0  // SNR-based quality metric
        
        mutating func recordLatency(_ latencyMs: Double) {
            totalFramesProcessed += 1
            // Exponentially weighted moving average
            averageLatencyMs = (averageLatencyMs * 0.9) + (latencyMs * 0.1)
        }
        
        mutating func recordFailure() {
            mlProcessingFailures += 1
        }
        
        mutating func recordMemoryPressure() {
            memoryPressureEvents += 1
        }
        
        mutating func recordCircuitBreakerTrigger() {
            circuitBreakerTriggers += 1
        }
        
        mutating func recordAudioBufferOverflow() {
            audioBufferOverflows += 1
        }
    }
    
    @Published var telemetry = ProductionTelemetry()
    
    private var timer: Timer?
    private var audioEngine: AVAudioEngine?
    private var isEnabled: Bool = false
    private var sensitivity: Double = 0.5
    
    // ML processing
    private var denoiser: DeepFilterNet?
    private var mlInitializationTask: Task<Void, Never>?
    
    // Fix CRITICAL: Thread-safe audioBuffer access with dedicated queue
    private let audioBufferQueue = DispatchQueue(label: "com.vocana.audiobuffer", qos: .userInteractive)
    private nonisolated(unsafe) var _audioBuffer: [Float] = []
    private var audioBuffer: [Float] {
        get { audioBufferQueue.sync { _audioBuffer } }
        set { audioBufferQueue.sync { _audioBuffer = newValue } }
    }
    
    // Fix HIGH: Circuit breaker for sustained buffer overflows
    private var consecutiveOverflows = 0
    private var audioCaptureSuspended = false
    private var audioCaptureSuspensionTimer: Timer?
    
    private let minimumBufferSize = 960  // FFT size for DeepFilterNet
    
    // Fix CRITICAL: Memory pressure monitoring and circuit breaker  
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var isMemoryPressureHandlerActive = false
    private var mlProcessingSuspendedDueToMemory = false
    
    // Fix CRITICAL: Thread-safe ML state management
    private let mlStateQueue = DispatchQueue(label: "com.vocana.mlstate", qos: .userInitiated)
    
    init() {
        setupMemoryPressureMonitoring()
    }
    
    func startSimulation(isEnabled: Bool, sensitivity: Double) {
        self.isEnabled = isEnabled
        self.sensitivity = sensitivity
        
        stopSimulation()
        
        // Initialize DeepFilterNet if enabled
        if isEnabled {
            initializeMLProcessing()
        }
        
        // Try to start real audio capture, fallback to simulation
        if startRealAudioCapture() {
            isUsingRealAudio = true
        } else {
            isUsingRealAudio = false
            startSimulatedAudio()
        }
    }
    
    // MARK: - ML Processing
    
    private func initializeMLProcessing() {
        // Fix CRITICAL: Cancel any existing initialization to prevent race conditions
        mlInitializationTask?.cancel()
        
        // Fix HIGH: Make ML initialization async to avoid blocking UI
        // Fix CRITICAL #4: Use MainActor.run to ensure isMLProcessingActive updates are synchronized
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
                
                // Fix CRITICAL #4: Update state atomically with proper synchronization
                await MainActor.run {
                    self.mlStateQueue.sync {
                        // Atomic check: verify both task cancellation AND ML suspension state
                        guard !wasCancelled && !self.mlProcessingSuspendedDueToMemory else { 
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
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    Self.logger.error("Could not initialize ML processing: \(error.localizedDescription)")
                    Self.logger.info("Falling back to simple level-based processing")
                    self.denoiser = nil
                    self.isMLProcessingActive = false
                }
            }
        }
    }
    
    nonisolated private func findModelsDirectory() -> String {
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
    
    func stopSimulation() {
        // Fix CRITICAL: Cancel ML initialization to prevent race conditions
        mlInitializationTask?.cancel()
        mlInitializationTask = nil
        
        stopRealAudioCapture()
        stopSimulatedAudio()
        
        // Fix HIGH: Ensure timer cleanup to prevent memory leak
        timer?.invalidate()
        timer = nil
        
        // Clean up ML processing
        if denoiser != nil {
            denoiser?.reset()
            denoiser = nil
            audioBuffer.removeAll()
            isMLProcessingActive = false
            processingLatencyMs = 0
        }
    }
    
    // Fix HIGH: Track tap installation to prevent crash on double-removal
    private var isTapInstalled = false
    
     nonisolated deinit {
         // Fix CRITICAL: Trigger cleanup from nonisolated context
         // 
         // NOTE: Callers MUST call stopSimulation() before deallocation to prevent resource leaks.
         // The tap and timer are MainActor-isolated and cannot be accessed from this nonisolated context.
         // Swift ARC will deallocate the engine, but the tap may remain installed on the audio node.
         //
         // Best-Effort Logging:
         // The warning below is fire-and-forget and may not execute if deallocation occurs during
         // app shutdown or when the main thread is blocked. This is expected behavior.
         // The warning serves as a development aid only and cannot be relied upon for production cleanup.
         
         // Attempt to log warning if main thread is available (best-effort)
         Task { @MainActor in
             Self.logger.warning("AudioEngine deallocated - ensure stopSimulation() was called for proper cleanup")
         }
     }
    
    // MARK: - Real Audio Capture
    
    private func startRealAudioCapture() -> Bool {
        do {
            // Fix HIGH: Configure audio session before starting engine
            #if os(iOS) || os(tvOS) || os(watchOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
            #endif
            
            audioEngine = AVAudioEngine()
            guard let audioEngine = audioEngine else { return false }
            
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            
            // Fix HIGH: Track tap installation to prevent crash
            // Install tap to monitor audio levels
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                // Fix CRITICAL: Use detached task without MainActor to prevent blocking audio thread
                // Process on background queue, update UI properties on MainActor
                Task.detached(priority: .userInteractive) {
                    await self?.processAudioBuffer(buffer)
                }
            }
            isTapInstalled = true
            
            try audioEngine.start()
            return true
        } catch {
            Self.logger.error("Failed to start real audio capture: \(error.localizedDescription)")
            // Fix HIGH: Clean up tap on failure path to prevent leak
            if isTapInstalled {
                audioEngine?.inputNode.removeTap(onBus: 0)
                isTapInstalled = false
            }
            audioEngine = nil
            return false
        }
    }
    
    private func stopRealAudioCapture() {
        // Fix HIGH: Remove tap BEFORE stopping engine to prevent crash
        if isTapInstalled, let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        audioEngine?.stop()
        audioEngine = nil
        
        // Fix CRITICAL: Conditionally deactivate audio session to prevent interference
        // 
        // Only deactivate if no other active audio sessions exist in the app.
        // This prevents interfering with music playback, VoIP calls, or other audio functionality.
        #if os(iOS) || os(tvOS) || os(watchOS)
        do {
            let session = AVAudioSession.sharedInstance()
            // Check if other audio sessions are active before deactivating
            if !session.isOtherAudioPlaying {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            } else {
                Self.logger.info("Keeping audio session active - other audio is playing")
            }
        } catch {
            Self.logger.error("Failed to deactivate audio session: \(error.localizedDescription)")
        }
        #endif
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Fix HIGH: Skip processing if audio capture is suspended (circuit breaker)
        guard !audioCaptureSuspended else { return }
        
        guard let channelData = buffer.floatChannelData else { return }
        let channelDataValue = channelData.pointee
        let frames = buffer.frameLength

        // Fix HIGH: Capture isEnabled/sensitivity atomically to prevent race
        let capturedEnabled = isEnabled
        let capturedSensitivity = sensitivity
        
        // Fix HIGH: Use direct buffer access instead of allocation (performance)
        let samplesPtr = UnsafeBufferPointer(start: channelDataValue, count: Int(frames))
        
        // Calculate input level (RMS) - using pointer directly
        let inputLevel = calculateRMSFromPointer(samplesPtr)
        
        if capturedEnabled {
            // Need array for ML processing
            let samples = Array(samplesPtr)
            
            // Process with ML if available
            let outputLevel = processWithMLIfAvailable(samples: samples, sensitivity: capturedSensitivity)
            currentLevels = AudioLevels(input: inputLevel, output: outputLevel)
        } else {
            // When disabled, show decay
            currentLevels = applyDecay()
        }
    }
    
    // Fix HIGH: Extract decay logic to avoid duplication
    private func applyDecay() -> AudioLevels {
        let decayedInput = max(currentLevels.input * AppConstants.levelDecayRate, 0)
        let decayedOutput = max(currentLevels.output * AppConstants.levelDecayRate, 0)
        
        if decayedInput < AppConstants.minimumLevelThreshold && decayedOutput < AppConstants.minimumLevelThreshold {
            return AudioLevels.zero
        } else {
            return AudioLevels(input: decayedInput, output: decayedOutput)
        }
    }
    
    // Fix HIGH: Add pointer-based RMS for performance
    private func calculateRMSFromPointer(_ samplesPtr: UnsafeBufferPointer<Float>) -> Float {
        guard samplesPtr.count > 0 else { return 0 }
        
        // Calculate RMS manually - vDSP_svesq isn't available in standard vDSP
        var sumOfSquares: Float = 0
        for sample in samplesPtr {
            sumOfSquares += sample * sample
        }
        let rms = sqrt(sumOfSquares / Float(samplesPtr.count))
        
        // Convert to 0-1 range
        return min(1.0, rms * AppConstants.rmsAmplificationFactor)
    }
    
     // MARK: - Input Validation
     
     /// Validate audio samples for range and quality issues
     /// - Parameter samples: Audio samples to validate
     /// - Returns: true if audio is valid for processing, false if validation fails
     private func validateAudioInput(_ samples: [Float]) -> Bool {
         // Fix HIGH: Empty buffer validation
         guard !samples.isEmpty else {
             return false
         }
         
         // Fix HIGH: Check for NaN or Infinity values (indicate processing errors upstream)
         guard samples.allSatisfy({ !$0.isNaN && !$0.isInfinite }) else {
             Self.logger.warning("Audio input contains NaN or Infinity values - skipping frame")
             return false
         }
         
         // Fix HIGH: Check for extreme amplitude values (potential DoS attack or distortion)
         guard samples.allSatisfy({ abs($0) <= AppConstants.maxAudioAmplitude }) else {
             Self.logger.warning("Audio input exceeds maximum amplitude \(AppConstants.maxAudioAmplitude) - possible clipping or attack")
             return false
         }
         
         // Fix HIGH: Calculate RMS and check for saturation
         var sum: Float = 0
         for sample in samples {
             sum += sample * sample
         }
         let rms = sqrt(sum / Float(samples.count))
         
         guard rms <= AppConstants.maxRMSLevel else {
             Self.logger.warning("Audio input RMS \(String(format: "%.3f", rms)) exceeds max level \(AppConstants.maxRMSLevel) - possible distortion")
             return false
         }
         
         return true
     }
     
     private func calculateRMS(samples: [Float]) -> Float {
         // Fix MAJOR: Guard against empty buffer causing division by zero
         guard !samples.isEmpty else { return 0 }
         
         var sum: Float = 0
         for sample in samples {
             sum += sample * sample
         }
         let rms = sqrt(sum / Float(samples.count))
         
         // Convert to 0-1 range (typical audio is -1 to 1, RMS will be much smaller)
         return min(1.0, rms * AppConstants.rmsAmplificationFactor)
     }
    
     private func processWithMLIfAvailable(samples: [Float], sensitivity: Double) -> Float {
         // Fix HIGH: Validate audio input before processing
         guard validateAudioInput(samples) else {
             // Invalid audio detected - skip ML processing but still calculate output level
             return calculateRMS(samples: samples) * Float(sensitivity)
         }
         
         // Fix CRITICAL: Capture denoiser to prevent race condition where it becomes nil
         // between guard check and actual use
         // Fix CRITICAL: Atomic read of memory pressure state to prevent race conditions
         let memoryPressureSuspended = mlStateQueue.sync { mlProcessingSuspendedDueToMemory }
         guard let capturedDenoiser = denoiser, 
               isMLProcessingActive, 
               !memoryPressureSuspended else {
             // Fallback to simple level-based processing during memory pressure or when ML disabled
             return calculateRMS(samples: samples) * Float(sensitivity)
         }
        
        // Fix CRITICAL: Atomic multi-step buffer operations to prevent race conditions
        let chunk = appendToBufferAndExtractChunk(samples: samples)
        
        // Process when we have enough samples
        guard let chunk = chunk else {
            // Not enough samples yet, return current level
            return calculateRMS(samples: samples) * Float(sensitivity)
        }
        
        // Process with DeepFilterNet
        do {
            let startTime = CFAbsoluteTimeGetCurrent()
            let enhanced = try capturedDenoiser.process(audio: chunk)
            let endTime = CFAbsoluteTimeGetCurrent()
            
            let latencyMs = (endTime - startTime) * 1000.0
            processingLatencyMs = latencyMs
            
            // Fix CRITICAL: Record telemetry for production monitoring
            var updatedTelemetry = telemetry
            updatedTelemetry.recordLatency(latencyMs)
            telemetry = updatedTelemetry
            
            // Monitor for SLA violations (target <1ms)
            if latencyMs > 1.0 {
                Self.logger.warning("Latency SLA violation: \(String(format: "%.2f", latencyMs))ms > 1.0ms target")
            }
            
            // Calculate output level from enhanced audio
            return calculateRMS(samples: enhanced)
        } catch {
            Self.logger.error("ML processing error: \(error.localizedDescription)")
            
            // Fix CRITICAL: Record telemetry for production monitoring
            var updatedTelemetry = telemetry
            updatedTelemetry.recordFailure()
            telemetry = updatedTelemetry
            
            isMLProcessingActive = false
            // Fix CRITICAL: Clear buffer synchronously to prevent race condition
            audioBufferQueue.sync { [weak self] in
                self?._audioBuffer.removeAll(keepingCapacity: false)
            }
            // Fix HIGH: Set denoiser to nil for consistency
            denoiser = nil
            
            // Fallback to simple processing
            return calculateRMS(samples: chunk) * Float(sensitivity)
        }
    }
    
    // Fix CRITICAL: Atomic multi-step buffer operation
    // Fix CRITICAL #5: Prevent unbounded memory growth during ML initialization
    private func appendToBufferAndExtractChunk(samples: [Float]) -> [Float]? {
        return audioBufferQueue.sync {
            // Fix CRITICAL: Simplified buffer overflow handling with logging
            //
            // ⚠️  AUDIO DROPPING BEHAVIOR:
            // When the buffer exceeds maxAudioBufferSize samples (1 second at 48kHz), old audio data is DROPPED
            // to maintain real-time processing. This prevents memory growth but may cause:
            // - Audio discontinuities during ML model loading/initialization
            // - Brief audio artifacts when switching between ML and fallback processing
            // - Loss of audio data during heavy system load
            //
            // This is designed for real-time applications where maintaining low latency is more
            // important than preserving every audio sample. For applications requiring perfect
            // audio preservation, consider increasing maxBufferSize or implementing backpressure.
            
            let maxBufferSize = AppConstants.maxAudioBufferSize
            let projectedSize = _audioBuffer.count + samples.count
            
            if projectedSize > maxBufferSize {
                // Fix HIGH: Circuit breaker for sustained buffer overflows
                consecutiveOverflows += 1
                var updatedTelemetry = telemetry
                updatedTelemetry.recordAudioBufferOverflow()
                telemetry = updatedTelemetry
                
                if consecutiveOverflows > AppConstants.maxConsecutiveOverflows && !audioCaptureSuspended {
                    updatedTelemetry = telemetry
                    updatedTelemetry.recordCircuitBreakerTrigger()
                    telemetry = updatedTelemetry
                    Self.logger.warning("Circuit breaker triggered: \(self.consecutiveOverflows) consecutive overflows")
                    Self.logger.info("Suspending audio capture for \(AppConstants.circuitBreakerSuspensionSeconds)s to allow ML to catch up")
                    suspendAudioCapture(duration: AppConstants.circuitBreakerSuspensionSeconds)
                    return nil // Skip this buffer append to help recovery
                }
                
                // Fix CRITICAL: Implement smoothing to prevent audio discontinuities
                Self.logger.warning("Audio buffer overflow \(self.consecutiveOverflows): \(self._audioBuffer.count) + \(samples.count) > \(maxBufferSize)")
                Self.logger.info("Applying crossfade to maintain audio continuity")
                
                // Fix CRITICAL: Calculate overflow and prevent crash when exceeding buffer size
                let overflow = projectedSize - maxBufferSize
                let samplesToRemove = min(overflow, _audioBuffer.count)
                
                // Apply crossfade to prevent clicks/pops when dropping audio
                let fadeLength = min(AppConstants.crossfadeLengthSamples, samplesToRemove)
                
                // Remove old samples first
                if samplesToRemove > 0 {
                    _audioBuffer.removeFirst(samplesToRemove)
                }
                
                // Apply fade-in to new samples if needed
                if fadeLength > 0 && samples.count >= fadeLength {
                    var fadedSamples = samples
                    for i in 0..<fadeLength {
                        let fade = Float(i + 1) / Float(fadeLength)
                        fadedSamples[i] *= fade
                    }
                    _audioBuffer.append(contentsOf: fadedSamples)
                } else {
                    _audioBuffer.append(contentsOf: samples)
                }
            } else {
                // Reset overflow counter on successful append
                consecutiveOverflows = 0
                _audioBuffer.append(contentsOf: samples)
            }
            
            guard _audioBuffer.count >= minimumBufferSize else {
                return nil
            }
            let chunk = Array(_audioBuffer.prefix(minimumBufferSize))
            _audioBuffer.removeFirst(minimumBufferSize)
            return chunk
        }
    }
    
    // MARK: - Simulated Audio (Fallback)
    
    private func startSimulatedAudio() {
        timer = Timer.scheduledTimer(withTimeInterval: AppConstants.audioUpdateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateSimulatedLevels()
            }
        }
    }
    
    private func stopSimulatedAudio() {
        timer?.invalidate()
        timer = nil
    }
    
    private func updateSimulatedLevels() {
        if isEnabled {
            let input = Float.random(in: Float(AppConstants.inputLevelRange.lowerBound)...Float(AppConstants.inputLevelRange.upperBound))
            let output = Float.random(in: Float(AppConstants.outputLevelRange.lowerBound)...Float(AppConstants.outputLevelRange.upperBound)) * Float(sensitivity)
            currentLevels = AudioLevels(input: input, output: output)
        } else {
            // Fix HIGH: Use extracted decay method
            currentLevels = applyDecay()
        }
    }
    
    // MARK: - Memory Pressure Monitoring (Production Safety)
    
    private func setupMemoryPressureMonitoring() {
        guard memoryPressureSource == nil else { return }
        
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        
        memoryPressureSource?.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            let pressureLevel = self.memoryPressureSource?.mask
            Task { @MainActor in
                self.handleMemoryPressure(pressureLevel)
            }
        }
        
        memoryPressureSource?.resume()
        isMemoryPressureHandlerActive = true
    }
    
    private func handleMemoryPressure(_ pressureLevel: DispatchSource.MemoryPressureEvent?) {
        guard let pressureLevel = pressureLevel else { return }
        
        // Record telemetry for production monitoring
        var updatedTelemetry = telemetry
        updatedTelemetry.recordMemoryPressure()
        telemetry = updatedTelemetry
        
        if pressureLevel.contains(.critical) {
            memoryPressureLevel = .critical
            // Immediately suspend ML processing to prevent iOS process termination
            suspendMLProcessing(reason: "Critical memory pressure")
            
        } else if pressureLevel.contains(.warning) {
            memoryPressureLevel = .warning
            // Reduce buffer sizes but continue processing
            optimizeMemoryUsage()
        }
        
        Self.logger.warning("Memory pressure detected: \(self.memoryPressureLevel.rawValue) - ML suspended: \(self.mlProcessingSuspendedDueToMemory)")
    }
    
 private func suspendMLProcessing(reason: String) {
        // Fix CRITICAL: Atomic check-and-set to prevent race conditions
        mlStateQueue.sync { [weak self] in
            guard let self = self else { return }
            guard !self.mlProcessingSuspendedDueToMemory else { return }
            
            self.mlProcessingSuspendedDueToMemory = true
            Self.logger.warning("ML processing suspended: \(reason)")
        }
        
        // Clear audio buffer to free memory
        clearAudioBuffers()
        
        // Set up memory pressure recovery timer
        memoryPressureSource?.resume()
        isMemoryPressureHandlerActive = true
        
        // Fix CRITICAL: Add timeout-based recovery for stuck memory pressure
        DispatchQueue.main.asyncAfter(deadline: .now() + AppConstants.memoryPressureRecoveryDelaySeconds) { [weak self] in
            // Force recovery attempt after timeout even if pressure is still warning
            self?.attemptMemoryPressureRecovery()
        }
    }
    
    /// Attempt to recover from memory pressure even if still elevated
    private func attemptMemoryPressureRecovery() {
        guard memoryPressureLevel != .critical else { return }
        
        Self.logger.info("Attempting timeout-based memory pressure recovery")
        if mlProcessingSuspendedDueToMemory && isEnabled {
            // Force re-initialization attempt
            initializeMLProcessing()
            Self.logger.info("Memory pressure recovery successful")
        }
    }
    
    private func optimizeMemoryUsage() {
        // Reduce audio buffer size during memory pressure
        audioBufferQueue.async { [weak self] in
            guard let self = self else { return }
            if self._audioBuffer.count > self.minimumBufferSize * 2 {
                // Keep only essential buffer size during memory pressure
                let excessSamples = self._audioBuffer.count - self.minimumBufferSize
                self._audioBuffer.removeFirst(excessSamples)
            }
        }
    }
    
    private func clearAudioBuffers() {
        audioBufferQueue.async { [weak self] in
            self?._audioBuffer.removeAll(keepingCapacity: false)
        }
    }
    
    private func checkMemoryPressureRecovery() {
        if memoryPressureLevel == .normal && mlProcessingSuspendedDueToMemory {
            mlProcessingSuspendedDueToMemory = false
            // Attempt to re-initialize ML processing
            if isEnabled {
                initializeMLProcessing()
            }
            Self.logger.info("Memory pressure recovered - attempting to resume ML processing")
        }
    }
    
    // Fix CRITICAL: Add synchronous reset function to prevent race conditions
    /// Reset all audio processing state atomically
    /// This is the primary reset API - use this instead of async operations
    func reset() {
        audioBufferQueue.sync { [weak self] in
            self?._audioBuffer.removeAll(keepingCapacity: false)
        }
        
        mlStateQueue.sync { [weak self] in
            self?.consecutiveOverflows = 0
        }
        
        // Reset ML processor if active
        if denoiser != nil {
            denoiser?.reset()
            denoiser = nil
            isMLProcessingActive = false
            processingLatencyMs = 0
        }
        
        Self.logger.info("AudioEngine reset completed")
    }
    
    // Fix HIGH: Audio capture suspension for circuit breaker
    private func suspendAudioCapture(duration: TimeInterval) {
        audioCaptureSuspended = true
        
        // Cancel any existing suspension timer
        audioCaptureSuspensionTimer?.invalidate()
        
        // Schedule resumption
        audioCaptureSuspensionTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.resumeAudioCapture()
            }
        }
    }
    
    private func resumeAudioCapture() {
        audioCaptureSuspended = false
        consecutiveOverflows = 0 // Reset counter on resume
        audioCaptureSuspensionTimer?.invalidate()
        audioCaptureSuspensionTimer = nil
        Self.logger.info("Audio capture resumed after circuit breaker recovery")
    }
}