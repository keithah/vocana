import Foundation
import Accelerate
import os.log

/// Spectral feature extraction for DeepFilterNet
/// Extracts first N frequency bins with unit normalization
///
/// **Thread Safety**: This class is thread-safe. All methods are stateless after initialization.
/// Safe to call from multiple threads simultaneously.
///
/// **Usage Example**:
/// ```swift
/// let spectral = SpectralFeatures(dfBands: 96, sampleRate: 48000, fftSize: 960)
/// let features = spectral.extract(spectrogramReal: real, spectrogramImag: imag)
/// let normalized = spectral.normalize(features, alpha: 0.6)
/// ```
final class SpectralFeatures {
    // MARK: - Configuration
    
    private let dfBands: Int  // Number of Deep Filtering bands
    private let sampleRate: Int
    private let fftSize: Int
    
    // Cached computed properties
    private let freqRange: (min: Float, max: Float)
    
    // Logging
    private static let logger = Logger(subsystem: "com.vocana.ml", category: "SpectralFeatures")
    
    // MARK: - Initialization
    
    init(dfBands: Int = 96, sampleRate: Int = 48000, fftSize: Int = 960) {
        // Fix HIGH: Validate dfBands doesn't exceed available FFT bins
        let maxBands = fftSize / 2 + 1
        precondition(dfBands > 0 && dfBands <= maxBands, 
                    "DF bands must be in range [1, \(maxBands)] for FFT size \(fftSize), got \(dfBands)")
        precondition(sampleRate > 0 && sampleRate <= 192000, 
                    "Sample rate must be in range [1, 192000], got \(sampleRate)")
        precondition(fftSize > 0 && fftSize <= 16384, 
                    "FFT size must be in range [1, 16384], got \(fftSize)")
        
        self.dfBands = dfBands
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        
        // Fix LOW: Cache frequency range
        let freqResolution = Float(sampleRate) / Float(fftSize)
        let maxFreq = freqResolution * Float(dfBands)
        self.freqRange = (0, maxFreq)
    }
    
    // MARK: - Feature Extraction
    
