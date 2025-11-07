import Foundation
import Accelerate
import os.log

/// Short-Time Fourier Transform (STFT) and Inverse STFT for audio processing
/// Implements real-time compatible spectral analysis with overlap-add synthesis
///
/// **Thread Safety**: This class is NOT thread-safe. Do not call transform() or inverse()
/// concurrently from multiple threads. Create separate STFT instances per thread if needed.
/// Read-only properties are thread-safe after initialization.
///
/// **Usage Example**:
/// ```swift
/// let stft = STFT(fftSize: 960, hopSize: 480, sampleRate: 48000)
/// let (real, imag) = stft.transform(audioSamples)
/// let reconstructed = stft.inverse(real: real, imag: imag)
/// ```
final class STFT {
    // MARK: - Configuration
    
    private let fftSize: Int
    private let hopSize: Int
    private let sampleRate: Int
    private let window: [Float]
    private let fftSizePowerOf2: Int  // Stored to avoid recalculation
    
    // MARK: - FFT Setup
    
    private let fftSetup: FFTSetup  // Non-optional - required for operation
    private let log2n: vDSP_Length
    
    // MARK: - Buffers (reused to avoid allocations)
    
    private var inputReal: [Float]
    private var inputImag: [Float]
    private var outputReal: [Float]
    private var outputImag: [Float]
    private var windowedInput: [Float]
    
    // Inverse transform buffers (reused)
    private var fullReal: [Float]
    private var fullImag: [Float]
    private var tempReal: [Float]
    private var tempImag: [Float]
    private var frameBuffer: [Float]
    
    // Logging
    private static let logger = Logger(subsystem: "com.vocana.ml", category: "STFT")
    
    // MARK: - Initialization
    
    init(fftSize: Int = 960, hopSize: Int = 480, sampleRate: Int = 48000) {
        precondition(fftSize > 0 && fftSize <= 16384, 
                    "FFT size must be in range [1, 16384], got \(fftSize)")
        precondition(hopSize > 0 && hopSize <= fftSize, 
                    "Hop size must be positive and <= FFT size, got hopSize=\(hopSize), fftSize=\(fftSize)")
        precondition(sampleRate > 0 && sampleRate <= 192000, 
                    "Sample rate must be in range [1, 192000], got \(sampleRate)")
        
        self.fftSize = fftSize
        self.hopSize = hopSize
        self.sampleRate = sampleRate
        
        // Pre-compute Hann window
        var hannWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.window = hannWindow
        
        // Set up FFT - must be power of 2, so round up
        self.fftSizePowerOf2 = Int(pow(2.0, ceil(log2(Double(fftSize)))))
        self.log2n = vDSP_Length(log2(Double(fftSizePowerOf2)))
        
        // Create FFT setup - must succeed or initialization fails
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("Failed to create FFT setup for size \(fftSizePowerOf2)")
        }
        self.fftSetup = setup
        
        // Initialize buffers (use power-of-2 size for FFT compatibility)
        self.inputReal = [Float](repeating: 0, count: fftSizePowerOf2)
        self.inputImag = [Float](repeating: 0, count: fftSizePowerOf2)
        self.outputReal = [Float](repeating: 0, count: fftSizePowerOf2)
        self.outputImag = [Float](repeating: 0, count: fftSizePowerOf2)
        self.windowedInput = [Float](repeating: 0, count: fftSize)
        
