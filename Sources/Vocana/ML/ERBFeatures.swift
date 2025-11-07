import Foundation
import Accelerate

/// ERB (Equivalent Rectangular Bandwidth) feature extraction
/// Implements perceptually-motivated frequency analysis for audio processing
class ERBFeatures {
    // MARK: - Configuration
    
    private let numBands: Int
    private let sampleRate: Int
    private let fftSize: Int
    private let erbFilterbank: [[Float]]
    
    // MARK: - Initialization
    
    init(numBands: Int = 32, sampleRate: Int = 48000, fftSize: Int = 960) {
        self.numBands = numBands
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        
        // Generate ERB filterbank
        self.erbFilterbank = ERBFeatures.generateERBFilterbank(
            numBands: numBands,
            sampleRate: sampleRate,
            fftSize: fftSize
        )
    }
    
    // MARK: - ERB Filterbank Generation
    
    /// Generate ERB filterbank based on human auditory perception
    /// ERB scale approximates the frequency resolution of the human ear
    private static func generateERBFilterbank(numBands: Int, sampleRate: Int, fftSize: Int) -> [[Float]] {
        let numFreqBins = fftSize / 2 + 1
        
        // Frequency range: 0 to Nyquist
        let nyquistFreq = Float(sampleRate) / 2.0
        let freqResolution = Float(sampleRate) / Float(fftSize)
        
        // ERB scale parameters (Glasberg & Moore, 1990)
        let minFreq: Float = 50.0  // Minimum frequency (Hz)
        let maxFreq = min(nyquistFreq, 20000.0)  // Maximum frequency (Hz)
        
        // Convert to ERB scale
        let minERB = frequencyToERB(minFreq)
        let maxERB = frequencyToERB(maxFreq)
        
        // ERB center frequencies (linearly spaced in ERB scale)
        var erbCenters = [Float]()
        for i in 0..<numBands {
            let erbValue = minERB + Float(i) * (maxERB - minERB) / Float(numBands - 1)
            let freqValue = erbToFrequency(erbValue)
            erbCenters.append(freqValue)
        }
        
        // Build filterbank
        var filterbank = [[Float]]()
        for centerFreq in erbCenters {
            var filter = [Float](repeating: 0, count: numFreqBins)
            
            // Calculate ERB bandwidth
            let bandwidth = erbBandwidth(centerFreq)
            
            // Generate triangular filter
            for bin in 0..<numFreqBins {
                let freq = Float(bin) * freqResolution
                
                // Triangular filter centered at centerFreq
                let distance = abs(freq - centerFreq)
                if distance < bandwidth {
                    filter[bin] = max(0, 1.0 - distance / bandwidth)
                }
            }
            
            // Normalize filter to sum to 1
            let filterSum = filter.reduce(0, +)
            if filterSum > 0 {
                filter = filter.map { $0 / filterSum }
            }
            
            filterbank.append(filter)
        }
        
        return filterbank
    }
    
    // MARK: - ERB Scale Conversions
    
    /// Convert frequency (Hz) to ERB scale
    /// ERB(f) = 21.4 * log10(1 + 0.00437 * f)
    private static func frequencyToERB(_ freq: Float) -> Float {
        return 21.4 * log10(1.0 + 0.00437 * freq)
    }
    
    /// Convert ERB scale to frequency (Hz)
    /// f = (10^(ERB/21.4) - 1) / 0.00437
    private static func erbToFrequency(_ erb: Float) -> Float {
        return (pow(10.0, erb / 21.4) - 1.0) / 0.00437
    }
    
    /// Calculate ERB bandwidth at a given frequency
    /// Bandwidth = 24.7 * (0.00437 * f + 1)
    private static func erbBandwidth(_ freq: Float) -> Float {
        return 24.7 * (0.00437 * freq + 1.0)
    }
    
    // MARK: - Feature Extraction
    
    /// Extract ERB features from complex spectrogram
    /// - Parameters:
    ///   - spectrogramReal: Real part of spectrogram [numFrames, numBins]
    ///   - spectrogramImag: Imaginary part of spectrogram [numFrames, numBins]
    /// - Returns: ERB features [numFrames, numBands]
    func extract(spectrogramReal: [[Float]], spectrogramImag: [[Float]]) -> [[Float]] {
        guard spectrogramReal.count == spectrogramImag.count else {
            return []
        }
        
        let numFrames = spectrogramReal.count
        var erbFeatures: [[Float]] = []
        
        for frameIndex in 0..<numFrames {
            let realPart = spectrogramReal[frameIndex]
            let imagPart = spectrogramImag[frameIndex]
            
            // Calculate magnitude spectrum
            var magnitudeSpectrum = [Float](repeating: 0, count: realPart.count)
            for i in 0..<realPart.count {
                let magnitude = sqrt(realPart[i] * realPart[i] + imagPart[i] * imagPart[i])
                magnitudeSpectrum[i] = magnitude
            }
            
            // Apply ERB filterbank
            var erbFrame = [Float](repeating: 0, count: numBands)
            for (bandIndex, filter) in erbFilterbank.enumerated() {
                // Weighted sum of magnitude spectrum
                var bandEnergy: Float = 0
                for i in 0..<min(filter.count, magnitudeSpectrum.count) {
                    bandEnergy += filter[i] * magnitudeSpectrum[i]
                }
                erbFrame[bandIndex] = bandEnergy
            }
            
            erbFeatures.append(erbFrame)
        }
        
        return erbFeatures
    }
    
    // MARK: - Normalization
    
    /// Apply unit normalization with alpha parameter
    /// This matches the libdf normalization: unit_norm(x, alpha)
    /// - Parameters:
    ///   - features: Input features [numFrames, numBands]
    ///   - alpha: Normalization parameter (default from DeepFilterNet)
    /// - Returns: Normalized features
    func normalize(_ features: [[Float]], alpha: Float = 0.6) -> [[Float]] {
        guard !features.isEmpty else { return [] }
        
        var normalized: [[Float]] = []
        
        for frame in features {
            var normalizedFrame = [Float](repeating: 0, count: frame.count)
            
            // Calculate mean
            let mean = frame.reduce(0, +) / Float(frame.count)
            
            // Calculate variance
            var variance: Float = 0
            for value in frame {
                let diff = value - mean
                variance += diff * diff
            }
            variance /= Float(frame.count)
            
            // Standard deviation
            let std = sqrt(variance + 1e-8)  // Add small epsilon to avoid division by zero
            
            // Unit normalization: (x - mean) / std
            for i in 0..<frame.count {
                normalizedFrame[i] = (frame[i] - mean) / (std + 1e-8)
                
                // Apply alpha scaling (optional, matches libdf)
                normalizedFrame[i] *= alpha
            }
            
            normalized.append(normalizedFrame)
        }
        
        return normalized
    }
    
    // MARK: - Utilities
    
    /// Get the ERB center frequencies
    var centerFrequencies: [Float] {
        var centers = [Float]()
        let minFreq: Float = 50.0
        let nyquistFreq = Float(sampleRate) / 2.0
        let maxFreq = min(nyquistFreq, 20000.0)
        
        let minERB = ERBFeatures.frequencyToERB(minFreq)
        let maxERB = ERBFeatures.frequencyToERB(maxFreq)
        
        for i in 0..<numBands {
            let erbValue = minERB + Float(i) * (maxERB - minERB) / Float(numBands - 1)
            let freqValue = ERBFeatures.erbToFrequency(erbValue)
            centers.append(freqValue)
        }
        
        return centers
    }
}
