import Foundation
import Accelerate
import os.log

/// SpectralFeatures processing errors
enum SpectralFeaturesError: Error, LocalizedError {
    case dimensionMismatch(frame: Int, real: Int, imag: Int)
    case invalidInput(String)
    
    var errorDescription: String? {
        switch self {
        case .dimensionMismatch(let frame, let real, let imag):
            return "Frame \(frame) dimension mismatch: real=\(real), imag=\(imag)"
        case .invalidInput(let message):
            return "Invalid input: \(message)"
        }
    }
}

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
    
    init(dfBands: Int = AppConstants.dfBands, sampleRate: Int = AppConstants.sampleRate, fftSize: Int = AppConstants.fftSize) {
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
    func extract(spectrogramReal: [[Float]], spectrogramImag: [[Float]]) throws -> [[[Float]]] {
        // Fix CRITICAL: Don't silently fail - precondition for dimension mismatch
        precondition(spectrogramReal.count == spectrogramImag.count,
                    "Spectrogram dimension mismatch: real=\(spectrogramReal.count), imag=\(spectrogramImag.count)")
        
        // Fix HIGH: Validate input isn't excessively large (prevent DoS)
        let maxFrames = AppConstants.maxSpectralFrames
        precondition(spectrogramReal.count <= maxFrames,
                    "Too many frames: \(spectrogramReal.count) (max: \(maxFrames))")
        
        let numFrames = spectrogramReal.count
        
        // Fix MEDIUM: Pre-allocate with reserveCapacity
        var spectralFeatures: [[[Float]]] = []
        spectralFeatures.reserveCapacity(numFrames)
        
        // Fix HIGH: Validate frame dimensions and throw error if mismatch is critical
        let expectedBins = fftSize / 2 + 1
        if let firstReal = spectrogramReal.first, firstReal.count != expectedBins {
            let message = "Spectrogram has \(firstReal.count) bins, expected \(expectedBins)"
            if firstReal.count < self.dfBands {
                // Critical: Not enough bins for required dfBands
                Self.logger.error("\(message) - Cannot extract \(self.dfBands) bands")
                throw SpectralFeaturesError.invalidInput("Insufficient frequency bins: need \(self.dfBands), have \(firstReal.count)")
            } else {
                // Warning: More bins than expected, but we can proceed
                Self.logger.warning("\(message) - Will use first \(self.dfBands) bands")
            }
        }
        
        for frameIndex in 0..<numFrames {
            let realPart = spectrogramReal[frameIndex]
            let imagPart = spectrogramImag[frameIndex]
            
            // Fix HIGH: Throw error instead of returning partial results
            guard realPart.count == imagPart.count else {
                Self.logger.error("Frame \(frameIndex) dimension mismatch: real=\(realPart.count), imag=\(imagPart.count)")
                throw SpectralFeaturesError.dimensionMismatch(
                    frame: frameIndex,
                    real: realPart.count,
                    imag: imagPart.count
                )
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
        
        // Fix CRITICAL: Replace preconditionFailure with recoverable error handling
        guard features.allSatisfy({ $0.count == 2 && !$0[0].isEmpty && !$0[1].isEmpty }) else {
            Self.logger.error("normalize() received invalid frame structure")
            // Return empty result instead of crashing
            return []
        }
        
        // Fix MEDIUM: Pre-allocate output array
        var normalized: [[[Float]]] = []
        normalized.reserveCapacity(features.count)
        
        // Fix CRITICAL: Allocate buffers per-frame to avoid race condition with variable sizes
        // Previous approach reused buffers which could cause data corruption if frame sizes differ
        
        // Pre-allocate empty result for error cases to prevent memory allocation in error paths
        let emptyFrameResult = [[Float](), [Float]()]
        
        for frame in features {
            let realPart = frame[0]
            let imagPart = frame[1]
            
            // Fix CRITICAL: Validate dimensions before any buffer allocation to prevent memory leak
            guard !realPart.isEmpty, 
                  !imagPart.isEmpty, 
                  realPart.count == imagPart.count,
                  realPart.count < Int32.max else {
                Self.logger.error("Invalid frame dimensions: real=\(realPart.count), imag=\(imagPart.count)")
                // Use pre-allocated empty result to avoid allocation in error path
                normalized.append(emptyFrameResult)
                continue
            }
            
            // Allocate fresh buffers for this frame only after validation
            let frameSize = realPart.count
            var magnitudeBuffer = [Float](repeating: 0, count: frameSize)
            var realSquaredBuffer = [Float](repeating: 0, count: frameSize)
            var imagSquaredBuffer = [Float](repeating: 0, count: frameSize)
            var normalizedRealBuffer = [Float](repeating: 0, count: frameSize)
            var normalizedImagBuffer = [Float](repeating: 0, count: frameSize)
            
            let length = vDSP_Length(realPart.count)
            
            // Calculate magnitude using Accelerate (vectorized)
            vDSP_vsq(realPart, 1, &realSquaredBuffer, 1, length)
            vDSP_vsq(imagPart, 1, &imagSquaredBuffer, 1, length)
            vDSP_vadd(realSquaredBuffer, 1, imagSquaredBuffer, 1, &magnitudeBuffer, 1, length)
            
            // Fix CRITICAL: Replace preconditionFailure with recoverable error handling
            guard magnitudeBuffer.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                Self.logger.error("Invalid magnitude buffer (NaN/Inf/negative)")
                // Use pre-allocated empty result to prevent allocation in error path
                normalized.append(emptyFrameResult)
                continue
            }
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
            
            // Fix CRITICAL #8: Combine normalization and alpha scaling in single operation for clarity
            // Normalize and scale: (x / std) * alpha = x * (alpha / std)
            var scale = alpha / max(std, epsilon)
            vDSP_vsmul(realPart, 1, &scale, &normalizedRealBuffer, 1, vDSP_Length(realPart.count))
            vDSP_vsmul(imagPart, 1, &scale, &normalizedImagBuffer, 1, vDSP_Length(imagPart.count))
            
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
