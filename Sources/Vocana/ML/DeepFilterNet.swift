import Foundation
import Accelerate

/// DeepFilterNet3 noise cancellation pipeline
///
/// Orchestrates the full DeepFilterNet inference pipeline:
/// 1. STFT - Convert audio to frequency domain
/// 2. Feature Extraction - Extract ERB and spectral features
/// 3. Encoder - Process features through neural network
/// 4. Decoders - Generate mask and filtering coefficients
/// 5. Filtering - Apply enhancement to spectrum
/// 6. ISTFT - Convert back to time domain
///
/// Reference: https://arxiv.org/abs/2305.08227
class DeepFilterNet {
    
    // MARK: - Components
    
    private let stft: STFT
    private let erbFeatures: ERBFeatures
    private let specFeatures: SpectralFeatures
    
    private let encoder: ONNXModel
    private let erbDecoder: ONNXModel
    private let dfDecoder: ONNXModel
    
    // MARK: - Configuration
    
    private let sampleRate: Int = 48000
    private let fftSize: Int = 960
    private let hopSize: Int = 480
    private let erbBands: Int = 32
    private let dfBands: Int = 96
    
    // MARK: - State Management
    
    private var states: [String: Tensor] = [:]
    private var isFirstFrame = true
    
    enum DeepFilterError: Error {
        case modelLoadFailed(String)
        case processingFailed(String)
        case invalidAudioLength
    }
    
    /// Initialize DeepFilterNet with model paths
    ///
    /// - Parameter modelsDirectory: Directory containing ONNX models
    init(modelsDirectory: String) throws {
        // Initialize signal processing components
        self.stft = STFT(fftSize: fftSize, hopSize: hopSize, sampleRate: sampleRate)
        self.erbFeatures = ERBFeatures(
            numBands: erbBands,
            sampleRate: sampleRate,
            fftSize: fftSize
        )
        self.specFeatures = SpectralFeatures(
            dfBands: dfBands,
            sampleRate: sampleRate,
            fftSize: fftSize
        )
        
        // Load ONNX models
        let encPath = "\(modelsDirectory)/enc.onnx"
        let erbDecPath = "\(modelsDirectory)/erb_dec.onnx"
        let dfDecPath = "\(modelsDirectory)/df_dec.onnx"
        
        do {
            self.encoder = try ONNXModel(modelPath: encPath)
            self.erbDecoder = try ONNXModel(modelPath: erbDecPath)
            self.dfDecoder = try ONNXModel(modelPath: dfDecPath)
            
            print("✓ DeepFilterNet initialized")
            print("  Sample rate: \(sampleRate) Hz")
            print("  FFT size: \(fftSize)")
            print("  Hop size: \(hopSize)")
            print("  ERB bands: \(erbBands)")
            print("  DF bands: \(dfBands)")
        } catch {
            throw DeepFilterError.modelLoadFailed(error.localizedDescription)
        }
    }
    
    /// Process audio frame through DeepFilterNet
    ///
    /// - Parameter audio: Input audio samples (minimum fftSize samples)
    /// - Returns: Enhanced audio samples
    func process(audio: [Float]) throws -> [Float] {
        // Validate input length - need at least fftSize samples
        guard audio.count >= fftSize else {
            throw DeepFilterError.invalidAudioLength
        }
        
        do {
            // 1. STFT - Convert to frequency domain
            let spectrum2D = stft.transform(audio)
            
            // Check if we got valid output
            guard !spectrum2D.real.isEmpty, !spectrum2D.imag.isEmpty else {
                // Not enough samples for STFT, return input as-is
                return audio
            }
            
            // Convert 2D to 1D (flatten for single frame)
            let spectrumReal = spectrum2D.real.flatMap { $0 }
            let spectrumImag = spectrum2D.imag.flatMap { $0 }
            let spectrum = (real: spectrumReal, imag: spectrumImag)
            
            // 2. Extract features
            let erbFeat = try extractERBFeatures(spectrum: spectrum)
            let specFeat = try extractSpectralFeatures(spectrum: spectrum)
            
            // 3. Run encoder
            let encoderOutputs = try runEncoder(erbFeat: erbFeat, specFeat: specFeat)
            
            // 4. Run decoders
            let mask = try runERBDecoder(states: encoderOutputs)
            let coefficients = try runDFDecoder(states: encoderOutputs)
            
            // 5. Apply filtering
            let enhanced = try applyFiltering(
                spectrum: spectrum,
                mask: mask,
                coefficients: coefficients
            )
            
            // 6. ISTFT - Convert back to time domain
            // Convert 1D back to 2D for ISTFT
            let enhancedReal2D = [enhanced.real]
            let enhancedImag2D = [enhanced.imag]
            let outputAudio = stft.inverse(real: enhancedReal2D, imag: enhancedImag2D)
            
            return Array(outputAudio.prefix(hopSize))
            
        } catch {
            throw DeepFilterError.processingFailed(error.localizedDescription)
        }
    }
    