    /// Extract spectral features from complex spectrogram
    /// Returns first `dfBands` frequency bins in real/imaginary format
    /// - Parameters:
    ///   - spectrogramReal: Real part of spectrogram [numFrames, numBins]
    ///   - spectrogramImag: Imaginary part of spectrogram [numFrames, numBins]
    /// - Returns: Spectral features [numFrames, 2, dfBands] (2 channels: real, imag)
    func extract(spectrogramReal: [[Float]], spectrogramImag: [[Float]]) -> [[[Float]]] {
        // Fix CRITICAL: Don't silently fail - precondition for dimension mismatch
        precondition(spectrogramReal.count == spectrogramImag.count,
                    "Spectrogram dimension mismatch: real=\(spectrogramReal.count), imag=\(spectrogramImag.count)")
        
        // Fix HIGH: Validate input isn't excessively large (prevent DoS)
        let maxFrames = 100_000  // ~35 minutes at 48kHz with 480 hop
        precondition(spectrogramReal.count <= maxFrames,
                    "Too many frames: \(spectrogramReal.count) (max: \(maxFrames))")
        
        let numFrames = spectrogramReal.count
        
        // Fix MEDIUM: Pre-allocate with reserveCapacity
        var spectralFeatures: [[[Float]]] = []
        spectralFeatures.reserveCapacity(numFrames)
        
        // Fix MEDIUM: Validate frame dimensions match expected
        let expectedBins = fftSize / 2 + 1
        if let firstReal = spectrogramReal.first, firstReal.count != expectedBins {
            Self.logger.warning("Spectrogram has \(firstReal.count) bins, expected \(expectedBins)")
        }
        
        for frameIndex in 0..<numFrames {
            let realPart = spectrogramReal[frameIndex]
            let imagPart = spectrogramImag[frameIndex]
            
            // Fix HIGH: Don't skip frames - causes temporal misalignment
            guard realPart.count == imagPart.count else {
                Self.logger.error("Frame \(frameIndex) dimension mismatch: real=\(realPart.count), imag=\(imagPart.count)")
                preconditionFailure("Real and imaginary parts must have same size at frame \(frameIndex)")
            }
            
            // Extract first dfBands bins
            let numBins = min(dfBands, realPart.count)
            
            // Fix LOW: Use prefix instead of Array constructor
            var realChannel = Array(realPart.prefix(numBins))
            var imagChannel = Array(imagPart.prefix(numBins))
            
            // Pad with zeros if needed
            if realChannel.count < dfBands {
                realChannel.append(contentsOf: repeatElement(0, count: dfBands - realChannel.count))
                imagChannel.append(contentsOf: repeatElement(0, count: dfBands - imagChannel.count))
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
        // Fix MEDIUM: Validate alpha parameter
        precondition(alpha > 0 && alpha <= 10, "Alpha must be in range (0, 10], got \(alpha)")
        
        guard !features.isEmpty else { return [] }
        
        // Fix LOW: Validate all frames have expected structure
        guard features.allSatisfy({ $0.count == 2 && !$0[0].isEmpty && !$0[1].isEmpty }) else {
            Self.logger.error("normalize() received invalid frame structure")
            preconditionFailure("All frames must have 2 non-empty channels")
        }
        
        // Fix MEDIUM: Pre-allocate output array
        var normalized: [[[Float]]] = []
        normalized.reserveCapacity(features.count)
        
        // Fix CRITICAL: Allocate buffers per-frame to avoid race condition with variable sizes
        // Previous approach reused buffers which could cause data corruption if frame sizes differ
        
        for frame in features {
            let realPart = frame[0]
            let imagPart = frame[1]
            
            // Allocate fresh buffers for this frame
            let frameSize = realPart.count
            var magnitudeBuffer = [Float](repeating: 0, count: frameSize)
            var realSquaredBuffer = [Float](repeating: 0, count: frameSize)
            var imagSquaredBuffer = [Float](repeating: 0, count: frameSize)
            var normalizedRealBuffer = [Float](repeating: 0, count: frameSize)
            var normalizedImagBuffer = [Float](repeating: 0, count: frameSize)
            
            // Fix HIGH: Validate arrays are non-empty and same length
            guard !realPart.isEmpty, !imagPart.isEmpty, realPart.count == imagPart.count else {
                Self.logger.error("Invalid frame dimensions: real=\(realPart.count), imag=\(imagPart.count)")
                preconditionFailure("Real and imaginary channels must be non-empty and same length")
            }
            
            let length = vDSP_Length(realPart.count)
            
            // Calculate magnitude using Accelerate (vectorized)
            vDSP_vsq(realPart, 1, &realSquaredBuffer, 1, length)
            vDSP_vsq(imagPart, 1, &imagSquaredBuffer, 1, length)
            vDSP_vadd(realSquaredBuffer, 1, imagSquaredBuffer, 1, &magnitudeBuffer, 1, length)
            
            // Fix CRITICAL: Safe sqrt with separate output buffer
            var count = Int32(realPart.count)
            var sqrtResult = [Float](repeating: 0, count: realPart.count)
            vvsqrtf(&sqrtResult, magnitudeBuffer, &count)
            
            // Calculate mean magnitude using vDSP
            var meanMag: Float = 0
            vDSP_meanv(sqrtResult, 1, &meanMag, vDSP_Length(sqrtResult.count))
            
            // Fix MEDIUM: Vectorized variance calculation
            let meanSquared = meanMag * meanMag
            var magSquared = [Float](repeating: 0, count: sqrtResult.count)
            vDSP_vsq(sqrtResult, 1, &magSquared, 1, vDSP_Length(sqrtResult.count))
            
            var sumMagSquared: Float = 0
            vDSP_sve(magSquared, 1, &sumMagSquared, vDSP_Length(magSquared.count))
            
            let variance = (sumMagSquared / Float(sqrtResult.count)) - meanSquared
            
            // Fix HIGH: Don't fail on invalid variance - use epsilon fallback to maintain frame count
            let epsilon: Float = 1e-6
            let validVariance: Float
            if variance.isNaN || variance.isInfinite || variance < 0 {
                Self.logger.error("Invalid variance: \(variance), using epsilon fallback")
                validVariance = epsilon
            } else {
                validVariance = variance
            }
            
            let std = sqrt(max(validVariance, epsilon))
            
            // Fix MEDIUM: Remove redundant NaN/Inf check after epsilon
            // std is guaranteed valid after sqrt(max(...))
            
            // Normalize real and imaginary parts using vDSP
            var invStd = 1.0 / max(std, epsilon)
            vDSP_vsmul(realPart, 1, &invStd, &normalizedRealBuffer, 1, vDSP_Length(realPart.count))
            vDSP_vsmul(imagPart, 1, &invStd, &normalizedImagBuffer, 1, vDSP_Length(imagPart.count))
            
            // Apply alpha scaling
            var alphaVal = alpha
            vDSP_vsmul(normalizedRealBuffer, 1, &alphaVal, &normalizedRealBuffer, 1, vDSP_Length(normalizedRealBuffer.count))
            vDSP_vsmul(normalizedImagBuffer, 1, &alphaVal, &normalizedImagBuffer, 1, vDSP_Length(normalizedImagBuffer.count))
            
            normalized.append([Array(normalizedRealBuffer), Array(normalizedImagBuffer)])
        }
        
        return normalized
    }
    
    // MARK: - Utilities
    
    /// Get frequency range covered by DF bands (cached)
    var frequencyRange: (min: Float, max: Float) {
        return freqRange
    }
    
    /// Get number of DF bands
    var numberOfBands: Int {
        return dfBands
    }
}
