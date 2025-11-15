import Foundation
import Accelerate
import os.log

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
/// **Thread Safety**: This class IS thread-safe for external calls using a dual-queue architecture:
/// 
/// - **stateQueue**: Protects neural network state tensors (_states) with fine-grained locking
/// - **processingQueue**: Protects audio processing pipeline and overlapBuffer with coarse-grained locking
/// 
/// **Queue Hierarchy**: stateQueue and processingQueue are independent - no nested locking occurs.
/// The reset() method accesses each queue separately to avoid deadlocks.
/// 
/// **Thread Safety Guarantees**:
/// - Multiple threads can safely call process(), reset(), and other public methods
/// - Internal components (STFT, ERBFeatures, etc.) use their own queues for protection
/// - No shared mutable state is accessed without synchronization
///
/// Reference: https://arxiv.org/abs/2305.08227
///
/// **Usage Example**:
/// ```swift
/// let denoiser = try DeepFilterNet(modelsDirectory: "path/to/models")
/// let enhanced = try denoiser.process(audio: audioSamples)
/// ```
///
/// **Error Handling Patterns**:
/// - **Throwing Methods** (e.g., process()): Use for unrecoverable errors requiring caller intervention
///   - Invalid audio shape, ML inference failures, tensor dimension mismatches
///   - Caller should handle with appropriate recovery strategy
/// - **Async Non-Blocking** (e.g., reset()): Use for non-critical async cleanup to prevent deadlocks
///   - Completion handler provided for synchronization when needed
///   - Immediate state after method return may not be fully cleared
/// - **Validation Errors**: Use preconditionFailure for programming errors (e.g., buffer size mismatches)
final class DeepFilterNet: @unchecked Sendable {
    
    // MARK: - Components
    
    private let stft: STFT
    private let erbFeatures: ERBFeatures
    private let specFeatures: SpectralFeatures
    
    private let encoder: ONNXModel
    private let erbDecoder: ONNXModel
    private let dfDecoder: ONNXModel
    
    // MARK: - Configuration
    
    private let sampleRate: Int = AppConstants.sampleRate
    private let fftSize: Int = AppConstants.fftSize
    private let hopSize: Int = AppConstants.hopSize
    private let erbBands: Int = AppConstants.erbBands
    private let dfBands: Int = AppConstants.dfBands
    private let dfOrder: Int = AppConstants.dfOrder  // Deep filtering FIR filter order
    
    // MARK: - State Management with Thread Safety
    
    // Fix CRITICAL: Thread-safe state storage AND processing using dual-queue architecture
    
    /// Protects neural network state tensors with fine-grained synchronization
    private let stateQueue = DispatchQueue(label: "com.vocana.deepfilternet.state", qos: .userInteractive)

    /// Protects audio processing pipeline and buffers with coarse-grained synchronization
    private let processingQueue = DispatchQueue(label: "com.vocana.deepfilternet.processing", qos: .userInteractive)
    private var _states: [String: Tensor] = [:]
    private var states: [String: Tensor] {
        get { stateQueue.sync { _states } }
        set { stateQueue.sync { _states = newValue } }
    }
    
    // Fix CRITICAL: ISTFT overlap buffer for proper COLA reconstruction
    // Protected by: processingQueue
    private var overlapBuffer: [Float] = []
    
    // Logging
    private static let logger = Logger(subsystem: "com.vocana.ml", category: "DeepFilterNet")
    
    enum DeepFilterError: Error, LocalizedError {
        case modelLoadFailed(String)
        case processingFailed(String)
        case invalidAudioLength(got: Int, minimum: Int)
        case bufferTooLarge(got: Int, max: Int)