    /// Reset internal state (call when starting new audio stream)
    func reset() {
        states.removeAll()
        isFirstFrame = true
        print("DeepFilterNet state reset")
    }
    
    // MARK: - Feature Extraction
    
    private func extractERBFeatures(spectrum: (real: [Float], imag: [Float])) throws -> Tensor {
        // Convert to 2D arrays for ERBFeatures API (single frame)
        let specReal2D = [spectrum.real]
        let specImag2D = [spectrum.imag]
        
        // Extract ERB bands (works with complex spectrogram)
        let erbBands2D = erbFeatures.extract(spectrogramReal: specReal2D, spectrogramImag: specImag2D)
        
        // Normalize
        let normalized2D = erbFeatures.normalize(erbBands2D, alpha: 0.9)
        
        // Flatten for tensor (single frame)
        let normalized = normalized2D.flatMap { $0 }
        
        // Reshape to [1, 1, T, 32]
        // For single frame: [1, 1, 1, 32]
        return Tensor(shape: [1, 1, 1, normalized.count], data: normalized)
    }
    
    private func extractSpectralFeatures(spectrum: (real: [Float], imag: [Float])) throws -> Tensor {
        // Convert to 2D arrays for SpectralFeatures API (single frame)
        let specReal2D = [spectrum.real]
        let specImag2D = [spectrum.imag]
        
        // Extract first 96 bins
        let dfSpec = specFeatures.extract(spectrogramReal: specReal2D, spectrogramImag: specImag2D)
        
        // Normalize
        let normalized = specFeatures.normalize(dfSpec, alpha: 0.6)
        
        // Convert to [1, 2, T, 96] format
        // Channel 0: real, Channel 1: imaginary
        // normalized is [numFrames, 2, dfBands], we want [1, 2, numFrames, dfBands]
        guard let frame = normalized.first else {
            throw DeepFilterError.processingFailed("No spectral features extracted")
        }
        
        var data: [Float] = []
        data.append(contentsOf: frame[0])  // real channel
        data.append(contentsOf: frame[1])  // imag channel
        
        return Tensor(shape: [1, 2, 1, dfBands], data: data)
    }
    
    // MARK: - Model Inference
    
    private func runEncoder(erbFeat: Tensor, specFeat: Tensor) throws -> [String: Tensor] {
        let inputs: [String: Tensor] = [
            "erb_feat": erbFeat,
            "spec_feat": specFeat
        ]
        
        let outputs = try encoder.infer(inputs: inputs)
        
        // Store states for next frame
        states = outputs
        
        return outputs
    }
    
    private func runERBDecoder(states: [String: Tensor]) throws -> [Float] {
        // Pass encoder states to ERB decoder
        let outputs = try erbDecoder.infer(inputs: states)
        
        // Extract mask [1, 1, T, F]
        guard let maskTensor = outputs["m"] else {
            throw DeepFilterError.processingFailed("ERB decoder didn't return mask")
        }
        
        return maskTensor.data
    }
    
