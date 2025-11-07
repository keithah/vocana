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
    private var audioBuffer: [Float] = []
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
        do {
            // Find models directory
            let modelsPath = findModelsDirectory()
            
            // Create DeepFilterNet instance
            self.denoiser = try DeepFilterNet(modelsDirectory: modelsPath)
            self.isMLProcessingActive = true
            print("✓ DeepFilterNet ML processing enabled")
        } catch {
            print("⚠️  Could not initialize ML processing: \(error.localizedDescription)")
            print("   Falling back to simple level-based processing")
            self.denoiser = nil
            self.isMLProcessingActive = false
        }
    }
    
    private func findModelsDirectory() -> String {
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
    
    nonisolated deinit {
        // Cleanup audio resources safely
        if let engine = audioEngine {
            engine.stop()
            // Only remove tap if input node is valid
            if engine.inputNode.numberOfInputs > 0 {
                engine.inputNode.removeTap(onBus: 0)
            }
        }
        timer?.invalidate()
        
        // Clean up ML resources
        denoiser?.reset()
    }
    
    // MARK: - Real Audio Capture
    
    private func startRealAudioCapture() -> Bool {
        do {
            audioEngine = AVAudioEngine()
            guard let audioEngine = audioEngine else { return false }
            
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            
            // Install tap to monitor audio levels
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                Task { @MainActor in
                    self?.processAudioBuffer(buffer)
                }
            }
            
            try audioEngine.start()
            return true
        } catch {
            print("Failed to start real audio capture: \(error.localizedDescription)")
            return false
        }
    }
    
    private func stopRealAudioCapture() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
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
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(samples.count))
        
        // Convert to 0-1 range (typical audio is -1 to 1, RMS will be much smaller)
        return min(1.0, rms * 10.0)
    }
    
    private func processWithMLIfAvailable(samples: [Float]) -> Float {
        guard let denoiser = denoiser, isMLProcessingActive else {
            // Fallback to simple level-based processing
            return calculateRMS(samples: samples) * Float(sensitivity)
        }
        
        // Accumulate samples in buffer
        audioBuffer.append(contentsOf: samples)
        
        // Process when we have enough samples
        guard audioBuffer.count >= minimumBufferSize else {
            // Not enough samples yet, return current level
            return calculateRMS(samples: samples) * Float(sensitivity)
        }
        
        // Extract chunk for processing
        let chunk = Array(audioBuffer.prefix(minimumBufferSize))
        audioBuffer.removeFirst(minimumBufferSize)
        
        // Process with DeepFilterNet
        do {
            let startTime = CFAbsoluteTimeGetCurrent()
            let enhanced = try denoiser.process(audio: chunk)
            let endTime = CFAbsoluteTimeGetCurrent()
            
            // Update latency measurement
            processingLatencyMs = (endTime - startTime) * 1000.0
            
            // Calculate output level from enhanced audio
            return calculateRMS(samples: enhanced)
        } catch {
            print("⚠️  ML processing error: \(error.localizedDescription)")
            isMLProcessingActive = false
            
            // Fallback to simple processing
            return calculateRMS(samples: chunk) * Float(sensitivity)
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