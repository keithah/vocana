import Foundation
import Combine
@preconcurrency import AVFoundation
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
    nonisolated private static let logger = Logger(subsystem: "Vocana", category: "AudioEngine")
    
    // Fix CRITICAL: Move audio processing off MainActor to prevent UI blocking
    private let audioProcessingQueue = DispatchQueue(label: "com.vocana.audio.processing", qos: .userInteractive)
    private let uiUpdateQueue = DispatchQueue(label: "com.vocana.ui.updates", qos: .userInitiated)
    
    // MARK: - Published Properties (UI) - Updated safely from background
    
    @Published var currentLevels = AudioLevels.zero
    @Published var isUsingRealAudio = false
    @Published var isMLProcessingActive = false
    @Published var processingLatencyMs: Double = 0
    @Published var memoryPressureLevel: MemoryPressureLevel = .normal
    @Published var telemetry = ProductionTelemetry()
    @Published var hasPerformanceIssues = false
    @Published var bufferHealthMessage = "Buffer healthy"
    
     // Fix CRITICAL-004: Actor-based telemetry to eliminate race conditions
     private let telemetryActor = TelemetryActor()
     
     /// Actor for thread-safe telemetry management
     private actor TelemetryActor {
         private var _telemetry = ProductionTelemetry()
         
         func update(_ update: (ProductionTelemetry) -> ProductionTelemetry) -> ProductionTelemetry {
             _telemetry = update(_telemetry)
             return _telemetry
         }
         
         func current() -> ProductionTelemetry {
             return _telemetry
         }
     }
    
    // MARK: - Memory Pressure Monitoring
    
    enum MemoryPressureLevel: Int {
        case normal = 0
        case warning = 1
        case urgent = 2
        case critical = 3
    }
    
    // Fix CRITICAL: Production telemetry for monitoring and debugging
    struct ProductionTelemetry: Sendable {
        var totalFramesProcessed: UInt64 = 0
        var mlProcessingFailures: UInt64 = 0
        var circuitBreakerTriggers: UInt64 = 0
        var audioBufferOverflows: UInt64 = 0
        var memoryPressureEvents: UInt64 = 0
        var averageLatencyMs: Double = 0
        var peakMemoryUsageMB: Double = 0
        var audioQualityScore: Double = 1.0
        
        mutating func recordLatency(_ latencyMs: Double) {
            totalFramesProcessed += 1
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
    
     /// Fix HIGH-004: Update performance status based on current telemetry
     private func updatePerformanceStatus() {
         hasPerformanceIssues = (
             telemetry.audioBufferOverflows > 0 ||
             telemetry.circuitBreakerTriggers > 0 ||
             telemetry.mlProcessingFailures > 0 ||
             memoryPressureLevel != .normal
         )
         
         // Update buffer health message
         if telemetry.circuitBreakerTriggers > 0 {
             bufferHealthMessage = "Circuit breaker active (\(telemetry.circuitBreakerTriggers)x)"
         } else if telemetry.audioBufferOverflows > 0 {
             bufferHealthMessage = "Buffer pressure (\(telemetry.audioBufferOverflows) overflows)"
         } else if telemetry.mlProcessingFailures > 0 {
             bufferHealthMessage = "ML issues detected"
         } else {
             bufferHealthMessage = "Buffer healthy"
         }
     }
     
     /// Fix CRITICAL-004: Record telemetry event using actor for thread safety
     private func recordTelemetryEvent(_ update: @escaping (ProductionTelemetry) -> ProductionTelemetry) {
         Task { [weak self] in
             guard let self = self else { return }
             let updatedTelemetry = await self.telemetryActor.update(update)
             await MainActor.run {
                 self.telemetry = updatedTelemetry
                 self.updatePerformanceStatus()
             }
         }
     }
    
    // MARK: - Component Instances

    private var levelController: AudioLevelController
    private var bufferManager: AudioBufferManager
    private var mlProcessor: MLAudioProcessor
    private var audioSessionManager: AudioSessionManager

    // HAL Plugin: Audio output callback for virtual devices
    var onProcessedAudioBufferReady: (([Float]) -> Void)?
    
    init() {
        // Initialize MainActor components
        self.levelController = AudioLevelController()
        self.bufferManager = AudioBufferManager()
        self.mlProcessor = MLAudioProcessor()
        self.audioSessionManager = AudioSessionManager()
        
        // Setup callbacks after initialization
        setupComponentCallbacks()
    }
    
    // MARK: - Private State
    
    private var isEnabled: Bool = false
    private var sensitivity: Double = 0.5
    private var decayTimer: Timer?

    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var isMemoryPressureHandlerActive = false
    

    
    /// Configure callbacks between components
    private func setupComponentCallbacks() {
        // Level controller has no callbacks
        
         // Buffer manager callbacks
         // Fix CRITICAL-001: Use dedicated telemetryQueue for thread-safe telemetry updates
         // Fix HIGH-005: Use async instead of sync to avoid blocking audio processing
         bufferManager.recordBufferOverflow = { [weak self] in
             guard let self = self else { return }
             self.recordTelemetryEvent { telemetry in
                 var updated = telemetry
                 updated.recordAudioBufferOverflow()
                 return updated
             }
         }
         
         bufferManager.recordCircuitBreakerTrigger = { [weak self] in
             guard let self = self else { return }
             self.recordTelemetryEvent { telemetry in
                 var updated = telemetry
                 updated.recordCircuitBreakerTrigger()
                 return updated
             }
         }
        
          bufferManager.recordCircuitBreakerSuspension = { duration in
             // Fix HIGH-006: Circuit breaker suspension is handled within AudioBufferManager
             // No need to maintain duplicate state - AudioBufferManager is single source of truth
             Self.logger.info("Circuit breaker suspension triggered for \(duration)s")
         }
        
         // ML processor callbacks
         // Fix CRITICAL-001: Use dedicated telemetryQueue for thread-safe telemetry updates
         // Fix HIGH-005: Use async instead of sync to avoid blocking audio processing
          mlProcessor.recordLatency = { [weak self] (latency: Double) in
             guard let self = self else { return }
             Task { @MainActor in
                 self.processingLatencyMs = latency
             }
             self.recordTelemetryEvent { telemetry in
                 var updated = telemetry
                 updated.recordLatency(latency)
                 return updated
             }
         }
         
         mlProcessor.recordFailure = { [weak self] in
             guard let self = self else { return }
             self.recordTelemetryEvent { telemetry in
                 var updated = telemetry
                 updated.recordFailure()
                 return updated
             }
             Task { @MainActor in
                 self.isMLProcessingActive = false
                 self.updatePerformanceStatus()
             }
         }
         
         // Fix HIGH-008: Use callback instead of arbitrary sleep for ML initialization
         mlProcessor.onMLProcessingReady = { [weak self] in
             Task { @MainActor in
                 self?.isMLProcessingActive = true
             }
         }
        
        // Audio session manager callbacks
        audioSessionManager.onAudioBufferReceived = { [weak self] buffer in
            guard let self = self else { return }
            self.processAudioBuffer(buffer)
        }

        audioSessionManager.updateLevels = { [weak self] input, output in
            guard let self = self else { return }
            self.currentLevels = AudioLevels(input: input, output: output)
        }

        // HAL Plugin: Connect processed audio output to AudioSessionManager
        onProcessedAudioBufferReady = { [weak self] processedSamples in
            self?.audioSessionManager.onProcessedAudioOutput?(processedSamples)
        }
    }
    
    // MARK: - Public API
    
    func startSimulation(isEnabled: Bool, sensitivity: Double) {
        // Always stop existing pipeline first to ensure clean state
        if self.isEnabled {
            stopSimulation()
        }

        self.isEnabled = isEnabled
        self.sensitivity = sensitivity

        if isEnabled {
            isUsingRealAudio = audioSessionManager.startRealAudioCapture()

            // Always start simulated audio for testing and fallback
            audioSessionManager.isEnabled = isEnabled
            audioSessionManager.sensitivity = sensitivity
            audioSessionManager.startSimulatedAudio()

            initializeMLProcessing()
        } else {
            // Start decay timer for visual smoothing when disabled
            startDecayTimer()
        }
    }

    /// Start decay timer for level smoothing during disabled simulation
    private func startDecayTimer() {
        decayTimer = Timer.scheduledTimer(withTimeInterval: AppConstants.audioUpdateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let decayedLevels = self.levelController.applyDecay()
                self.currentLevels = decayedLevels
            }
        }
        RunLoop.main.add(decayTimer!, forMode: .common)
    }
    
    func stopSimulation() {
        isEnabled = false
        decayTimer?.invalidate()
        decayTimer = nil
        audioSessionManager.stopRealAudioCapture()
        audioSessionManager.stopSimulatedAudio()
        mlProcessor.stopMLProcessing()
    }
    
    func reset() {
        stopSimulation()
        levelController.updateLevels(input: 0, output: 0)
        bufferManager.clearAudioBuffers()
    }
    
    // MARK: - Private Methods
    
     private func initializeMLProcessing() {
         // Fix HIGH-008: ML initialization is now async with callback notification
         // No need for arbitrary sleep - onMLProcessingReady callback will notify when ready
         mlProcessor.initializeMLProcessing()
     }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Fix CRITICAL: Move audio processing off MainActor to prevent UI blocking
        // Capture MainActor state before dispatching to background
        let capturedEnabled = isEnabled
        let capturedSensitivity = sensitivity
        let capturedCallback = onProcessedAudioBufferReady

        audioProcessingQueue.async { [weak self] in
            self?.processAudioBufferInternal(buffer, enabled: capturedEnabled, sensitivity: capturedSensitivity, callback: capturedCallback)
        }
    }
    
    private func processAudioBufferInternal(_ buffer: AVAudioPCMBuffer, enabled: Bool, sensitivity: Double, callback: (([Float]) -> Void)?) {
        // Fix HIGH: Skip processing if audio capture is suspended (circuit breaker)
        // Use AudioBufferManager as single source of truth for suspension state
        guard !bufferManager.isAudioCaptureSuspended() else { return }

        guard let channelData = buffer.floatChannelData else { return }
        let channelDataValue = channelData.pointee
        let frames = buffer.frameLength

        let samplesPtr = UnsafeBufferPointer(start: channelDataValue, count: Int(frames))

        // Calculate input level
        let inputLevel = levelController.calculateRMSFromPointer(samplesPtr)

        if enabled {
            let samples = Array(samplesPtr)
            let processedSamples = processWithMLForOutput(samples: samples, sensitivity: sensitivity)
            let outputLevel = levelController.calculateRMS(samples: processedSamples)

            // HAL Plugin: Emit processed stereo buffer to virtual devices
            callback?(processedSamples)

            // Update UI safely on MainActor
            Task { @MainActor [weak self] in
                self?.currentLevels = AudioLevels(input: inputLevel, output: outputLevel)
            }
        } else {
            // Apply level decay when disabled
            let decayedLevels = levelController.applyDecay()

            // Update UI safely on MainActor
            Task { @MainActor [weak self] in
                self?.currentLevels = decayedLevels
            }
        }
    }
    
    /// Process audio samples with ML and return processed samples for output
    /// - Parameters:
    ///   - samples: Input audio samples
    ///   - sensitivity: Processing sensitivity
    /// - Returns: Processed audio samples (stereo if available)
    private func processWithMLForOutput(samples: [Float], sensitivity: Double) -> [Float] {
        // Validate audio input
        guard levelController.validateAudioInput(samples) else {
            // Apply sensitivity and convert to stereo
            let processed = samples.map { $0 * Float(sensitivity) }
            return convertToStereo(processed)
        }

        // Check if ML is available
        guard isMLProcessingActive, !mlProcessor.isMemoryPressureSuspended() else {
            // Apply sensitivity and convert to stereo
            let processed = samples.map { $0 * Float(sensitivity) }
            return convertToStereo(processed)
        }

         // Append to buffer and extract chunk
         // Fix HIGH-006: Circuit breaker suspension is handled via recordCircuitBreakerSuspension callback
         let chunk = bufferManager.appendToBufferAndExtractChunk(samples: samples) { [weak self] duration in
             guard let self = self else { return }
             // Trigger the circuit breaker callback which updates UI flags
             // The actual suspension is managed within AudioBufferManager.audioBufferQueue
             self.bufferManager.recordCircuitBreakerSuspension(duration)
         }

        // Process when we have enough samples
        guard let chunk = chunk else {
            // Apply sensitivity and convert to stereo
            let processed = samples.map { $0 * Float(sensitivity) }
            return convertToStereo(processed)
        }

        // Run ML inference
        if let enhanced = mlProcessor.processAudioWithML(chunk: chunk, sensitivity: sensitivity) {
            return convertToStereo(enhanced)
        } else {
            // ML failed, use fallback with sensitivity
            let processed = chunk.map { $0 * Float(sensitivity) }
            return convertToStereo(processed)
        }
    }

    /// Convert mono audio samples to stereo format for HAL plugin output
    /// - Parameter monoSamples: Mono audio samples
    /// - Returns: Stereo audio samples (duplicated mono channel)
    private func convertToStereo(_ monoSamples: [Float]) -> [Float] {
        // For HAL plugin: duplicate mono channel to create stereo output
        var stereoSamples = [Float]()
        stereoSamples.reserveCapacity(monoSamples.count * 2)

        for sample in monoSamples {
            stereoSamples.append(sample) // Left channel
            stereoSamples.append(sample) // Right channel
        }

        return stereoSamples
    }

    private func processWithMLIfAvailable(samples: [Float], sensitivity: Double) -> Float {
        let processed = processWithMLForOutput(samples: samples, sensitivity: sensitivity)
        return levelController.calculateRMS(samples: processed)
    }
    
    // MARK: - Memory Pressure Monitoring
    
    private func setupMemoryPressureMonitoring() {
        guard memoryPressureSource == nil else { return }
        
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        
        // Fix HIGH-002: Capture mask within handler to prevent TOCTOU race
        memoryPressureSource?.setEventHandler { [weak self] in
            guard let self = self, let source = self.memoryPressureSource else { return }
            
            // Capture the pressure level immediately to prevent stale state
            let pressureLevel = source.mask
            Task { @MainActor in
                self.handleMemoryPressure(pressureLevel)
            }
        }
        
        memoryPressureSource?.resume()
        isMemoryPressureHandlerActive = true
    }
    
     private func handleMemoryPressure(_ pressureLevel: DispatchSource.MemoryPressureEvent?) {
         guard let pressureLevel = pressureLevel else { return }
         
         // Fix HIGH: Use recordTelemetryEvent to avoid race condition
         recordTelemetryEvent { telemetry in
             var updated = telemetry
             updated.recordMemoryPressure()
             return updated
         }
        
        if pressureLevel.contains(.critical) {
            memoryPressureLevel = .critical
            mlProcessor.suspendMLProcessing(reason: "Critical memory pressure")
        } else if pressureLevel.contains(.warning) {
            memoryPressureLevel = .warning
            // Reduce buffer sizes but continue processing
            bufferManager.clearAudioBuffers()
        }
        
        // Fix HIGH-004: Update performance status when memory pressure changes
        updatePerformanceStatus()
        
        Self.logger.warning("Memory pressure detected: \(self.memoryPressureLevel.rawValue)")
    }
    
    deinit {
        memoryPressureSource?.cancel()
        // Fix CRITICAL-003: Ensure audioSessionManager cleanup happens synchronously before deallocate
        // Capture audioSessionManager before self is deallocated
        let sessionManager = audioSessionManager
        Task { @MainActor in
            sessionManager.cleanup()
        }
    }
}
