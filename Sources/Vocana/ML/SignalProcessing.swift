import Foundation
import Accelerate

/// Short-Time Fourier Transform (STFT) and Inverse STFT for audio processing
/// Implements real-time compatible spectral analysis with overlap-add synthesis
class STFT {
    // MARK: - Configuration
    
    private let fftSize: Int
    private let hopSize: Int
    private let sampleRate: Int
    private let window: [Float]
    
    // MARK: - FFT Setup
    
    private var fftSetup: FFTSetup?
    private let log2n: vDSP_Length
    
    // MARK: - Buffers (reused to avoid allocations)
    
    private var inputReal: [Float]
    private var inputImag: [Float]
    private var outputReal: [Float]
    private var outputImag: [Float]
    private var windowedInput: [Float]
    
    // MARK: - Initialization
    
    init(fftSize: Int = 960, hopSize: Int = 480, sampleRate: Int = 48000) {
        self.fftSize = fftSize
        self.hopSize = hopSize
        self.sampleRate = sampleRate
        
        // Pre-compute Hann window
        var hannWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.window = hannWindow
        
        // Set up FFT - must be power of 2, so round up
        let fftSizePowerOf2 = Int(pow(2.0, ceil(log2(Double(fftSize)))))
        self.log2n = vDSP_Length(log2(Float(fftSizePowerOf2)))
        
        // Initialize buffers (use power-of-2 size for FFT compatibility)
        self.inputReal = [Float](repeating: 0, count: fftSizePowerOf2)
        self.inputImag = [Float](repeating: 0, count: fftSizePowerOf2)
        self.outputReal = [Float](repeating: 0, count: fftSizePowerOf2)
        self.outputImag = [Float](repeating: 0, count: fftSizePowerOf2)
        self.windowedInput = [Float](repeating: 0, count: fftSize)
        
        // Create FFT setup
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }
    
    deinit {
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }
    
    // MARK: - Forward Transform (Time → Frequency)
    
    /// Compute STFT of audio signal
    /// - Parameter audio: Input audio samples
    /// - Returns: Complex spectrogram as (real, imag) arrays with shape [numFrames, fftSize/2 + 1]
    func transform(_ audio: [Float]) -> (real: [[Float]], imag: [[Float]]) {
        let numSamples = audio.count
        let numFrames = (numSamples - fftSize) / hopSize + 1
        
        guard numFrames > 0 else {
            return ([], [])
        }
        
        var spectrogramReal: [[Float]] = []
        var spectrogramImag: [[Float]] = []
        
        for frameIndex in 0..<numFrames {
            let startSample = frameIndex * hopSize
            let endSample = startSample + fftSize
            
            guard endSample <= numSamples else { break }
            
            // Extract frame
            let frame = Array(audio[startSample..<endSample])
            
            // Apply window
            vDSP_vmul(frame, 1, window, 1, &windowedInput, 1, vDSP_Length(fftSize))
            
            // Copy windowed input to buffers and zero-pad to power of 2
            for i in 0..<inputReal.count {
                if i < fftSize {
                    inputReal[i] = windowedInput[i]
                } else {
                    inputReal[i] = 0
                }
                inputImag[i] = 0
            }
            
            // Perform FFT
            if let fft = fftSetup {
                var splitComplex = DSPSplitComplex(realp: &inputReal, imagp: &inputImag)
                var resultComplex = DSPSplitComplex(realp: &outputReal, imagp: &outputImag)
                
                vDSP_fft_zop(fft, &splitComplex, 1, &resultComplex, 1, log2n, FFTDirection(FFT_FORWARD))
            }
            
            // Extract positive frequencies only (FFT is symmetric for real input)
            let numBins = fftSize / 2 + 1
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
        let outputLength = (numFrames - 1) * hopSize + fftSize
        var output = [Float](repeating: 0, count: outputLength)
        
        let fftSizePowerOf2 = Int(pow(2.0, ceil(log2(Double(fftSize)))))
        var frameBuffer = [Float](repeating: 0, count: fftSize)
        var fullReal = [Float](repeating: 0, count: fftSizePowerOf2)
        var fullImag = [Float](repeating: 0, count: fftSizePowerOf2)
        var tempReal = [Float](repeating: 0, count: fftSizePowerOf2)
        var tempImag = [Float](repeating: 0, count: fftSizePowerOf2)
        
        for frameIndex in 0..<numFrames {
            let frameReal = real[frameIndex]
            let frameImag = imag[frameIndex]
            
            // Reconstruct full spectrum (mirror for negative frequencies)
            fullReal = [Float](repeating: 0, count: fftSizePowerOf2)
            fullImag = [Float](repeating: 0, count: fftSizePowerOf2)
            
            // Positive frequencies (only use first fftSize bins)
            let binsToUse = min(frameReal.count, fftSize)
            for i in 0..<binsToUse {
                fullReal[i] = frameReal[i]
                fullImag[i] = frameImag[i]
            }
            
            // Negative frequencies (complex conjugate of positive)
            for i in 1..<(binsToUse / 2) {
                fullReal[fftSize - i] = frameReal[i]
                fullImag[fftSize - i] = -frameImag[i]
            }
            
            // Perform inverse FFT
            if let fft = fftSetup {
                var splitComplex = DSPSplitComplex(realp: &fullReal, imagp: &fullImag)
                var resultComplex = DSPSplitComplex(realp: &tempReal, imagp: &tempImag)
                
                vDSP_fft_zop(fft, &splitComplex, 1, &resultComplex, 1, log2n, FFTDirection(FFT_INVERSE))
            }
            
            // Scale by 1/fftSize (required for inverse FFT)
            let scale = 1.0 / Float(fftSizePowerOf2)
            vDSP_vsmul(tempReal, 1, [scale], &tempReal, 1, vDSP_Length(fftSizePowerOf2))
            
            // Take real part and apply window
            vDSP_vmul(tempReal, 1, window, 1, &frameBuffer, 1, vDSP_Length(fftSize))
            
            // Overlap-add
            let startSample = frameIndex * hopSize
            for i in 0..<fftSize {
                if startSample + i < outputLength {
                    output[startSample + i] += frameBuffer[i]
                }
            }
        }
        
        // Normalize by window sum (for perfect reconstruction with overlap-add)
        let windowSum = window.reduce(0, +)
        let normalizationFactor = Float(hopSize) / windowSum
        vDSP_vsmul(output, 1, [normalizationFactor], &output, 1, vDSP_Length(outputLength))
        
        return output
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
