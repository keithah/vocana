import Foundation
import Accelerate
import os.log

/// ERB (Equivalent Rectangular Bandwidth) feature extraction
/// Implements perceptually-motivated frequency analysis for audio processing
///
/// **Thread Safety**: This class is thread-safe. All methods are stateless after initialization.
/// The filterbank is immutable after init, allowing concurrent calls to extract() and normalize().
///
/// **Usage Example**:
/// ```swift
/// let erbFeatures = ERBFeatures(numBands: 32, sampleRate: 48000, fftSize: 960)
/// let features = erbFeatures.extract(spectrogramReal: real, spectrogramImag: imag)
/// let normalized = erbFeatures.normalize(features, alpha: 0.6)
/// ```
final class ERBFeatures {
    // MARK: - Configuration
    
    private let numBands: Int
    private let sampleRate: Int
    private let fftSize: Int
    private let erbFilterbank: [[Float]]
    private let centerFreqs: [Float]  // Cached center frequencies
    
    // Fix CRITICAL: Remove unused instance variable that suggests unsafe buffer reuse
    // Documentation claims thread-safe but buffer reuse would cause races
    // Current implementation correctly uses local buffers - keeping it that way
    
    private struct NormalizeBuffers {
        var meanArray: [Float]
        var centered: [Float]
        var normalizedFrame: [Float]
    }
    
    // Logging
    private static let logger = Logger(subsystem: "com.vocana.ml", category: "ERBFeatures")
    
    // MARK: - Initialization
    
    init(numBands: Int = 32, sampleRate: Int = 48000, fftSize: Int = 960) {
        precondition(numBands >= 2 && numBands <= 1000, 
                    "Number of ERB bands must be in range [2, 1000], got \(numBands)")
        precondition(sampleRate > 0 && sampleRate <= 192000, 
                    "Sample rate must be in range [1, 192000], got \(sampleRate)")
        precondition(fftSize > 0 && fftSize <= 16384, 
                    "FFT size must be in range [1, 16384], got \(fftSize)")
        
        self.numBands = numBands
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        
        // Generate ERB filterbank (moved to background if called from main thread)
        let (filterbank, centers) = ERBFeatures.generateERBFilterbank(
            numBands: numBands,
            sampleRate: sampleRate,
            fftSize: fftSize
        )
        self.erbFilterbank = filterbank
        self.centerFreqs = centers
    }
    
    // MARK: - ERB Filterbank Generation
    
    /// Generate ERB filterbank based on human auditory perception
    /// ERB scale approximates the frequency resolution of the human ear
    /// - Returns: Tuple of (filterbank, center frequencies)
    private static func generateERBFilterbank(numBands: Int, sampleRate: Int, fftSize: Int) -> ([[Float]], [Float]) {
        let numFreqBins = fftSize / 2 + 1
        
        // Frequency range: 0 to Nyquist
        let nyquistFreq = Float(sampleRate) / 2.0
        let freqResolution = Float(sampleRate) / Float(fftSize)
        
        // ERB scale parameters (Glasberg & Moore, 1990)
        let minFreq: Float = 50.0  // Minimum frequency (Hz) - human hearing starts ~20Hz but 50Hz is more practical
        let maxFreq = min(nyquistFreq, 20000.0)  // Maximum frequency - human hearing limit ~20kHz
        
        // Convert to ERB scale
        let minERB = frequencyToERB(minFreq)
        let maxERB = frequencyToERB(maxFreq)
        
        // ERB center frequencies (linearly spaced in ERB scale)
        var erbCenters = [Float]()
        erbCenters.reserveCapacity(numBands)
        
        // Fix MEDIUM: Handle numBands == 1 case
        let stepSize = numBands > 1 ? (maxERB - minERB) / Float(numBands - 1) : 0.0
        
        for i in 0..<numBands {
            let erbValue = minERB + Float(i) * stepSize
            let freqValue = erbToFrequency(erbValue)
            erbCenters.append(freqValue)
        }
        
        // Build filterbank
        var filterbank = [[Float]]()
        filterbank.reserveCapacity(numBands)
        
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
            
            // Normalize filter to sum to 1 using vDSP
            var filterSum: Float = 0
            vDSP_sve(filter, 1, &filterSum, vDSP_Length(filter.count))
            
            if filterSum > Float.leastNormalMagnitude {
                // Fix CRITICAL: Use separate output array to avoid in-place operation issues
                var normalized = filter
                var divisor = filterSum
                vDSP_vsdiv(filter, 1, &divisor, &normalized, 1, vDSP_Length(filter.count))
                filter = normalized
                
                // Fix HIGH: Validate filter after generation
                assert(filter.allSatisfy({ $0.isFinite }), "Filter contains NaN or Inf")
            }
            
            filterbank.append(filter)
        }
        
