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
    
    private var timer: Timer?
    private var audioEngine: AVAudioEngine?
    private var isEnabled: Bool = false
    private var sensitivity: Double = 0.5
    
    // ML processing
    private var denoiser: DeepFilterNet?
    
    // Fix CRITICAL: Thread-safe audioBuffer access with dedicated queue
    private let audioBufferQueue = DispatchQueue(label: "com.vocana.audiobuffer")
    private var _audioBuffer: [Float] = []
    private var audioBuffer: [Float] {
        get { audioBufferQueue.sync { _audioBuffer } }
        set { audioBufferQueue.sync { _audioBuffer = newValue } }
    }
    
    private let minimumBufferSize = 960  // FFT size for DeepFilterNet
    
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
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            do {
                // Find models directory (can be slow with file system checks)
                let modelsPath = self.findModelsDirectory()
                
                // Create DeepFilterNet instance (potentially slow model loading)
                let denoiser = try DeepFilterNet(modelsDirectory: modelsPath)
                
                // Update state on main actor
                await MainActor.run {
                    self.denoiser = denoiser
                    self.isMLProcessingActive = true
                    print("✓ DeepFilterNet ML processing enabled")
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
        // Fix HIGH: Don't access MainActor-isolated properties from nonisolated deinit
        // audioEngine, timer, denoiser are all captured and cleaned up properly
        // The engine cleanup happens automatically when the instance is deallocated
    }
    
    // MARK: - Real Audio Capture
    
    private func startRealAudioCapture() -> Bool {
        do {
            audioEngine = AVAudioEngine()
            guard let audioEngine = audioEngine else { return false }
            
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            
            // Fix HIGH: Track tap installation to prevent crash
            // Install tap to monitor audio levels
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                Task { @MainActor in
                    self?.processAudioBuffer(buffer)
                }
            }
            isTapInstalled = true
            
            try audioEngine.start()
            return true
        } catch {
            print("Failed to start real audio capture: \(error.localizedDescription)")
            return false
        }
    }
    
    private func stopRealAudioCapture() {
        audioEngine?.stop()
        // Fix HIGH: Only remove tap if it was installed to prevent crash
        if isTapInstalled, let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        audioEngine = nil
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let channelDataValue = channelData.pointee
        let frames = buffer.frameLength
        
        // Extract audio samples
        var samples = [Float](repeating: 0, count: Int(frames))
        for i in 0..<Int(frames) {
            samples[i] = channelDataValue[i]
        }
        
        // Calculate input level (RMS)
        let inputLevel = calculateRMS(samples: samples)
        
        if isEnabled {
            // Process with ML if available
            let outputLevel = processWithMLIfAvailable(samples: samples)
            currentLevels = AudioLevels(input: inputLevel, output: outputLevel)
        } else {
            // When disabled, show decay
            let decayedInput = max(currentLevels.input * AppConstants.levelDecayRate, 0)
            let decayedOutput = max(currentLevels.output * AppConstants.levelDecayRate, 0)
            
            if decayedInput < AppConstants.minimumLevelThreshold && decayedOutput < AppConstants.minimumLevelThreshold {
                currentLevels = AudioLevels.zero
            } else {
                currentLevels = AudioLevels(input: decayedInput, output: decayedOutput)
            }
        }
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
        return min(1.0, rms * 10.0)
    }
    
    private func processWithMLIfAvailable(samples: [Float]) -> Float {
        // Fix CRITICAL: Capture denoiser to prevent race condition where it becomes nil
        // between guard check and actual use
        guard let capturedDenoiser = denoiser, isMLProcessingActive else {
            // Fallback to simple level-based processing
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
            
            // Update latency measurement
            processingLatencyMs = (endTime - startTime) * 1000.0
            
            // Calculate output level from enhanced audio
            return calculateRMS(samples: enhanced)
        } catch {
            print("⚠️  ML processing error: \(error.localizedDescription)")
            isMLProcessingActive = false
            // Fix HIGH: Clear buffer on error to prevent unbounded growth
            audioBuffer.removeAll()
            
            // Fallback to simple processing
            return calculateRMS(samples: chunk) * Float(sensitivity)
        }
    }
    
    // Fix CRITICAL: Atomic multi-step buffer operation
    private func appendToBufferAndExtractChunk(samples: [Float]) -> [Float]? {
        return audioBufferQueue.sync {
            _audioBuffer.append(contentsOf: samples)
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
            let decayedInput = max(currentLevels.input * AppConstants.levelDecayRate, 0)
            let decayedOutput = max(currentLevels.output * AppConstants.levelDecayRate, 0)
            
            if decayedInput < AppConstants.minimumLevelThreshold && decayedOutput < AppConstants.minimumLevelThreshold {
                currentLevels = AudioLevels.zero
            } else {
                currentLevels = AudioLevels(input: decayedInput, output: decayedOutput)
            }
        }
    }
}