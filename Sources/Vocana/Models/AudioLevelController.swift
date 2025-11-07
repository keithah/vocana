import Foundation
import os.log

/// Manages audio input/output level calculations and decay
/// Responsibility: Calculate RMS levels, apply decay, validate audio input
/// Isolated from audio capture, buffering, and ML processing
class AudioLevelController {
    private static let logger = Logger(subsystem: "Vocana", category: "AudioLevelController")
    
    private var currentLevels = AudioLevels.zero
    
    /// Calculate RMS level from unsafe buffer pointer (avoids array allocation)
    /// - Parameter samplesPtr: Unsafe buffer pointer to audio samples
    /// - Returns: RMS level normalized to 0-1 range
    func calculateRMSFromPointer(_ samplesPtr: UnsafeBufferPointer<Float>) -> Float {
        guard samplesPtr.count > 0 else { return 0 }
        
        // Calculate RMS using pointer iteration (avoids array allocation)
        var sumOfSquares: Float = 0
        for sample in samplesPtr {
            sumOfSquares += sample * sample
        }
        let rms = sqrt(sumOfSquares / Float(samplesPtr.count))
        
        // Convert to 0-1 range and apply amplification
        return min(1.0, rms * AppConstants.rmsAmplificationFactor)
    }
    
    /// Calculate raw RMS value from audio samples (for validation purposes)
    /// - Parameter samples: Audio samples to calculate RMS from
    /// - Returns: Raw RMS value (not normalized)
    /// - Note: This is used for validation thresholds; use calculateRMS for display
    func calculateRawRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return sqrt(sum / Float(samples.count))
    }
    
    /// Calculate normalized RMS level for audio display/processing
    /// Consolidates RMS calculation logic for array inputs
    /// - Parameter samples: Audio samples to calculate RMS from
    /// - Returns: RMS level normalized to 0-1 range
    func calculateRMS(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        
        let rms = calculateRawRMS(samples)
        
        // Convert to 0-1 range (typical audio is -1 to 1, RMS will be much smaller)
        return min(1.0, rms * AppConstants.rmsAmplificationFactor)
    }
    
    /// Validate audio samples for range and quality issues
    /// - Parameter samples: Audio samples to validate
    /// - Returns: true if audio is valid for processing, false if validation fails
    func validateAudioInput(_ samples: [Float]) -> Bool {
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
        let rms = calculateRawRMS(samples)
        
        guard rms <= AppConstants.maxRMSLevel else {
            Self.logger.warning("Audio input RMS \(String(format: "%.3f", rms)) exceeds max level \(AppConstants.maxRMSLevel) - possible distortion")
            return false
        }
        
        return true
    }
    
    /// Apply level decay for visual smoothing
    /// - Returns: Decayed audio levels
    func applyDecay() -> AudioLevels {
        let decayedInput = max(currentLevels.input * AppConstants.levelDecayRate, 0)
        let decayedOutput = max(currentLevels.output * AppConstants.levelDecayRate, 0)
        currentLevels = AudioLevels(input: decayedInput, output: decayedOutput)
        return currentLevels
    }
    
    /// Update current levels
    /// - Parameters:
    ///   - input: Input level (0-1)
    ///   - output: Output level (0-1)
    func updateLevels(input: Float, output: Float) {
        currentLevels = AudioLevels(input: input, output: output)
    }
    
    /// Get current levels
    /// - Returns: Current audio levels
    func getLevels() -> AudioLevels {
        return currentLevels
    }
    
    /// Update simulated levels for testing
    /// Used during simulated audio playback
    func updateSimulatedLevels() {
        // Generate random levels for UI testing
        let randomInput = Float.random(in: 0.1...0.8)
        let randomOutput = Float.random(in: 0.05...0.6)
        updateLevels(input: randomInput, output: randomOutput)
    }
}