        // Initialize inverse transform buffers
        self.fullReal = [Float](repeating: 0, count: fftSizePowerOf2)
        self.fullImag = [Float](repeating: 0, count: fftSizePowerOf2)
        self.tempReal = [Float](repeating: 0, count: fftSizePowerOf2)
        self.tempImag = [Float](repeating: 0, count: fftSizePowerOf2)
        self.frameBuffer = [Float](repeating: 0, count: fftSize)
    }
    
    // Fix MEDIUM: Mark deinit as nonisolated for consistency
    nonisolated deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }
    
    // MARK: - Forward Transform (Time → Frequency)
    
    /// Compute STFT of audio signal
    /// - Parameter audio: Input audio samples
    /// - Returns: Complex spectrogram as (real, imag) arrays with shape [numFrames, fftSize/2 + 1]
    func transform(_ audio: [Float]) -> (real: [[Float]], imag: [[Float]]) {
        let numSamples = audio.count
        
        // Fix CRITICAL: Integer underflow protection
        guard numSamples >= fftSize else {
            return ([], [])
        }
        
        let numFrames = (numSamples - fftSize) / hopSize + 1
        
        guard numFrames > 0 else {
            return ([], [])
        }
        
        // Pre-allocate arrays for better performance
        var spectrogramReal: [[Float]] = []
        var spectrogramImag: [[Float]] = []
        spectrogramReal.reserveCapacity(numFrames)
        spectrogramImag.reserveCapacity(numFrames)
        
        let numBins = fftSize / 2 + 1
        
        for frameIndex in 0..<numFrames {
            let startSample = frameIndex * hopSize
            let endSample = startSample + fftSize
            
            guard endSample <= numSamples else { break }
            
            // Apply window directly to avoid array copy
            audio[startSample..<endSample].withUnsafeBufferPointer { audioPtr in
                vDSP_vmul(audioPtr.baseAddress!, 1, window, 1, &windowedInput, 1, vDSP_Length(fftSize))
            }
            
            // Zero-fill buffers using vDSP
            vDSP_vclr(&inputReal, 1, vDSP_Length(fftSizePowerOf2))
            vDSP_vclr(&inputImag, 1, vDSP_Length(fftSizePowerOf2))
            
            // Copy windowed input
            windowedInput.withUnsafeBufferPointer { winPtr in
                inputReal.withUnsafeMutableBufferPointer { realPtr in
                    realPtr.baseAddress!.initialize(from: winPtr.baseAddress!, count: fftSize)
                }
            }
            
            // Perform FFT with safe pointer handling
            var fftSucceeded = false
            inputReal.withUnsafeMutableBufferPointer { inputRealPtr in
                inputImag.withUnsafeMutableBufferPointer { inputImagPtr in
                    outputReal.withUnsafeMutableBufferPointer { outputRealPtr in
                        outputImag.withUnsafeMutableBufferPointer { outputImagPtr in
                            guard let inputRealBase = inputRealPtr.baseAddress,
                                  let inputImagBase = inputImagPtr.baseAddress,
                                  let outputRealBase = outputRealPtr.baseAddress,
                                  let outputImagBase = outputImagPtr.baseAddress else {
                                Self.logger.error("FFT buffer pointers are nil")
                                return
                            }
                            
                            var splitComplex = DSPSplitComplex(realp: inputRealBase, imagp: inputImagBase)
                            var resultComplex = DSPSplitComplex(realp: outputRealBase, imagp: outputImagBase)
                            
                            vDSP_fft_zop(fftSetup, &splitComplex, 1, &resultComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                            fftSucceeded = true
                        }
                    }
                }
            }
            
            // Only append frame if FFT succeeded
            guard fftSucceeded else {
                Self.logger.warning("FFT failed for frame \(frameIndex)")
                continue
            }
            
            // Extract positive frequencies only (FFT is symmetric for real input)
            // Use pre-allocated arrays
            let frameReal = Array(outputReal[0..<numBins])
            let frameImag = Array(outputImag[0..<numBins])
            
            spectrogramReal.append(frameReal)
            spectrogramImag.append(frameImag)
        }
        
        return (spectrogramReal, spectrogramImag)
    }
    
    // MARK: - Inverse Transform (Frequency → Time)
    
    /// Compute inverse STFT to reconstruct audio
    /// - Parameters:
    ///   - real: Real part of spectrogram [numFrames, fftSize/2 + 1]
    ///   - imag: Imaginary part of spectrogram [numFrames, fftSize/2 + 1]
    /// - Returns: Reconstructed audio samples
    func inverse(real: [[Float]], imag: [[Float]]) -> [Float] {
        guard real.count == imag.count, real.count > 0 else {
            return []
        }
        
        let numFrames = real.count
        
        // Fix CRITICAL: Integer overflow protection
        guard let outputLength = calculateOutputLength(numFrames: numFrames) else {
            Self.logger.error("Output length calculation overflow")
            return []
        }
        
        var output = [Float](repeating: 0, count: outputLength)
        var windowSumBuffer = [Float](repeating: 0, count: outputLength)
        
        for frameIndex in 0..<numFrames {
            let frameReal = real[frameIndex]
            let frameImag = imag[frameIndex]
            
            // Reuse buffers instead of reallocating
            vDSP_vclr(&fullReal, 1, vDSP_Length(fftSizePowerOf2))
            vDSP_vclr(&fullImag, 1, vDSP_Length(fftSizePowerOf2))
            
            // Positive frequencies (only use first fftSize bins)
            let binsToUse = min(frameReal.count, fftSize / 2 + 1)
            
            // Copy positive frequencies
            frameReal.withUnsafeBufferPointer { realPtr in
                fullReal.withUnsafeMutableBufferPointer { fullRealPtr in
                    fullRealPtr.baseAddress!.initialize(from: realPtr.baseAddress!, count: binsToUse)
                }
            }
            frameImag.withUnsafeBufferPointer { imagPtr in
                fullImag.withUnsafeMutableBufferPointer { fullImagPtr in
                    fullImagPtr.baseAddress!.initialize(from: imagPtr.baseAddress!, count: binsToUse)
                }
            }
            
            // Negative frequencies (complex conjugate of positive)
            // Fix HIGH: Use fftSizePowerOf2 for correct mirroring
            for i in 1..<binsToUse {
                let mirrorIndex = fftSizePowerOf2 - i
                if mirrorIndex > 0 && mirrorIndex < fftSizePowerOf2 {
                    fullReal[mirrorIndex] = frameReal[i]
                    fullImag[mirrorIndex] = -frameImag[i]
                }
            }
            
            // Perform inverse FFT with safe pointer handling
            var ifftSucceeded = false
            fullReal.withUnsafeMutableBufferPointer { fullRealPtr in
                fullImag.withUnsafeMutableBufferPointer { fullImagPtr in
                    tempReal.withUnsafeMutableBufferPointer { tempRealPtr in
                        tempImag.withUnsafeMutableBufferPointer { tempImagPtr in
                            guard let fullRealBase = fullRealPtr.baseAddress,
                                  let fullImagBase = fullImagPtr.baseAddress,
                                  let tempRealBase = tempRealPtr.baseAddress,
                                  let tempImagBase = tempImagPtr.baseAddress else {
                                Self.logger.error("IFFT buffer pointers are nil")
                                return
                            }
                            
                            var splitComplex = DSPSplitComplex(realp: fullRealBase, imagp: fullImagBase)
                            var resultComplex = DSPSplitComplex(realp: tempRealBase, imagp: tempImagBase)
                            
                            vDSP_fft_zop(fftSetup, &splitComplex, 1, &resultComplex, 1, log2n, FFTDirection(FFT_INVERSE))
                            ifftSucceeded = true
                        }
                    }
                }
            }
            
            // Only process if IFFT succeeded
            guard ifftSucceeded else {
                Self.logger.warning("IFFT failed for frame \(frameIndex)")
                continue
            }
            
            // Validate imaginary component is near-zero (for debugging)
            #if DEBUG
            var maxImag: Float = 0
            vDSP_maxv(tempImag, 1, &maxImag, vDSP_Length(fftSize))
            assert(abs(maxImag) < 1e-3, "IFFT imaginary component too large: \(maxImag)")
            #endif
            
            // Scale by 1/fftSize (required for inverse FFT)
            let scale = 1.0 / Float(fftSizePowerOf2)
            vDSP_vsmul(tempReal, 1, [scale], &tempReal, 1, vDSP_Length(fftSizePowerOf2))
            
            // Take real part and apply window
            vDSP_vmul(tempReal, 1, window, 1, &frameBuffer, 1, vDSP_Length(fftSize))
            
            // Overlap-add with proper COLA normalization
            let startSample = frameIndex * hopSize
            for i in 0..<fftSize where startSample + i < outputLength {
                output[startSample + i] += frameBuffer[i]
                windowSumBuffer[startSample + i] += window[i] * window[i]
            }
        }
        
        // Fix HIGH: Proper COLA normalization
        for i in 0..<outputLength where windowSumBuffer[i] > Float.leastNormalMagnitude {
            output[i] /= windowSumBuffer[i]
        }
        
        return output
    }
    
    // MARK: - Helper Methods
    
    private func calculateOutputLength(numFrames: Int) -> Int? {
        // Safe calculation with overflow checking
        let (framesPart, overflow1) = (numFrames - 1).multipliedReportingOverflow(by: hopSize)
        guard !overflow1 else { return nil }
        
        let (result, overflow2) = framesPart.addingReportingOverflow(fftSize)
        guard !overflow2 else { return nil }
        
        return result
    }
    
    // MARK: - Utilities
    
    /// Get the number of frequency bins
    var frequencyBins: Int {
        return fftSize / 2 + 1
    }
    
    /// Get frequency resolution in Hz
    var frequencyResolution: Float {
        return Float(sampleRate) / Float(fftSize)
    }
    
    /// Get frame duration in seconds
    var frameDuration: Float {
        return Float(fftSize) / Float(sampleRate)
    }
    
    /// Get hop duration in seconds
    var hopDuration: Float {
        return Float(hopSize) / Float(sampleRate)
    }
}
