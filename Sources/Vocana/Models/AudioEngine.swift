import Foundation

struct AudioLevels {
    let input: Float
    let output: Float
    
    static let zero = AudioLevels(input: 0.0, output: 0.0)
}

class AudioEngine: ObservableObject {
    @Published var currentLevels = AudioLevels.zero
    private var timer: Timer?
    
    func startSimulation(isEnabled: Bool, sensitivity: Double) {
        stopSimulation()
        
        timer = Timer.scheduledTimer(withTimeInterval: AppConstants.audioUpdateInterval, repeats: true) { _ in
            self.updateLevels(isEnabled: isEnabled, sensitivity: sensitivity)
        }
    }
    
    func stopSimulation() {
        timer?.invalidate()
        timer = nil
    }
    
    private func updateLevels(isEnabled: Bool, sensitivity: Double) {
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