        var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let message):
                return "Model loading failed: \(message)"
            case .processingFailed(let message):
                return "Processing failed: \(message)"
            case .invalidAudioLength(let got, let minimum):
                return "Audio buffer too short: got \(got) samples, minimum \(minimum)"
            case .bufferTooLarge(let got, let max):
                return "Audio buffer too large: got \(got) samples, maximum \(max)"
            }
        }
    }
    
    /// Initialize DeepFilterNet with model paths
    ///
    /// - Parameter modelsDirectory: Directory containing ONNX models (enc.onnx, erb_dec.onnx, df_dec.onnx)
    ///                          Pass nil to use mock implementation for testing
    /// - Throws:
    ///   - `DeepFilterError.modelLoadFailed` if ONNX models cannot be loaded or directory doesn't exist
    convenience init(modelsDirectory: String?) throws {
        if let modelsDir = modelsDirectory {
            Self.logger.info("Initializing DeepFilterNet from \(modelsDir)")
        } else {
            Self.logger.info("Initializing DeepFilterNet with mock implementation")
        }

        // Initialize signal processing components
        let stft = STFT(fftSize: AppConstants.fftSize, hopSize: AppConstants.hopSize, sampleRate: AppConstants.sampleRate)
        let erbFeatures = ERBFeatures(
            numBands: AppConstants.erbBands,
            sampleRate: AppConstants.sampleRate,
            fftSize: AppConstants.fftSize
        )
        let specFeatures = SpectralFeatures(
            dfBands: AppConstants.dfBands,
            sampleRate: AppConstants.sampleRate,
            fftSize: AppConstants.fftSize
        )

        // Load ONNX models or use mock
        let encoder: ONNXModel
        let erbDecoder: ONNXModel
        let dfDecoder: ONNXModel

        if let modelsDir = modelsDirectory {
            // CRITICAL SECURITY: Sanitize models directory path to prevent traversal attacks
            let sanitizedModelsDir = try Self.sanitizeModelsDirectory(modelsDir)
            
            let encPath = "\(sanitizedModelsDir)/enc.onnx"
            let erbDecPath = "\(sanitizedModelsDir)/erb_dec.onnx"
            let dfDecPath = "\(sanitizedModelsDir)/df_dec.onnx"

            encoder = try Self.loadModel(path: encPath, name: "encoder")
            erbDecoder = try Self.loadModel(path: erbDecPath, name: "ERB decoder")
            dfDecoder = try Self.loadModel(path: dfDecPath, name: "DF decoder")
        } else {
            // Use mock implementation - create ONNXModel instances with mock sessions
            encoder = try Self.loadModel(path: "enc", name: "encoder", useMock: true)
            erbDecoder = try Self.loadModel(path: "erb_dec", name: "ERB decoder", useMock: true)
            dfDecoder = try Self.loadModel(path: "df_dec", name: "DF decoder", useMock: true)
        }
        
        // Initialize with dependency injection
        self.init(
            stft: stft,
            erbFeatures: erbFeatures,
            specFeatures: specFeatures,
            encoder: encoder,
            erbDecoder: erbDecoder,
            dfDecoder: dfDecoder
        )
    }
    
    /// Dependency injection initializer for testing and modular design
    /// - Parameters:
    ///   - stft: STFT processor
    ///   - erbFeatures: ERB feature extractor
    ///   - specFeatures: Spectral feature extractor
    ///   - encoder: ONNX encoder model
    ///   - erbDecoder: ONNX ERB decoder model
    ///   - dfDecoder: ONNX DF decoder model
    init(
        stft: STFT,
        erbFeatures: ERBFeatures,
        specFeatures: SpectralFeatures,
        encoder: ONNXModel,
        erbDecoder: ONNXModel,
        dfDecoder: ONNXModel
    ) {
        Self.logger.info("Initializing DeepFilterNet with dependency injection")
        
        // Use injected dependencies
        self.stft = stft
        self.erbFeatures = erbFeatures
        self.specFeatures = specFeatures
        self.encoder = encoder
        self.erbDecoder = erbDecoder
        self.dfDecoder = dfDecoder
        
        Self.logger.info("✓ DeepFilterNet initialized successfully")
        Self.logger.debug("  Sample rate: \(self.sampleRate) Hz")
        Self.logger.debug("  FFT size: \(self.fftSize)")
        Self.logger.debug("  Hop size: \(self.hopSize)")
        Self.logger.debug("  ERB bands: \(self.erbBands)")
        Self.logger.debug("  DF bands: \(self.dfBands)")
    }
    
    // Fix MEDIUM: deinit is nonisolated by default, logging handled asynchronously
    deinit {
        // Note: deinit is nonisolated, logger is thread-safe
        // State cleanup handled by ARC - manual cleanup should be done via reset() before deallocation
        // Logger calls are generally safe in deinit - no Task wrapper needed
        Self.logger.debug("DeepFilterNet deinitialized")
    }
    
     /// Reset internal state (call when starting new audio stream)
     /// 
     /// - Parameter completion: Optional closure called on the main queue when reset completes
     /// 
     /// This method is now async to prevent potential deadlocks during high-load scenarios.
     /// **IMPORTANT**: Callers cannot guarantee that state is cleared immediately after this method returns.
     /// If process() is called immediately after reset(), partial state may still exist.
     /// For critical cleanup sequences, use `resetSync()` instead (with caution about deadlock potential).
     /// Use `resetSync()` if you need synchronous behavior and can guarantee no deadlock risk.
     func reset(completion: (() -> Void)? = nil) {
         // Fix CRITICAL: Use async dispatch to prevent potential deadlock
         // This ensures reset never blocks if queues are under heavy load
         let group = DispatchGroup()
         
         group.enter()
         stateQueue.async { [weak self] in
             self?._states.removeAll()  // Explicit cleanup for clarity
             group.leave()
         }
         
         group.enter()
         processingQueue.async { [weak self] in
             self?.overlapBuffer.removeAll()
             group.leave()
         }
         
         if let completion = completion {
             group.notify(queue: .main) {
                 completion()
             }
         }
         
         Self.logger.info("DeepFilterNet async reset initiated - clearing states and overlap buffer")
     }
    
    /// Synchronous reset for testing and scenarios where immediate completion is required
    /// 
    /// ⚠️ Use with caution: Can potentially deadlock if called during heavy processing load
    func resetSync() {
        // Original synchronous implementation for compatibility
        stateQueue.sync {
            _states = [:]
        }
        
        processingQueue.sync {
            overlapBuffer.removeAll()
        }
        
        Self.logger.info("DeepFilterNet sync reset completed - cleared states and overlap buffer")
    }
    
    // MARK: - Processing
    
    /// Process audio frame through DeepFilterNet
    ///
    /// - Parameter audio: Input audio samples (minimum fftSize samples)
    /// - Returns: Enhanced audio samples
    /// - Throws: DeepFilterError if processing fails
    func process(audio: [Float]) throws -> [Float] {
        // Fix CRITICAL: Wrap entire processing in queue to prevent concurrent access
        // to non-thread-safe components (STFT, ERBFeatures, SpectralFeatures)
        return try processingQueue.sync {
            // Fix MEDIUM: Use configurable maximum size to prevent memory exhaustion attacks
            // Allows 1 hour of audio processing while preventing DoS attacks
            let maxAudioSize = sampleRate * AppConstants.maxAudioProcessingSeconds
            guard audio.count >= fftSize && audio.count <= maxAudioSize else {
                if audio.count < fftSize {
                    throw DeepFilterError.invalidAudioLength(got: audio.count, minimum: fftSize)
                } else {
                    throw DeepFilterError.bufferTooLarge(got: audio.count, max: maxAudioSize)
                }
            }
            
            // Fix LOW: Add denormal detection
            // Fix CRITICAL-006: Comprehensive audio input validation
            guard audio.allSatisfy({ sample in
                sample.isFinite && 
                abs(sample) <= AppConstants.maxAudioAmplitude &&
                (sample.isZero || abs(sample) >= Float.leastNormalMagnitude)
            }) else {
                let invalidSamples = audio.enumerated().compactMap { index, sample in
                    if sample.isNaN { return "NaN at \(index)" }
                    if sample.isInfinite { return "Infinity at \(index)" }
                    if abs(sample) > AppConstants.maxAudioAmplitude { return "Amplitude \(sample) at \(index)" }
                    if !sample.isZero && abs(sample) < Float.leastNormalMagnitude { return "Denormal \(sample) at \(index)" }
                    return nil
                }
                throw DeepFilterError.processingFailed("Invalid audio values detected: \(invalidSamples.prefix(5).joined(separator: ", "))")
            }
            
            // Check for denormals (can slow down processing 100x)
            #if DEBUG
            let denormals = audio.filter { $0 != 0 && abs($0) < Float.leastNormalMagnitude }
            if !denormals.isEmpty {
                Self.logger.warning("Input contains \(denormals.count) denormal values")
            }
            #endif
            
            return try self.processInternal(audio: audio)
        }
    }
    
    private func processInternal(audio: [Float]) throws -> [Float] {
        
        do {
            // 1. STFT - Convert to frequency domain
            let spectrum2D = stft.transform(audio)
            
            // Fix HIGH: Validate STFT output
            guard !spectrum2D.real.isEmpty, !spectrum2D.imag.isEmpty else {
                Self.logger.warning("STFT returned empty spectrum for \(audio.count) samples")
                return audio  // Not enough samples, return input as-is
            }
            
            // Fix HIGH: Validate spectrum dimensions
            let expectedBins = fftSize / 2 + 1
            if let firstFrame = spectrum2D.real.first, firstFrame.count != expectedBins {
                Self.logger.error("STFT returned \(firstFrame.count) bins, expected \(expectedBins)")
                throw DeepFilterError.processingFailed("Invalid STFT output dimensions")
            }
            
            // OPTIMIZED: Use flatMap for O(n) complexity (already optimal)
            // flatMap is O(n) - each element is visited exactly once
            let spectrumReal = spectrum2D.real.flatMap { $0 }
            let spectrumImag = spectrum2D.imag.flatMap { $0 }
            let spectrum = (real: spectrumReal, imag: spectrumImag)

            // 2. Extract features
            let erbFeat = try extractERBFeatures(spectrum2D: spectrum2D)
            let specFeat = try extractSpectralFeatures(spectrum2D: spectrum2D)

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
            // Fix CRITICAL: Preserve ISTFT overlap for proper COLA reconstruction
            let enhancedReal2D = [enhanced.real]
            let enhancedImag2D = [enhanced.imag]
            let outputAudio = stft.inverse(real: enhancedReal2D, imag: enhancedImag2D)
            
            // Accumulate overlap and return exactly hopSize samples
            overlapBuffer.append(contentsOf: outputAudio)
            
            // Fix CRITICAL: Handle first frame properly to avoid audio discontinuities
            guard overlapBuffer.count >= hopSize else {
                // First frame: pad with zeros at beginning, use available samples
                // This maintains temporal continuity instead of returning all zeros
                let availableSamples = min(overlapBuffer.count, hopSize)
                var frame = [Float](repeating: 0, count: hopSize)
                
                if availableSamples > 0 {
                    // Copy available samples to the end of the frame (maintain timing)
                    let startIndex = hopSize - availableSamples
                    frame[startIndex..<hopSize] = ArraySlice(overlapBuffer.prefix(availableSamples))
                    overlapBuffer.removeAll() // Clear the buffer since we used all samples
                }
                
                return frame
            }
            
            // Extract hopSize samples and keep remainder for next frame
            let frame = Array(overlapBuffer.prefix(hopSize))
            overlapBuffer.removeFirst(hopSize)
            
            return frame
            
        } catch let error as DeepFilterError {
            throw error
        } catch {
            throw DeepFilterError.processingFailed("Processing failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Feature Extraction
    
    private func extractERBFeatures(spectrum2D: (real: [[Float]], imag: [[Float]])) throws -> Tensor {
        // Extract ERB bands for all frames
        let erbBands2D = erbFeatures.extract(spectrogramReal: spectrum2D.real, spectrogramImag: spectrum2D.imag)

        // Normalize (alpha=0.9 for ERB features)
        let normalized2D = erbFeatures.normalize(erbBands2D, alpha: 0.9)

        // Flatten all frames for tensor input
        let normalized = normalized2D.flatMap { $0 }

        // Fix MEDIUM: Pre-compute expected shape with overflow protection
        let numFrames = spectrum2D.real.count
        let expectedCount = try safeMultiply(numFrames, erbBands)
        guard normalized.count == expectedCount else {
            throw DeepFilterError.processingFailed("ERB feature count mismatch: got \(normalized.count), expected \(expectedCount)")
        }

        // Reshape to [1, 1, numFrames, erbBands] for ONNX model
        return Tensor(shape: [1, 1, numFrames, erbBands], data: normalized)
    }
    
    private func extractSpectralFeatures(spectrum2D: (real: [[Float]], imag: [[Float]])) throws -> Tensor {
        // Extract spectral features for all frames
        let dfSpec = try specFeatures.extract(spectrogramReal: spectrum2D.real, spectrogramImag: spectrum2D.imag)

        // Normalize (alpha=0.6 for spectral features)
        let normalized = specFeatures.normalize(dfSpec, alpha: 0.6)

        // Fix HIGH: Better error context
        guard !normalized.isEmpty else {
            throw DeepFilterError.processingFailed(
                "No spectral features extracted: input frames=\(spectrum2D.real.count)"
            )
        }

        // For multiple frames, we need to handle the data differently
        // The spectral features are returned as [[[Float]]] - frames x channels x bands
        // We need to flatten this properly for the tensor

        var data: [Float] = []
        let numFrames = normalized.count
        let capacity = try safeMultiply(try safeMultiply(numFrames, 2), dfBands)  // 2 channels (real/imag) per frame
        data.reserveCapacity(capacity)

        for frame in normalized {
            guard frame.count >= 2 else {
                throw DeepFilterError.processingFailed("Invalid spectral frame structure")
            }
            data.append(contentsOf: frame[0])  // real channel
            data.append(contentsOf: frame[1])  // imag channel
        }

        return Tensor(shape: [1, 2, numFrames, dfBands], data: data)
    }
    
    // MARK: - Model Inference
    
    private func runEncoder(erbFeat: Tensor, specFeat: Tensor) throws -> [String: Tensor] {
        let inputs: [String: Tensor] = [
            "erb_feat": erbFeat,
            "spec_feat": specFeat
        ]
        
        let outputs = try encoder.infer(inputs: inputs)
        
        // Fix HIGH: Validate encoder outputs before using
        let requiredKeys = ["e0", "e1", "e2", "e3", "emb", "c0", "lsnr"]
        for key in requiredKeys {
            guard outputs.keys.contains(key) else {
                throw DeepFilterError.processingFailed("Missing encoder output: \(key)")
            }
        }
        
        // Fix CRITICAL: Use proper state synchronization through computed property
        // Fix CRITICAL #6: Clear old states before storing new ones to prevent memory leak
        
        // Deep copy new states outside the queue for better performance
        let copiedOutputs = outputs.mapValues { tensor in
            Tensor(shape: tensor.shape, data: Array(tensor.data))
        }
        
         // Fix CRITICAL: Improved memory management for state updates
         // Use autoreleasepool to ensure prompt memory cleanup during sustained processing
         stateQueue.sync {
             autoreleasepool {
                 // Explicitly clear old states before assignment to ensure prompt deallocation
                 // This is more explicit than relying on ARC's deallocation timing
                 _states.removeAll()
                 _states = copiedOutputs
                 
                 // autoreleasepool ensures any temporary Tensor objects from removeAll()
                 // are deallocated promptly rather than accumulating in autorelease pool
             }
         }
        return copiedOutputs
    }
    
    private func runERBDecoder(states: [String: Tensor]) throws -> [Float] {
        let outputs = try erbDecoder.infer(inputs: states)
        
        // Fix MEDIUM: Validate output exists and has valid data
        guard let maskTensor = outputs["m"] else {
            let availableKeys = outputs.keys.joined(separator: ", ")
            throw DeepFilterError.processingFailed("ERB decoder output missing 'm' key. Available: \(availableKeys)")
        }
        
        // Fix MEDIUM: Validate mask data
        guard !maskTensor.data.isEmpty,
              maskTensor.data.allSatisfy({ $0.isFinite }) else {
            throw DeepFilterError.processingFailed("Invalid mask data from ERB decoder")
        }
        
        return maskTensor.data
    }
    
    private func runDFDecoder(states: [String: Tensor]) throws -> [Float] {
        let outputs = try dfDecoder.infer(inputs: states)
        
        // Fix MEDIUM: Validate output exists
        guard let coefsTensor = outputs["coefs"] else {
            let availableKeys = outputs.keys.joined(separator: ", ")
            throw DeepFilterError.processingFailed("DF decoder output missing 'coefs' key. Available: \(availableKeys)")
        }
        
        // Fix HIGH: Validate coefficient array size
        let expectedSize = 1 * dfBands * dfOrder
        guard coefsTensor.data.count == expectedSize else {
            throw DeepFilterError.processingFailed("Coefficient size \(coefsTensor.data.count) doesn't match expected \(expectedSize)")
        }
        
        return coefsTensor.data
    }
    
    // MARK: - Filtering
    
    private func applyFiltering(
        spectrum: (real: [Float], imag: [Float]),
        mask: [Float],
        coefficients: [Float]
    ) throws -> (real: [Float], imag: [Float]) {
        // Fix HIGH: Validate mask size matches spectrum
        guard mask.count == spectrum.real.count else {
            throw DeepFilterError.processingFailed("Mask size \(mask.count) doesn't match spectrum size \(spectrum.real.count)")
        }
        
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
    
    /// Helper method to load ONNX models with consistent error handling
    /// - Parameters:
    ///   - path: Path to the ONNX model file
    ///   - name: Human-readable name for error messages
    /// - Returns: Loaded ONNXModel instance
    /// - Throws: DeepFilterError.modelLoadFailed if model cannot be loaded
    /// Sanitizes models directory path to prevent directory traversal attacks
    /// - Parameter modelsDirectory: User-provided models directory path
    /// - Returns: Sanitized canonical path safe to use
    /// - Throws: DeepFilterError if path is invalid or outside allowed directories
    private static func sanitizeModelsDirectory(_ modelsDirectory: String) throws -> String {
        let fm = FileManager.default
        
        // Basic path validation
        guard !modelsDirectory.isEmpty else {
            throw DeepFilterError.modelLoadFailed("Empty models directory path")
        }

        // Prevent obvious traversal attempts
        guard !modelsDirectory.contains("../") && !modelsDirectory.contains("..\\") && !modelsDirectory.hasPrefix("/") else {
            throw DeepFilterError.modelLoadFailed("Invalid directory format: potential traversal attack")
        }
        
        // Resolve and validate path within app sandbox
        let url = URL(fileURLWithPath: modelsDirectory)
        let resolvedURL = url.standardizedFileURL
        let resolvedPath = resolvedURL.path
        
        // Restrict to app bundle and known safe directories only
        var allowedPaths: Set<String> = Set([
            Bundle.main.resourcePath,
            Bundle.main.bundlePath,
        ].compactMap { basePath in
            guard let basePath = basePath, !basePath.isEmpty else { return nil }
            return URL(fileURLWithPath: basePath).standardizedFileURL.path
        })

        // Allow Resources/Models directory for testing and development
        if let resourcesModelsPath = Bundle.main.resourceURL?.appendingPathComponent("Models").path {
            allowedPaths.insert(resourcesModelsPath)
        }
        
        // CRITICAL SECURITY: Removed insecure currentDirectoryPath inclusion
        // Only allow explicitly configured or app bundle paths
        
        // Strict path validation - must be within allowed directories
        let isPathAllowed = allowedPaths.contains { allowedPath in
            // Must be exactly within allowed path or subdirectory
            resolvedPath == allowedPath || resolvedPath.hasPrefix(allowedPath + "/")
        }
        
        guard isPathAllowed else {
            throw DeepFilterError.modelLoadFailed("Models directory not in allowed directories: \(resolvedPath)")
        }
        
        // Verify directory exists and is accessible
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: resolvedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DeepFilterError.modelLoadFailed("Models directory does not exist or is not a directory: \(resolvedPath)")
        }
        
        return resolvedPath
    }

    private static func loadModel(path: String, name: String, useMock: Bool = false) throws -> ONNXModel {
        if useMock {
            // Create mock ONNX model without requiring file to exist
            return try ONNXModel(modelPath: path, useNative: false)
        }

        guard FileManager.default.fileExists(atPath: path) else {
            throw DeepFilterError.modelLoadFailed("\(name) model not found: \(path)")
        }

        do {
            return try ONNXModel(modelPath: path)
        } catch {
            throw DeepFilterError.modelLoadFailed("Failed to load \(name) model: \(error.localizedDescription)")
        }
    }
    
    // Removed unused spectrumToMagnitude method as identified in code review
    
    /// Process entire audio buffer (for batch processing)
    ///
    /// - Parameter audio: Input audio samples (any length)
    /// - Returns: Enhanced audio samples
    /// - Throws: DeepFilterError if buffer is too large or processing fails
    /// - Note: For buffers longer than 10 seconds, consider processing in smaller batches
    ///   to reduce peak memory usage. Maximum buffer duration is 60 seconds.
    /// - Warning: Peak memory usage is approximately 4 * audio.count bytes (input + output + intermediate buffers)
    func processBuffer(_ audio: [Float]) throws -> [Float] {
        // Fix MEDIUM: Make max buffer size configurable
        let maxBufferDuration = 60  // seconds
        let maxBufferSize = sampleRate * maxBufferDuration
        
        // Fix HIGH: Integer overflow protection
        guard audio.count <= maxBufferSize else {
            throw DeepFilterError.bufferTooLarge(got: audio.count, max: maxBufferSize)
        }
        
        // Need at least fftSize samples to process
        guard audio.count >= fftSize else {
            return audio
        }
        
        // Fix HIGH: Validate hopSize to prevent infinite loop
        guard self.hopSize > 0 else {
            Self.logger.error("Invalid hopSize: \(self.hopSize)")
            return audio
        }
        
        var output: [Float] = []
        output.reserveCapacity(audio.count)
        
        // Process in chunks
        // Fix HIGH: Add autoreleasepool to prevent memory accumulation in loop
        var position = 0
        while position + fftSize <= audio.count {
            autoreleasepool {
                // Fix HIGH: Bounds checking
                guard position + fftSize <= audio.count else {
                    return  // Skip invalid chunks
                }
                
                let chunk = Array(audio[position..<position + fftSize])
                
                // Fix HIGH: Handle errors gracefully instead of silently dropping
                do {
                    let enhanced = try process(audio: chunk)
                    let outputChunk = Array(enhanced.prefix(hopSize))
                    output.append(contentsOf: outputChunk)
                } catch {
                    Self.logger.error("Chunk processing failed at position \(position): \(error)")
                    // Append original chunk to maintain temporal continuity
                    let fallbackChunk = Array(chunk.prefix(hopSize))
                    output.append(contentsOf: fallbackChunk)
                }
            }
            
            // Fix CRITICAL: Check for integer overflow in position increment
            let (newPosition, overflow) = position.addingReportingOverflow(self.hopSize)
            guard !overflow else {
                Self.logger.error("Position overflow at \(position) + \(self.hopSize)")
                break  // Exit loop to prevent corruption
            }
            position = newPosition
        }
        
        // Handle remaining samples
        // Fix HIGH: Add autoreleasepool here too
        // Fix HIGH: Document memory implications for long buffers
        if position < audio.count {
            autoreleasepool {
                let remaining = audio.count - position
                var lastChunk = Array(audio[position..<audio.count])
                
                 // Fix HIGH: Add size limit to reflection padding to prevent unbounded arrays
                 if remaining < fftSize {
                     let padCount = fftSize - remaining
                     
                     // Fix MEDIUM: Ensure maxAudioBufferSize is large enough for reflection padding
                     precondition(AppConstants.maxAudioBufferSize >= fftSize * AppConstants.minBufferForReflectionRatio,
                                "maxAudioBufferSize (\(AppConstants.maxAudioBufferSize)) must be at least " +
                                "\(fftSize * AppConstants.minBufferForReflectionRatio) (fftSize * \(AppConstants.minBufferForReflectionRatio)) " +
                                "for proper reflection padding")
                     
                     // Limit reflection to reasonable size (max 2x FFT size) to prevent memory issues
                     let maxReflectSize = min(fftSize * 2, AppConstants.maxAudioBufferSize)
                     let reflectCount = min(padCount, remaining, maxReflectSize)
                    
                    // Fix CRITICAL: More robust reflection padding with edge case handling
                    guard reflectCount > 0, audio.count >= reflectCount else {
                        // Skip reflection if not enough data, use zero padding instead
                        lastChunk.append(contentsOf: Array(repeating: 0.0, count: padCount))
                        return
                    }
                    
                    // Use safe clamping for reflection indices
                    let reflectStartIndex = max(0, audio.count - reflectCount)
                    let reflectEndIndex = min(audio.count, reflectStartIndex + reflectCount)
                    
                    guard reflectStartIndex < reflectEndIndex else {
                        // Degenerate case, use zero padding
                        lastChunk.append(contentsOf: Array(repeating: 0.0, count: padCount))
                        return
                    }
                    
                    // Apply reflection with bounds validation
                    let reflectionSlice = audio[reflectStartIndex..<reflectEndIndex]
                    lastChunk.append(contentsOf: reflectionSlice.reversed())
                    
                    // Fill remaining space with zeros if reflection wasn't enough
                    let remainingPadding = padCount - reflectionSlice.count
                    if remainingPadding > 0 {
                        lastChunk.append(contentsOf: Array(repeating: 0.0, count: remainingPadding))
                    }
                    
                    if lastChunk.count < fftSize {
                        lastChunk.append(contentsOf: Array(repeating: 0.0, count: fftSize - lastChunk.count))
                    }
                }
                
                // Fix HIGH: Handle errors gracefully
                do {
                    let enhanced = try process(audio: lastChunk)
                    let outputChunk = Array(enhanced.prefix(remaining))
                    output.append(contentsOf: outputChunk)
                } catch {
                    Self.logger.error("Last chunk processing failed: \(error)")
                    // Append original to maintain continuity
                    output.append(contentsOf: audio[position..<audio.count])
                }
            }
        }
        
        return output
    }
}

// MARK: - Convenience Initializer

extension DeepFilterNet {
    /// Initialize with default model location (Resources/Models/)
    static func withDefaultModels() throws -> DeepFilterNet {
        let resourcePath = Bundle.main.resourcePath ?? "."
        let modelsPath = "\(resourcePath)/Models"

        let encPath = "\(modelsPath)/enc.onnx"

        // Check if models exist, if not, use mock implementation
        if FileManager.default.fileExists(atPath: encPath) {
            return try DeepFilterNet(modelsDirectory: modelsPath)
        } else {
            // Use mock implementation for testing/development
            Self.logger.info("ONNX models not found, using mock implementation")
            return try DeepFilterNet(modelsDirectory: nil) // nil triggers mock mode
        }
    }
}

// MARK: - Performance Monitoring

extension DeepFilterNet {
    /// Process audio with performance measurement
    func processWithTiming(audio: [Float]) throws -> (output: [Float], latencyMs: Double) {
        let start = CFAbsoluteTimeGetCurrent()
        
        do {
            let output = try process(audio: audio)
            let end = CFAbsoluteTimeGetCurrent()
            let latencyMs = (end - start) * 1000.0
            return (output, latencyMs)
        } catch {
            let end = CFAbsoluteTimeGetCurrent()
            let latencyMs = (end - start) * 1000.0
            DeepFilterNet.logger.warning("Processing failed after \(latencyMs)ms: \(error)")
            throw error
        }
    }
}
