import Foundation
import Accelerate

/// Deep Filtering implementation for DeepFilterNet
///
/// Applies frequency-domain filtering using learned coefficients
/// from the DF decoder model. Uses a 5-tap FIR filter per frequency bin.
struct DeepFiltering {
    
    /// Number of deep filtering frequency bins (first 96 bins)
    static let dfBins = 96
    
    /// Filter order (number of taps)
    static let dfOrder = 5
    
    /// Apply deep filtering to complex spectrum using learned coefficients
    ///
    /// - Parameters:
    ///   - spectrum: Complex spectrum in split format (real, imaginary)
    ///   - coefficients: Filter coefficients [T, dfBins, dfOrder]
    /// - Returns: Filtered complex spectrum
    static func apply(spectrum: (real: [Float], imag: [Float]), coefficients: [Float], timeSteps: Int) -> (real: [Float], imag: [Float]) {
        let freqBins = spectrum.real.count / timeSteps
        
        guard freqBins >= dfBins else {
            print("⚠️ Spectrum has fewer bins (\(freqBins)) than DF bins (\(dfBins))")
            return spectrum
        }
        
        var filteredReal = spectrum.real
        var filteredImag = spectrum.imag
        
        // Apply filtering to first 96 bins only
        for t in 0..<timeSteps {
            for f in 0..<dfBins {
                // Get filter coefficients for this time-frequency point
                let coefOffset = (t * dfBins + f) * dfOrder
                let coefs = Array(coefficients[coefOffset..<coefOffset + dfOrder])
                
                // Apply FIR filter across time
                let (filteredR, filteredI) = applyFIRFilter(
                    real: filteredReal,
                    imag: filteredImag,
                    timeIndex: t,
                    freqIndex: f,
                    freqBins: freqBins,
                    coefficients: coefs
                )
                
                let idx = t * freqBins + f
                filteredReal[idx] = filteredR
                filteredImag[idx] = filteredI
            }
        }
        
        return (filteredReal, filteredImag)
    }
    
    /// Apply FIR filter at a single time-frequency point
    private static func applyFIRFilter(
        real: [Float],
        imag: [Float],
        timeIndex: Int,
        freqIndex: Int,
        freqBins: Int,
        coefficients: [Float]
    ) -> (Float, Float) {
        var outputReal: Float = 0.0
        var outputImag: Float = 0.0
        
        // 5-tap FIR filter centered at current time
        let halfOrder = dfOrder / 2  // 2
        
        for tap in 0..<dfOrder {
            let t = timeIndex - halfOrder + tap
            
            // Handle boundary conditions with zero-padding
            guard t >= 0 && t < (real.count / freqBins) else {
                continue
            }
            
            let idx = t * freqBins + freqIndex
            let coef = coefficients[tap]
            
            outputReal += real[idx] * coef
            outputImag += imag[idx] * coef
        }
        
        return (outputReal, outputImag)
    }
    
    /// Apply ERB mask to spectrum
    ///
    /// Multiplies complex spectrum by real-valued mask
    ///
    /// - Parameters:
    ///   - spectrum: Complex spectrum in split format
    ///   - mask: Real-valued mask [T, F]
    ///   - timeSteps: Number of time frames
    /// - Returns: Masked spectrum
    static func applyMask(spectrum: (real: [Float], imag: [Float]), mask: [Float], timeSteps: Int) -> (real: [Float], imag: [Float]) {
        var maskedReal = spectrum.real
        var maskedImag = spectrum.imag
        
        let freqBins = spectrum.real.count / timeSteps
        
        // Element-wise multiplication
        for t in 0..<timeSteps {
            for f in 0..<freqBins {
                let idx = t * freqBins + f
                let maskValue = mask[idx]
                
                maskedReal[idx] *= maskValue
                maskedImag[idx] *= maskValue
            }
        }
        
        return (maskedReal, maskedImag)
    }
    
    /// Combine ERB mask and DF coefficients filtering
    ///
    /// First applies ERB mask, then deep filtering
    ///
    /// - Parameters:
    ///   - spectrum: Input complex spectrum
    ///   - mask: ERB mask [T, F]
    ///   - coefficients: DF coefficients [T, dfBins, dfOrder]
    ///   - timeSteps: Number of time frames
    /// - Returns: Enhanced spectrum
    static func enhance(
        spectrum: (real: [Float], imag: [Float]),
        mask: [Float],
        coefficients: [Float],
        timeSteps: Int
    ) -> (real: [Float], imag: [Float]) {
        // Step 1: Apply ERB mask
        let masked = applyMask(spectrum: spectrum, mask: mask, timeSteps: timeSteps)
        
        // Step 2: Apply deep filtering to low frequencies
        let filtered = apply(spectrum: masked, coefficients: coefficients, timeSteps: timeSteps)
        
        return filtered
    }
    
    /// Compute gain from mask (for visualization/debugging)
    static func computeGain(mask: [Float]) -> Float {
        let sum = mask.reduce(0, +)
        return sum / Float(mask.count)
    }
    
    /// Apply post-filtering gain normalization
    static func normalizeGain(spectrum: (real: [Float], imag: [Float]), targetGain: Float = 1.0) -> (real: [Float], imag: [Float]) {
        // Compute current magnitude
        var magnitude: Float = 0.0
        vDSP_svesq(spectrum.real, 1, &magnitude, vDSP_Length(spectrum.real.count))
        
        var imagMag: Float = 0.0
        vDSP_svesq(spectrum.imag, 1, &imagMag, vDSP_Length(spectrum.imag.count))
        
        magnitude = sqrtf(magnitude + imagMag)
        
        guard magnitude > 0 else {
            return spectrum
        }
        
        // Normalize to target gain
        var gain = targetGain / magnitude
        
        var normalizedReal = spectrum.real
        var normalizedImag = spectrum.imag
        
        vDSP_vsmul(spectrum.real, 1, &gain, &normalizedReal, 1, vDSP_Length(spectrum.real.count))
        vDSP_vsmul(spectrum.imag, 1, &gain, &normalizedImag, 1, vDSP_Length(spectrum.imag.count))
        
        return (normalizedReal, normalizedImag)
    }
}

// MARK: - Performance Notes

/*
 Optimization opportunities:
 
 1. Vectorize FIR filtering:
    - Use vDSP_conv for convolution
    - Process multiple frequencies in parallel
 
 2. SIMD optimizations:
    - Process 4-8 complex values at once
    - Use vDSP_zvmul for complex multiplication
 
 3. Memory layout:
    - Consider SoA (Structure of Arrays) for better cache locality
    - Pre-allocate output buffers
 
 4. Metal GPU acceleration:
    - Offload filtering to GPU for real-time processing
    - Use MPSImageConvolution for 2D filtering
 
 Typical performance:
 - CPU: ~1ms for 480 samples (10ms audio)
 - Target: <5ms for real-time processing
 */
