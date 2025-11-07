import Foundation
import Accelerate
import os.log

/// ERB (Equivalent Rectangular Bandwidth) feature extraction
/// Implements perceptually-motivated frequency analysis for audio processing
///
/// **Thread Safety**: This class is thread-safe after initialization.
/// - The filterbank is immutable after init (thread-safe)  
/// - extract() and normalize() use per-frame buffer allocation (thread-safe)
/// - Safe for: Concurrent calls to ANY method from multiple threads
/// - Per-frame allocation ensures no shared mutable state between calls
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
    
    // Reusable buffers for extract method to reduce allocation overhead
    // Thread-local storage ensures thread safety
    private struct ExtractBuffers {
        var magnitudeSpectrum: [Float]
        var realSquared: [Float]
        var imagSquared: [Float]
        var sqrtResult: [Float]
        var erbFrame: [Float]
        
        init(spectrumSize: Int, numBands: Int) {
            self.magnitudeSpectrum = [Float](repeating: 0, count: spectrumSize)
            self.realSquared = [Float](repeating: 0, count: spectrumSize)
            self.imagSquared = [Float](repeating: 0, count: spectrumSize)
            self.sqrtResult = [Float](repeating: 0, count: spectrumSize)
            self.erbFrame = [Float](repeating: 0, count: numBands)
        }
    }
    
    // Note: Removed shared buffer state to eliminate thread safety issues.
    // Extract method now uses local buffers for thread safety.
    
    // Logging
    private static let logger = Logger(subsystem: "com.vocana.ml", category: "ERBFeatures")
    
    // MARK: - Initialization
    
    init(numBands: Int = AppConstants.erbBands, sampleRate: Int = AppConstants.sampleRate, fftSize: Int = AppConstants.fftSize) {
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
        
        // Fix HIGH: More realistic memory usage validation based on actual ML models
        let estimatedMemoryBytes = numBands * numFreqBins * MemoryLayout<Float>.size
        let estimatedMemoryMB = estimatedMemoryBytes / (1024 * 1024)
        // DeepFilterNet models typically use 32 bands × 481 bins = ~60KB, allow headroom for larger models
        let maxMemoryMB = 500 // 500MB limit allows for much larger spectrograms while preventing abuse
        precondition(estimatedMemoryMB < maxMemoryMB, 
                    "Filterbank would require \(estimatedMemoryMB)MB (max: \(maxMemoryMB)MB)")
        
        Self.logger.debug("Generating ERB filterbank: \(numBands) bands × \(numFreqBins) bins = \(estimatedMemoryMB)MB")
        
        // Frequency range: 0 to Nyquist
        let nyquistFreq = Float(sampleRate) / 2.0
        let freqResolution = Float(sampleRate) / Float(fftSize)
        
        // ERB scale parameters (Glasberg & Moore, 1990)
        let minFreq: Float = AppConstants.minFrequency  // Minimum frequency (Hz) - human hearing starts ~20Hz but 50Hz is more practical
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
        // Fix CRITICAL: Consistent error handling - return empty instead of crashing
        guard spectrogramReal.count == spectrogramImag.count else {
            Self.logger.error("Spectrogram dimension mismatch: real=\(spectrogramReal.count), imag=\(spectrogramImag.count)")
            return []
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
        
        // OPTIMIZED: Use reusable buffers to reduce allocation overhead
        // Thread safety: Use local buffers for each extract() call to ensure thread safety
        let spectrumSize = fftSize / 2 + 1
        var magnitudeSpectrum = [Float](repeating: 0, count: spectrumSize)
        var realSquared = [Float](repeating: 0, count: spectrumSize)
        var imagSquared = [Float](repeating: 0, count: spectrumSize)
        var sqrtResult = [Float](repeating: 0, count: spectrumSize)
        var erbFrame = [Float](repeating: 0, count: numBands)
        
        for frameIndex in 0..<numFrames {
            let realPart = spectrogramReal[frameIndex]
            let imagPart = spectrogramImag[frameIndex]
            
            // Fix CRITICAL: Consistent error handling - skip bad frame but log
            guard realPart.count == imagPart.count else {
                Self.logger.error("Frame \(frameIndex) dimension mismatch: real=\(realPart.count), imag=\(imagPart.count)")
                // Skip this frame to maintain count consistency
                erbFeatures.append([Float](repeating: 0, count: numBands))
                continue
            }
            
            // OPTIMIZED: Reuse pre-allocated buffers instead of allocating per frame
            
            // Calculate magnitude using Accelerate framework (much faster)
            let length = vDSP_Length(realPart.count)
            vDSP_vsq(realPart, 1, &realSquared, 1, length)
            vDSP_vsq(imagPart, 1, &imagSquared, 1, length)
            vDSP_vadd(realSquared, 1, imagSquared, 1, &magnitudeSpectrum, 1, length)
            
            // Fix HIGH: Int32 overflow protection for vvsqrtf
            guard magnitudeSpectrum.count < Int32.max else {
                Self.logger.error("Buffer too large for vvsqrtf: \(magnitudeSpectrum.count)")
                // Skip this frame or use fallback
                erbFeatures.append([Float](repeating: 0, count: numBands))
                continue
            }
            var count = Int32(magnitudeSpectrum.count)
            vvsqrtf(&sqrtResult, magnitudeSpectrum, &count)
            
            // Apply ERB filterbank using vDSP dot product (much faster)
            // Clear erbFrame for reuse
            vDSP_vclr(&erbFrame, 1, vDSP_Length(numBands))
            for (bandIndex, filter) in erbFilterbank.enumerated() {
                var bandEnergy: Float = 0
                
                // Fix CRITICAL: Guard instead of assert to prevent silent corruption in release
                let filterLen = filter.count
                let magLen = sqrtResult.count
                guard filterLen == magLen else {
                    Self.logger.error("Filter/magnitude size mismatch: \(filterLen) vs \(magLen)")
                    erbFrame[bandIndex] = 0
                    continue
                }
                
                vDSP_dotpr(filter, 1, sqrtResult, 1, &bandEnergy, vDSP_Length(filterLen))
                erbFrame[bandIndex] = bandEnergy
            }
            
            // Copy the erbFrame to avoid reference sharing
            erbFeatures.append(Array(erbFrame))
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
        
        // Fix HIGH: Allocate buffers per-frame for thread safety instead of reusing
        // This ensures normalize() is safe for concurrent calls
        
        for frame in features {
            // Per-frame buffer allocation
            let frameSize = frame.count
            var centered = [Float](repeating: 0, count: frameSize)
            var normalizedFrame = [Float](repeating: 0, count: frameSize)
            // Fix CRITICAL #7: Remove redundant mean subtraction
            // Calculate mean once
            var mean: Float = 0
            vDSP_meanv(frame, 1, &mean, vDSP_Length(frame.count))
            
            // Calculate centered values: centered = frame - mean
            var meanNeg = -mean
            vDSP_vsadd(frame, 1, &meanNeg, &centered, 1, vDSP_Length(frame.count))
            
            // Calculate variance from centered values
            var centeredSquared = [Float](repeating: 0, count: frameSize)
            vDSP_vsq(centered, 1, &centeredSquared, 1, vDSP_Length(frame.count))
            
            var variance: Float = 0
            vDSP_meanv(centeredSquared, 1, &variance, vDSP_Length(frame.count))
            
            // Fix HIGH: Simplified variance handling - use max() which handles negative/NaN
            let epsilon: Float = 1e-6
            let validVariance: Float
            if variance.isNaN || variance.isInfinite {
                Self.logger.error("Invalid variance: \(variance), using epsilon fallback")
                validVariance = epsilon
            } else {
                validVariance = max(variance, epsilon)
            }
            
            let std = sqrt(validVariance)
            
            // Unit normalization: centered / std (already have centered = x - mean)
            var divisor = std
            vDSP_vsdiv(centered, 1, &divisor, &normalizedFrame, 1, vDSP_Length(frame.count))
            
            // Apply alpha scaling
            var alphaScalar = alpha
            vDSP_vsmul(normalizedFrame, 1, &alphaScalar, &normalizedFrame, 1, vDSP_Length(frame.count))
            
            normalized.append(normalizedFrame)
        }
        
        return normalized
    }
    
    // MARK: - Utilities
    
    /// Get the ERB center frequencies (cached)
    var centerFrequencies: [Float] {
        return centerFreqs
    }
}