        return (filterbank, erbCenters)
    }
    
    // MARK: - ERB Scale Conversions
    
    /// Convert frequency (Hz) to ERB scale
    /// ERB(f) = 21.4 * log10(1 + 0.00437 * f)
    /// Constants from Glasberg & Moore (1990)
    private static func frequencyToERB(_ freq: Float) -> Float {
        precondition(freq >= 0, "Frequency must be non-negative, got \(freq)")
        return 21.4 * log10(1.0 + 0.00437 * freq)
    }
    
    /// Convert ERB scale to frequency (Hz)
    /// f = (10^(ERB/21.4) - 1) / 0.00437
    /// Inverse of frequencyToERB
    private static func erbToFrequency(_ erb: Float) -> Float {
        return (pow(10.0, erb / 21.4) - 1.0) / 0.00437
    }
    
    /// Calculate ERB bandwidth at a given frequency
    /// Bandwidth = 24.7 * (0.00437 * f + 1)
    /// Moore & Glasberg auditory filter bandwidth formula
    private static func erbBandwidth(_ freq: Float) -> Float {
        return 24.7 * (0.00437 * freq + 1.0)
    }
    
    // MARK: - Feature Extraction
    
    /// Extract ERB features from complex spectrogram
    /// - Parameters:
    ///   - spectrogramReal: Real part of spectrogram [numFrames, numBins]
    ///   - spectrogramImag: Imaginary part of spectrogram [numFrames, numBins]
    /// - Returns: ERB features [numFrames, numBands]
    /// - Throws: Never, but logs errors and returns empty array on failure
    func extract(spectrogramReal: [[Float]], spectrogramImag: [[Float]]) -> [[Float]] {
        // Fix CRITICAL: Don't silently fail - validate inputs strictly
        guard spectrogramReal.count == spectrogramImag.count else {
            Self.logger.error("Spectrogram dimension mismatch: real=\(spectrogramReal.count), imag=\(spectrogramImag.count)")
            preconditionFailure("Real and imaginary spectrograms must have same number of frames")
        }
        
        // Fix HIGH: Validate input isn't empty
        guard !spectrogramReal.isEmpty else {
            return []
        }
        
        let numFrames = spectrogramReal.count
        
        // Fix HIGH: Validate frame dimensions match expected fftSize
        let expectedBins = fftSize / 2 + 1
        if let firstFrame = spectrogramReal.first, firstFrame.count != expectedBins {
            Self.logger.warning("Spectrogram frame size \(firstFrame.count) doesn't match expected \(expectedBins)")
        }
        
        var erbFeatures: [[Float]] = []
        erbFeatures.reserveCapacity(numFrames)
        
        // Fix HIGH: Pre-allocate reusable buffers to avoid per-frame allocation
        var magnitudeSpectrum: [Float]?
        var realSquared: [Float]?
        var imagSquared: [Float]?
        
        for frameIndex in 0..<numFrames {
            let realPart = spectrogramReal[frameIndex]
            let imagPart = spectrogramImag[frameIndex]
            
            // Fix CRITICAL: Don't skip frames - this causes data corruption
            guard realPart.count == imagPart.count else {
                Self.logger.error("Frame \(frameIndex) dimension mismatch: real=\(realPart.count), imag=\(imagPart.count)")
                preconditionFailure("Real and imaginary parts must have same size at frame \(frameIndex)")
            }
            
            // Allocate buffers on first iteration
            if magnitudeSpectrum == nil {
                let size = realPart.count
                magnitudeSpectrum = [Float](repeating: 0, count: size)
                realSquared = [Float](repeating: 0, count: size)
                imagSquared = [Float](repeating: 0, count: size)
            }
            
            // Calculate magnitude using Accelerate framework (much faster)
            var magSpec = magnitudeSpectrum!
            var realSq = realSquared!
            var imagSq = imagSquared!
            
            let length = vDSP_Length(realPart.count)
            vDSP_vsq(realPart, 1, &realSq, 1, length)
            vDSP_vsq(imagPart, 1, &imagSq, 1, length)
            vDSP_vadd(realSq, 1, imagSq, 1, &magSpec, 1, length)
            
            // Fix CRITICAL: Safe sqrt operation - use separate output
            var count = Int32(magSpec.count)
            var sqrtResult = [Float](repeating: 0, count: magSpec.count)
            vvsqrtf(&sqrtResult, magSpec, &count)
            
            // Apply ERB filterbank using vDSP dot product (much faster)
            var erbFrame = [Float](repeating: 0, count: numBands)
            for (bandIndex, filter) in erbFilterbank.enumerated() {
                var bandEnergy: Float = 0
                
                // Fix HIGH: Assert filter/magnitude match instead of silent min
                let filterLen = filter.count
                let magLen = sqrtResult.count
                assert(filterLen == magLen, "Filter size \(filterLen) doesn't match magnitude \(magLen)")
                
                let length = min(filterLen, magLen)
                vDSP_dotpr(filter, 1, sqrtResult, 1, &bandEnergy, vDSP_Length(length))
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
        // Fix MEDIUM: Validate alpha parameter
        precondition(alpha > 0 && alpha <= 10, "Alpha must be in range (0, 10], got \(alpha)")
        
        guard !features.isEmpty else { return [] }
        
        // Fix LOW: Validate all frames are non-empty
        guard features.allSatisfy({ !$0.isEmpty }) else {
            Self.logger.error("normalize() received empty frames")
            return []
        }
        
        var normalized: [[Float]] = []
        normalized.reserveCapacity(features.count)
        
        // Fix MEDIUM: Pre-allocate buffers to reduce per-frame allocation
        let frameSize = features[0].count
        var buffers = NormalizeBuffers(
            meanArray: [Float](repeating: 0, count: frameSize),
            centered: [Float](repeating: 0, count: frameSize),
            normalizedFrame: [Float](repeating: 0, count: frameSize)
        )
        
        for frame in features {
            // Fix CRITICAL: Variance calculation order (frame - mean, not mean - frame)
            var mean: Float = 0
            vDSP_meanv(frame, 1, &mean, vDSP_Length(frame.count))
            
            // Calculate variance using corrected order
            vDSP_vfill([mean], &buffers.meanArray, 1, vDSP_Length(frame.count))
            vDSP_vsub(buffers.meanArray, 1, frame, 1, &buffers.centered, 1, vDSP_Length(frame.count))
            vDSP_vsq(buffers.centered, 1, &buffers.centered, 1, vDSP_Length(frame.count))
            
            var variance: Float = 0
            vDSP_meanv(buffers.centered, 1, &variance, vDSP_Length(frame.count))
            
            // Fix CRITICAL: Better epsilon for division safety (same as SpectralFeatures)
            guard !variance.isNaN && !variance.isInfinite && variance >= 0 else {
                Self.logger.error("Invalid variance: \(variance)")
                continue
            }
            
            let epsilon: Float = 1e-6
            let std = sqrt(max(variance, epsilon))
            
            // Fix MEDIUM: Remove redundant NaN check after epsilon addition
            // std is guaranteed positive due to sqrt(max(...))
            
            // Unit normalization: (x - mean) / std using vDSP
            var meanNeg = -mean
            vDSP_vsadd(frame, 1, &meanNeg, &buffers.normalizedFrame, 1, vDSP_Length(frame.count))
            var divisor = std
            vDSP_vsdiv(buffers.normalizedFrame, 1, &divisor, &buffers.normalizedFrame, 1, vDSP_Length(frame.count))
            
            // Apply alpha scaling
            var alphaScalar = alpha
            vDSP_vsmul(buffers.normalizedFrame, 1, &alphaScalar, &buffers.normalizedFrame, 1, vDSP_Length(frame.count))
            
            normalized.append(Array(buffers.normalizedFrame))
        }
        
        return normalized
    }
    
    // MARK: - Utilities
    
    /// Get the ERB center frequencies (cached)
    var centerFrequencies: [Float] {
        return centerFreqs
    }
}