    private func runDFDecoder(states: [String: Tensor]) throws -> [Float] {
        // Pass encoder states to DF decoder
        let outputs = try dfDecoder.infer(inputs: states)
        
        // Extract coefficients [T, dfBands, 5]
        guard let coefsTensor = outputs["coefs"] else {
            throw DeepFilterError.processingFailed("DF decoder didn't return coefficients")
        }
        
        return coefsTensor.data
    }
    
    // MARK: - Filtering
    
    private func applyFiltering(
        spectrum: (real: [Float], imag: [Float]),
        mask: [Float],
        coefficients: [Float]
    ) throws -> (real: [Float], imag: [Float]) {
        // Apply enhancement (ERB mask + deep filtering)
        let enhanced = DeepFiltering.enhance(
            spectrum: spectrum,
            mask: mask,
            coefficients: coefficients,
            timeSteps: 1  // Single frame
        )
        
        return enhanced
    }
    
    // MARK: - Utilities
    
    private func spectrumToMagnitude(_ spectrum: (real: [Float], imag: [Float])) -> [Float] {
        var magnitude = [Float](repeating: 0, count: spectrum.real.count)
        
        for i in 0..<spectrum.real.count {
            let real = spectrum.real[i]
            let imag = spectrum.imag[i]
            magnitude[i] = sqrtf(real * real + imag * imag)
        }
        
        return magnitude
    }
    
    /// Process entire audio buffer (for batch processing)
    ///
    /// - Parameter audio: Input audio samples (any length)
    /// - Returns: Enhanced audio samples
    func processBuffer(_ audio: [Float]) throws -> [Float] {
        // Need at least fftSize samples to process
        guard audio.count >= fftSize else {
            // Not enough samples, return as-is
            return audio
        }
        
        var output: [Float] = []
        output.reserveCapacity(audio.count)
        
        // Process in chunks of fftSize (with overlap handled internally)
        // Each chunk produces hopSize output samples
        var position = 0
        while position + fftSize <= audio.count {
            let chunk = Array(audio[position..<position + fftSize])
            let enhanced = try process(audio: chunk)
            
            // Take first hopSize samples from output
            let outputChunk = Array(enhanced.prefix(hopSize))
            output.append(contentsOf: outputChunk)
            
            position += hopSize
        }
        
        // Handle remaining samples (if any)
        if position < audio.count {
            let remaining = audio.count - position
            var lastChunk = Array(audio[position..<audio.count])
            
            // Pad to fftSize
            lastChunk.append(contentsOf: Array(repeating: 0.0, count: fftSize - remaining))
            
            let enhanced = try process(audio: lastChunk)
            let outputChunk = Array(enhanced.prefix(remaining))
            output.append(contentsOf: outputChunk)
        }
        
        return output
    }
}

// MARK: - Convenience Initializer

extension DeepFilterNet {
    /// Initialize with default model location (Resources/Models/)
    static func withDefaultModels() throws -> DeepFilterNet {
        // Try to find models in Resources
        let resourcePath = Bundle.main.resourcePath ?? "."
        let modelsPath = "\(resourcePath)/Models"
        
        // Check if models exist
        let encPath = "\(modelsPath)/enc.onnx"
        guard FileManager.default.fileExists(atPath: encPath) else {
            throw DeepFilterError.modelLoadFailed("Models not found at \(modelsPath)")
        }
        
        return try DeepFilterNet(modelsDirectory: modelsPath)
    }
}

// MARK: - Performance Monitoring

extension DeepFilterNet {
    /// Process audio with performance measurement
    func processWithTiming(audio: [Float]) throws -> (output: [Float], latencyMs: Double) {
        let start = CFAbsoluteTimeGetCurrent()
        let output = try process(audio: audio)
        let end = CFAbsoluteTimeGetCurrent()
        
        let latencyMs = (end - start) * 1000.0
        return (output, latencyMs)
    }
}
