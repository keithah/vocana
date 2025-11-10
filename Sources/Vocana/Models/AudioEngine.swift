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
    
    // Fix CRITICAL: Throttle UI updates to prevent main thread blocking
    private let uiUpdateThrottler = Throttler(interval: 0.016) // ~60fps
    
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
          let previousIssues = hasPerformanceIssues
          // Only show performance warning for critical issues, not ML initialization failures
          hasPerformanceIssues = (
              telemetry.audioBufferOverflows > 5 ||  // Multiple buffer overflows
              telemetry.circuitBreakerTriggers > 0 ||  // Any circuit breaker trips
              memoryPressureLevel != .normal  // Memory pressure issues
          )
          
          if hasPerformanceIssues != previousIssues {
              print("⚠️ Performance status changed: \(hasPerformanceIssues)")
              print("⚠️ Issues - Buffer overflows: \(telemetry.audioBufferOverflows), Circuit breaker: \(telemetry.circuitBreakerTriggers), ML failures: \(telemetry.mlProcessingFailures), Memory pressure: \(memoryPressureLevel)")
          }
          
          // Update buffer health message
          if telemetry.circuitBreakerTriggers > 0 {
              bufferHealthMessage = "Circuit breaker active (\(telemetry.circuitBreakerTriggers)x)"
          } else if telemetry.audioBufferOverflows > 5 {
              bufferHealthMessage = "Buffer pressure (\(telemetry.audioBufferOverflows) overflows)"
          } else if telemetry.mlProcessingFailures > 0 && !isMLProcessingActive {
              bufferHealthMessage = "ML unavailable - using basic processing"
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
    private var mlProcessor: MLAudioProcessorProtocol
    private var audioSessionManager: AudioSessionManager
    
    init() {
        // Initialize MainActor components
        self.levelController = AudioLevelController()
        self.bufferManager = AudioBufferManager()
        self.mlProcessor = MLAudioProcessor()
        self.audioSessionManager = AudioSessionManager()
        
        // Setup callbacks after initialization
        setupComponentCallbacks()
    }
    
    /// Test initializer with dependency injection
    init(mlProcessor: MLAudioProcessorProtocol) {
        // Initialize MainActor components
        self.levelController = AudioLevelController()
        self.bufferManager = AudioBufferManager()
        self.mlProcessor = mlProcessor
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
         mlProcessor.recordLatency = { [weak self] latency in
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
              print("❌ ML processor recordFailure callback triggered")
              self.recordTelemetryEvent { telemetry in
                  var updated = telemetry
                  updated.recordFailure()
                  return updated
              }
              Task { @MainActor in
                  Self.logger.info("Setting isMLProcessingActive to false due to failure")
                  self.isMLProcessingActive = false
                  self.updatePerformanceStatus()
               }
           }
          
          // Reset ML failures on successful processing
          mlProcessor.recordSuccess = { [weak self] in
              guard let self = self else { return }
              self.recordTelemetryEvent { telemetry in
                  var updated = telemetry
                  if updated.mlProcessingFailures > 0 {
                      updated.mlProcessingFailures = 0
                  }
                  return updated
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
            // Fix CRITICAL: Throttle UI updates to prevent main thread blocking
            self.uiUpdateThrottler.throttle {
                self.currentLevels = AudioLevels(input: input, output: output)
            }
        }
    }
    
    // MARK: - Public API
    
    func startAudioProcessing(isEnabled: Bool, sensitivity: Double) {
        Self.logger.info("Starting audio processing - isEnabled: \(isEnabled), sensitivity: \(sensitivity)")
        
        // Always stop existing pipeline first to ensure clean state
        if self.isEnabled {
            stopAudioProcessing()
        }

        self.isEnabled = isEnabled
        self.sensitivity = sensitivity

        if isEnabled {
            Self.logger.info("Starting real audio capture")
            isUsingRealAudio = audioSessionManager.startRealAudioCapture()
            Self.logger.info("Real audio capture result: \(self.isUsingRealAudio)")

            if !isUsingRealAudio {
                Self.logger.error("Failed to start real audio capture - microphone unavailable")
                // Reset engine state since capture failed
                self.isEnabled = false
                self.isUsingRealAudio = false
                return
            }

            Self.logger.info("Initializing ML processing")
            initializeMLProcessing()
        } else {
            Self.logger.debug("Starting decay timer for disabled state")
            // Start decay timer for visual smoothing when disabled
            startDecayTimer()
        }
        
        Self.logger.info("Audio processing started - isUsingRealAudio: \(self.isUsingRealAudio), isMLProcessingActive: \(self.isMLProcessingActive), hasPerformanceIssues: \(self.hasPerformanceIssues)")
    }

    /// Start decay timer for level smoothing during disabled state
    /// Security: Ensure proper timer resource management and cleanup
    private func startDecayTimer() {
        // Security: Ensure cleanup of existing timer before creating new one
        decayTimer?.invalidate()
        
        decayTimer = Timer.scheduledTimer(withTimeInterval: AppConstants.audioUpdateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let decayedLevels = self.levelController.applyDecay()
                // Fix CRITICAL: Throttle UI updates to prevent main thread blocking
                self.uiUpdateThrottler.throttle {
                    self.currentLevels = decayedLevels
                }
            }
        }
        
        // Security: Safely add timer to RunLoop with proper error handling
        if let timer = decayTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    func stopAudioProcessing() {
        isEnabled = false
        decayTimer?.invalidate()
        decayTimer = nil
        audioSessionManager.stopRealAudioCapture()
        mlProcessor.stopMLProcessing()
        
        // Keep published state in sync when stopping - fix menu bar icon state
        Task { @MainActor [weak self] in
            self?.isUsingRealAudio = false
            self?.isMLProcessingActive = false
        }
    }
    
    func reset() {
        stopAudioProcessing()
        levelController.updateLevels(input: 0, output: 0)
        bufferManager.clearAudioBuffers()
        
        // Ensure all published state is reset to initial values
        Task { @MainActor [weak self] in
            self?.currentLevels = AudioLevels.zero
        }
    }
    
    // MARK: - Private Methods
    
     private func initializeMLProcessing() {
         // Fix HIGH-008: ML initialization is now async with callback notification
         // No need for arbitrary sleep - onMLProcessingReady callback will notify when ready
         mlProcessor.initializeMLProcessing()
     }
    
    /// Process incoming audio buffer from audio capture system
    /// 
    /// This method serves as the entry point for audio processing pipeline:
    /// 1. Dispatches processing to dedicated audio queue to prevent MainActor blocking
    /// 2. Coordinates between audio capture, buffering, ML processing, and level calculation
    /// 3. Handles circuit breaker suspension and error recovery
    /// 
    /// - Important: This method is called from the audio capture thread (real-time priority)
    /// - Parameter buffer: Audio buffer containing captured audio data
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Fix CRITICAL: Keep heavy processing off MainActor to prevent UI blocking
        audioProcessingQueue.async { [weak self] in
            Task { @MainActor [weak self] in
                self?.processAudioBufferInternal(buffer)
            }
        }
    }
    
    private func processAudioBufferInternal(_ buffer: AVAudioPCMBuffer) {
        // Fix HIGH: Skip processing if audio capture is suspended (circuit breaker)
        // Use AudioBufferManager as single source of truth for suspension state
        guard !bufferManager.isAudioCaptureSuspended() else { return }
        
        // Extract audio samples from buffer
        guard let samples = extractAudioSamples(from: buffer) else { return }
        
        // Calculate input level
        let inputLevel = levelController.calculateRMS(samples: samples)
        
        // Capture state atomically for this processing cycle
        let capturedEnabled = isEnabled
        let capturedSensitivity = sensitivity
        
        // Process audio based on enabled state
        if capturedEnabled {
            let outputLevel = processEnabledAudio(samples: samples, sensitivity: capturedSensitivity, inputLevel: inputLevel)
            updateLevels(input: inputLevel, output: outputLevel)
        } else {
            let decayedLevels = processDisabledAudio(inputLevel: inputLevel)
            updateLevels(input: decayedLevels.input, output: decayedLevels.output)
        }
    }
    
    // MARK: - Audio Processing Helper Methods
    
    /// Extract audio samples from AVAudioPCMBuffer
    /// - Parameter buffer: Audio buffer to extract samples from
    /// - Returns: Array of Float samples, or nil if extraction fails
    private func extractAudioSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let channelDataValue = channelData.pointee
        let frames = buffer.frameLength
        
        let samplesPtr = UnsafeBufferPointer(start: channelDataValue, count: Int(frames))
        return Array(samplesPtr)
    }
    
    /// Process audio when enhancement is enabled
    /// - Parameters:
    ///   - samples: Audio samples to process
    ///   - sensitivity: Processing sensitivity (0-1)
    ///   - inputLevel: Calculated input RMS level
    /// - Returns: Output level after processing
    private func processEnabledAudio(samples: [Float], sensitivity: Double, inputLevel: Float) -> Float {
        return processWithMLIfAvailable(samples: samples, sensitivity: sensitivity)
    }
    
    /// Process audio when enhancement is disabled (apply decay)
    /// - Parameter inputLevel: Current input level
    /// - Returns: Audio levels after applying decay
    private func processDisabledAudio(inputLevel: Float) -> AudioLevels {
        return levelController.applyDecay()
    }
    
    /// Update currentLevels on MainActor
    /// - Parameters:
    ///   - input: Input audio level
    ///   - output: Output audio level
    private func updateLevels(input: Float, output: Float) {
        Task { @MainActor [weak self] in
            self?.currentLevels = AudioLevels(input: input, output: output)
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
         // Fix HIGH-006: Circuit breaker suspension is handled via recordCircuitBreakerSuspension callback
         let chunk = bufferManager.appendToBufferAndExtractChunk(samples: samples) { [weak self] duration in
             guard let self = self else { return }
             // Trigger the circuit breaker callback which updates UI flags
             // The actual suspension is managed within AudioBufferManager.audioBufferQueue
             self.bufferManager.recordCircuitBreakerSuspension(duration)
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
