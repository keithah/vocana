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
    
    private var timer: Timer?
    private var audioEngine: AVAudioEngine?
    private var isEnabled: Bool = false
    private var sensitivity: Double = 0.5
    
    func startSimulation(isEnabled: Bool, sensitivity: Double) {
        self.isEnabled = isEnabled
        self.sensitivity = sensitivity
        
        stopSimulation()
        
        // Try to start real audio capture, fallback to simulation
        if startRealAudioCapture() {
            isUsingRealAudio = true
        } else {
            isUsingRealAudio = false
            startSimulatedAudio()
        }
    }
    
    func stopSimulation() {
        stopRealAudioCapture()
        stopSimulatedAudio()
    }
    
    deinit {
        // Cleanup audio resources
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        timer?.invalidate()
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
        
        // Calculate RMS (Root Mean Square) for audio level
        var sum: Float = 0
        for frame in 0..<Int(frames) {
            let sample = channelDataValue[frame]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frames))
        
        // Convert to 0-1 range (typical audio is -1 to 1, RMS will be much smaller)
        let inputLevel = min(1.0, rms * 10.0) // Scale up RMS
        
        if isEnabled {
            // Apply noise reduction (simulated by reducing output level)
            let outputLevel = inputLevel * Float(sensitivity)
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