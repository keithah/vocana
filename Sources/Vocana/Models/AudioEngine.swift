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
    
    // MARK: - Published Properties (UI)
    
    @Published var currentLevels = AudioLevels.zero
    @Published var isUsingRealAudio = false
    @Published var isMLProcessingActive = false
    @Published var processingLatencyMs: Double = 0
    @Published var memoryPressureLevel: MemoryPressureLevel = .normal
    @Published var telemetry = ProductionTelemetry()
    
    // Fix CRITICAL-001: Dedicated queue for telemetry to prevent race conditions
    private let telemetryQueue = DispatchQueue(label: "com.vocana.telemetry", qos: .userInitiated)
    private var telemetrySnapshot = ProductionTelemetry()
    
    // MARK: - Memory Pressure Monitoring
    
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
    
    /// Computed property to indicate if there are buffer/performance issues
    var hasPerformanceIssues: Bool {
        telemetry.audioBufferOverflows > 0 ||
        telemetry.circuitBreakerTriggers > 0 ||
        telemetry.mlProcessingFailures > 0 ||
        memoryPressureLevel != .normal
    }
    
    /// Computed property for user-friendly status message about buffer health
    var bufferHealthMessage: String {
        if telemetry.circuitBreakerTriggers > 0 {
            return "Circuit breaker active (\(telemetry.circuitBreakerTriggers)x)"
        } else if telemetry.audioBufferOverflows > 0 {
            return "Buffer pressure (\(telemetry.audioBufferOverflows) overflows)"
        } else if telemetry.mlProcessingFailures > 0 {
            return "ML issues detected"
        } else {
            return "Buffer healthy"
        }
    }
    
    // MARK: - Component Instances
    
    private let levelController = AudioLevelController()
    private let bufferManager = AudioBufferManager()
    private let mlProcessor = MLAudioProcessor()
    private let audioSessionManager = AudioSessionManager()
    
    // MARK: - Private State
    
    private var isEnabled: Bool = false
    private var sensitivity: Double = 0.5
    private var audioCaptureSuspended = false
    
    // Fix CRITICAL: Memory pressure monitoring
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var isMemoryPressureHandlerActive = false
    
    // MARK: - Initialization
    
    init() {
        setupComponentCallbacks()
        setupMemoryPressureMonitoring()
    }
    
    /// Configure callbacks between components
    private func setupComponentCallbacks() {
        // Level controller has no callbacks
        
        // Buffer manager callbacks
        // Fix CRITICAL-001: Use dedicated telemetryQueue for thread-safe telemetry updates
        bufferManager.recordBufferOverflow = { [weak self] in
            guard let self = self else { return }
            self.telemetryQueue.sync {
                self.telemetrySnapshot.recordAudioBufferOverflow()
                Task { @MainActor in
                    self.telemetry = self.telemetrySnapshot
                }
            }
        }
        
        bufferManager.recordCircuitBreakerTrigger = { [weak self] in
            guard let self = self else { return }
            self.telemetryQueue.sync {
                self.telemetrySnapshot.recordCircuitBreakerTrigger()
                Task { @MainActor in
                    self.telemetry = self.telemetrySnapshot
                }
            }
        }
        
        bufferManager.recordCircuitBreakerSuspension = { [weak self] duration in
            guard let self = self else { return }
            Task { @MainActor in
                self.audioCaptureSuspended = true
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                    self?.audioCaptureSuspended = false
                }
            }
        }
        
        // ML processor callbacks
        // Fix CRITICAL-001: Use dedicated telemetryQueue for thread-safe telemetry updates
        mlProcessor.recordLatency = { [weak self] latency in
            guard let self = self else { return }
            Task { @MainActor in
                self.processingLatencyMs = latency
            }
            self.telemetryQueue.sync {
                self.telemetrySnapshot.recordLatency(latency)
                Task { @MainActor in
                    self.telemetry = self.telemetrySnapshot
                }
            }
        }
        
        mlProcessor.recordFailure = { [weak self] in
            guard let self = self else { return }
            self.telemetryQueue.sync {
                self.telemetrySnapshot.recordFailure()
                Task { @MainActor in
                    self.telemetry = self.telemetrySnapshot
                    self.isMLProcessingActive = false
                }
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
    }
    
    // MARK: - Public API
    
    func startSimulation(isEnabled: Bool, sensitivity: Double) {
        self.isEnabled = isEnabled
        self.sensitivity = sensitivity
        
        if isEnabled {
            isUsingRealAudio = audioSessionManager.startRealAudioCapture()
            
            if !isUsingRealAudio {
                audioSessionManager.isEnabled = isEnabled
                audioSessionManager.sensitivity = sensitivity
                audioSessionManager.startSimulatedAudio()
            }
            
            initializeMLProcessing()
        } else {
            audioSessionManager.stopSimulatedAudio()
        }
    }
    
    func stopSimulation() {
        isEnabled = false
        audioSessionManager.stopRealAudioCapture()
        audioSessionManager.stopSimulatedAudio()
        mlProcessor.stopMLProcessing()
    }
    
    func reset() {
        stopSimulation()
        levelController.updateLevels(input: 0, output: 0)
        bufferManager.clearAudioBuffers()
        audioCaptureSuspended = false
    }
    
    // MARK: - Private Methods
    
    private func initializeMLProcessing() {
        mlProcessor.initializeMLProcessing()
        Task {
            // Wait a bit then check if active
            try? await Task.sleep(nanoseconds: 100_000_000)
            if mlProcessor.isMLProcessingActive {
                isMLProcessingActive = true
            }
        }
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Fix HIGH: Skip processing if audio capture is suspended (circuit breaker)
        guard !audioCaptureSuspended else { return }
        
        guard let channelData = buffer.floatChannelData else { return }
        let channelDataValue = channelData.pointee
        let frames = buffer.frameLength
        
        // Capture state atomically
        let capturedEnabled = isEnabled
        let capturedSensitivity = sensitivity
        
        let samplesPtr = UnsafeBufferPointer(start: channelDataValue, count: Int(frames))
        
        // Calculate input level
        let inputLevel = levelController.calculateRMSFromPointer(samplesPtr)
        
        if capturedEnabled {
            let samples = Array(samplesPtr)
            let outputLevel = processWithMLIfAvailable(samples: samples, sensitivity: capturedSensitivity)
            currentLevels = AudioLevels(input: inputLevel, output: outputLevel)
        } else {
            // Apply level decay when disabled
            currentLevels = levelController.applyDecay()
        }
    }
    
    private func processWithMLIfAvailable(samples: [Float], sensitivity: Double) -> Float {
        // Validate audio input
        guard levelController.validateAudioInput(samples) else {
            return levelController.calculateRMS(samples: samples) * Float(sensitivity)
        }
        
        // Check if ML is available
        guard isMLProcessingActive, !mlProcessor.isMemoryPressureSuspended() else {
            return levelController.calculateRMS(samples: samples) * Float(sensitivity)
        }
        
        // Append to buffer and extract chunk
        // Fix CRITICAL-004: Use weak self to prevent retain cycles in callback
        let chunk = bufferManager.appendToBufferAndExtractChunk(samples: samples) { [weak self] duration in
            guard let self = self else { return }
            // Handle circuit breaker suspension without nested dispatch to MainActor
            // Schedule resumption outside the audio processing hot path
            Task { @MainActor in
                self.audioCaptureSuspended = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self = self else { return }
                Task { @MainActor in
                    self.audioCaptureSuspended = false
                }
            }
        }
        
        // Process when we have enough samples
        guard let chunk = chunk else {
            return levelController.calculateRMS(samples: samples) * Float(sensitivity)
        }
        
        // Run ML inference
        if let enhanced = mlProcessor.processAudioWithML(chunk: chunk, sensitivity: sensitivity) {
            return levelController.calculateRMS(samples: enhanced)
        } else {
            // ML failed, use fallback
            return levelController.calculateRMS(samples: chunk) * Float(sensitivity)
        }
    }
    
    // MARK: - Memory Pressure Monitoring
    
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
        
        var updatedTelemetry = telemetry
        updatedTelemetry.recordMemoryPressure()
        telemetry = updatedTelemetry
        
        if pressureLevel.contains(.critical) {
            memoryPressureLevel = .critical
            mlProcessor.suspendMLProcessing(reason: "Critical memory pressure")
        } else if pressureLevel.contains(.warning) {
            memoryPressureLevel = .warning
            // Reduce buffer sizes but continue processing
            bufferManager.clearAudioBuffers()
        }
        
        Self.logger.warning("Memory pressure detected: \(self.memoryPressureLevel.rawValue)")
    }
    
    deinit {
        memoryPressureSource?.cancel()
        // Schedule cleanup on MainActor to handle actor isolation
        Task { @MainActor [weak self] in
            self?.audioSessionManager.cleanup()
        }
    }
}
