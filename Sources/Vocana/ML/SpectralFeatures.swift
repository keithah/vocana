import Foundation
import Accelerate

/// Spectral feature extraction for DeepFilterNet
/// Extracts first N frequency bins with unit normalization
class SpectralFeatures {
    // MARK: - Configuration
    
    private let dfBands: Int  // Number of Deep Filtering bands
    private let sampleRate: Int
    private let fftSize: Int
    
    // MARK: - Initialization
    
    init(dfBands: Int = 96, sampleRate: Int = 48000, fftSize: Int = 960) {
        self.dfBands = dfBands
        self.sampleRate = sampleRate
        self.fftSize = fftSize
    }
    
    // MARK: - Feature Extraction
    
    /// Extract spectral features from complex spectrogram
    /// Returns first `dfBands` frequency bins in real/imaginary format
    /// - Parameters:
    ///   - spectrogramReal: Real part of spectrogram [numFrames, numBins]
    ///   - spectrogramImag: Imaginary part of spectrogram [numFrames, numBins]
    /// - Returns: Spectral features [numFrames, 2, dfBands] (2 channels: real, imag)
    func extract(spectrogramReal: [[Float]], spectrogramImag: [[Float]]) -> [[[Float]]] {
        guard spectrogramReal.count == spectrogramImag.count else {
            return []
        }
        
        let numFrames = spectrogramReal.count
        var spectralFeatures: [[[Float]]] = []
        
        for frameIndex in 0..<numFrames {
            let realPart = spectrogramReal[frameIndex]
            let imagPart = spectrogramImag[frameIndex]
            
            // Extract first dfBands bins
            let numBins = min(dfBands, realPart.count)
            var realChannel = Array(realPart[0..<numBins])
            var imagChannel = Array(imagPart[0..<numBins])
            
            // Pad with zeros if needed
            while realChannel.count < dfBands {
                realChannel.append(0)
                imagChannel.append(0)
            }
            
            // Create 2-channel output [2, dfBands]
            let frameFeatures = [realChannel, imagChannel]
            spectralFeatures.append(frameFeatures)
        }
        
        return spectralFeatures
    }
    
    // MARK: - Normalization
    
    /// Apply unit normalization to spectral features
    /// Normalizes across the complex spectrum
    /// - Parameters:
    ///   - features: Input features [numFrames, 2, dfBands]
    ///   - alpha: Normalization parameter
    /// - Returns: Normalized features
    func normalize(_ features: [[[Float]]], alpha: Float = 0.6) -> [[[Float]]] {
        guard !features.isEmpty else { return [] }
        
        var normalized: [[[Float]]] = []
        
        for frame in features {
            guard frame.count == 2 else {
                normalized.append(frame)
                continue
            }
            
            let realPart = frame[0]
            let imagPart = frame[1]
            
            // Calculate magnitude for normalization
            var magnitudes = [Float](repeating: 0, count: realPart.count)
            for i in 0..<realPart.count {
                magnitudes[i] = sqrt(realPart[i] * realPart[i] + imagPart[i] * imagPart[i])
            }
            
            // Calculate mean magnitude
            let meanMag = magnitudes.reduce(0, +) / Float(magnitudes.count)
            
            // Calculate variance
            var variance: Float = 0
            for mag in magnitudes {
                let diff = mag - meanMag
                variance += diff * diff
            }
            variance /= Float(magnitudes.count)
            
            // Standard deviation
            let std = sqrt(variance + 1e-8)
            
            // Normalize real and imaginary parts
            var normalizedReal = [Float](repeating: 0, count: realPart.count)
            var normalizedImag = [Float](repeating: 0, count: imagPart.count)
            
            for i in 0..<realPart.count {
                normalizedReal[i] = realPart[i] / (std + 1e-8) * alpha
                normalizedImag[i] = imagPart[i] / (std + 1e-8) * alpha
            }
            
            normalized.append([normalizedReal, normalizedImag])
        }
        
        return normalized
    }
    
    // MARK: - Utilities
    
    /// Get frequency range covered by DF bands
    var frequencyRange: (min: Float, max: Float) {
        let freqResolution = Float(sampleRate) / Float(fftSize)
        let maxFreq = freqResolution * Float(dfBands)
        return (0, maxFreq)
    }
    
    /// Get number of DF bands
    var numberOfBands: Int {
        return dfBands
    }
}
