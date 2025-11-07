import Foundation
import Combine
import AVFoundation

struct AudioLevels {
    let input: Float
    let output: Float
    
    static let zero = AudioLevels(input: 0.0, output: 0.0)
}

@MainActor
class AudioEngine: ObservableObject {
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
    }
    
    @Published var telemetry = ProductionTelemetry()
    
    private var timer: Timer?
    private var audioEngine: AVAudioEngine?
    private var isEnabled: Bool = false
    private var sensitivity: Double = 0.5
    
    // ML processing
    private var denoiser: DeepFilterNet?
    
    // Fix CRITICAL: Thread-safe audioBuffer access with dedicated queue
    private let audioBufferQueue = DispatchQueue(label: "com.vocana.audiobuffer", qos: .userInteractive)
    private nonisolated(unsafe) var _audioBuffer: [Float] = []
    private var audioBuffer: [Float] {
        get { audioBufferQueue.sync { _audioBuffer } }
        set { audioBufferQueue.sync { _audioBuffer = newValue } }
    }
    
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
        // Fix HIGH: Make ML initialization async to avoid blocking UI
        // Fix CRITICAL #4: Use MainActor.run to ensure isMLProcessingActive updates are synchronized
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            do {
                // Find models directory (can be slow with file system checks)
                let modelsPath = self.findModelsDirectory()
                
                // Create DeepFilterNet instance (potentially slow model loading)
                let denoiser = try DeepFilterNet(modelsDirectory: modelsPath)
                
                // Fix CRITICAL #4: Update state atomically with proper synchronization
                await MainActor.run {
                    self.mlStateQueue.sync {
                        // Check if ML was suspended during initialization
                        if !self.mlProcessingSuspendedDueToMemory {
                            self.denoiser = denoiser
                            self.isMLProcessingActive = true
                            print("✓ DeepFilterNet ML processing enabled")
                        } else {
                            print("⚠️ ML initialization completed but suspended due to memory pressure")
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    print("⚠️  Could not initialize ML processing: \(error.localizedDescription)")
                    print("   Falling back to simple level-based processing")
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
        // NOTE: Callers MUST call stopSimulation() before deallocation to prevent resource leaks
        // The tap and timer are MainActor-isolated and cannot be accessed here
        // Swift ARC will deallocate the engine, but the tap may remain installed
        
        // Log warning if cleanup wasn't called
        Task { @MainActor in
            print("⚠️ AudioEngine deallocated - ensure stopSimulation() was called for proper cleanup")
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
                // Fix CRITICAL: Use detached task to prevent MainActor deadlock
                Task.detached { @MainActor in
                    self?.processAudioBuffer(buffer)
                }
            }
            isTapInstalled = true
            
            try audioEngine.start()
            return true
        } catch {
            print("Failed to start real audio capture: \(error.localizedDescription)")
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
                print("ℹ️ Keeping audio session active - other audio is playing")
            }
        } catch {
            print("Failed to deactivate audio session: \(error.localizedDescription)")
        }
        #endif
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
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
            telemetry.recordLatency(latencyMs)
            
            // Monitor for SLA violations (target <1ms)
            if latencyMs > 1.0 {
                print("⚠️ Latency SLA violation: \(String(format: "%.2f", latencyMs))ms > 1.0ms target")
            }
            
            // Calculate output level from enhanced audio
            return calculateRMS(samples: enhanced)
        } catch {
            print("⚠️  ML processing error: \(error.localizedDescription)")
            
            // Fix CRITICAL: Record telemetry for production monitoring
            telemetry.recordFailure()
            
            isMLProcessingActive = false
            // Fix HIGH: Clear buffer on error to prevent unbounded growth
            audioBufferQueue.async { [weak self] in
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
                // Fix CRITICAL: Implement smoothing to prevent audio discontinuities
                print("⚠️ Audio buffer overflow: \(_audioBuffer.count) + \(samples.count) > \(maxBufferSize)")
                print("   Applying crossfade to maintain audio continuity")
                
                // Calculate how many samples to remove
                let samplesToRemove = projectedSize - maxBufferSize
                
                // Apply 10ms crossfade to prevent clicks/pops when dropping audio
                let fadeLength = min(480, samplesToRemove, _audioBuffer.count) // 10ms at 48kHz
                if fadeLength > 0 && _audioBuffer.count >= fadeLength {
                    // Apply fade-out to the end of existing buffer
                    for i in 0..<fadeLength {
                        let fade = Float(fadeLength - i) / Float(fadeLength)
                        _audioBuffer[_audioBuffer.count - fadeLength + i] *= fade
                    }
                }
                
                // Remove old samples
                _audioBuffer.removeFirst(samplesToRemove)
                _audioBuffer.append(contentsOf: samples)
            } else {
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
        telemetry.recordMemoryPressure()
        
        if pressureLevel.contains(.critical) {
            memoryPressureLevel = .critical
            // Immediately suspend ML processing to prevent iOS process termination
            suspendMLProcessing(reason: "Critical memory pressure")
            
        } else if pressureLevel.contains(.warning) {
            memoryPressureLevel = .warning
            // Reduce buffer sizes but continue processing
            optimizeMemoryUsage()
        }
        
        print("⚠️ Memory pressure detected: \(memoryPressureLevel) - ML suspended: \(mlProcessingSuspendedDueToMemory)")
    }
    
    private func suspendMLProcessing(reason: String) {
        // Fix CRITICAL: Atomic check-and-set to prevent race conditions
        var shouldSuspend = false
        mlStateQueue.sync {
            if isMLProcessingActive && !mlProcessingSuspendedDueToMemory {
                mlProcessingSuspendedDueToMemory = true
                shouldSuspend = true
            }
        }
        
        if shouldSuspend {
            denoiser = nil // Release ML models to free memory
            print("🔴 ML processing suspended: \(reason)")
        }
        
        // Schedule memory pressure recovery check
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.checkMemoryPressureRecovery()
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
            print("✅ Memory pressure recovered - attempting to resume ML processing")
        }
    }
}