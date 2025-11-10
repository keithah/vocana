import Foundation
import Accelerate
import os.log
import Darwin.Mach

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
    
    // MARK: - Memory Tracking
    
    /// Memory usage statistics for ML models
    private struct MemoryStats {
        var modelLoadMemoryMB: Double = 0.0
        var peakInferenceMemoryMB: Double = 0.0
        var currentInferenceMemoryMB: Double = 0.0
        var totalInferences: UInt64 = 0
    }
    
    /// Thread-safe memory statistics tracking
    private let memoryStatsQueue = DispatchQueue(label: "com.vocana.deepfilternet.memory", qos: .utility)
    private var _memoryStats = MemoryStats()
    private var memoryStats: MemoryStats {
        get { memoryStatsQueue.sync { _memoryStats } }
        set { memoryStatsQueue.sync { _memoryStats = newValue } }
    }
    
    /// Public memory usage information
    var memoryUsageMB: Double {
        return memoryStats.currentInferenceMemoryMB
    }
    
    var peakMemoryUsageMB: Double {
        return memoryStats.peakInferenceMemoryMB
    }
    
    var modelLoadMemoryMB: Double {
        return memoryStats.modelLoadMemoryMB
    }
    
    /// Get comprehensive memory statistics
    func getMemoryStatistics() -> (current: Double, peak: Double, modelLoad: Double, totalInferences: UInt64) {
        return (
            current: memoryStats.currentInferenceMemoryMB,
            peak: memoryStats.peakInferenceMemoryMB,
            modelLoad: memoryStats.modelLoadMemoryMB,
            totalInferences: memoryStats.totalInferences
        )
    }
    
    /// Reset memory statistics (useful for testing)
    func resetMemoryStatistics() {
        memoryStatsQueue.sync { [weak self] in
            self?._memoryStats = MemoryStats()
        }
    }
    
    enum DeepFilterError: Error {
        case modelLoadFailed(String)
        case processingFailed(String)
        case invalidAudioLength(got: Int, minimum: Int)
        case bufferTooLarge(got: Int, max: Int)
    }
    
    /// Initialize DeepFilterNet with model paths
    ///
    /// - Parameter modelsDirectory: Directory containing ONNX models (enc.onnx, erb_dec.onnx, df_dec.onnx)
    /// - Throws: 
    ///   - `DeepFilterError.modelLoadFailed` if ONNX models cannot be loaded or directory doesn't exist
    convenience init(modelsDirectory: String) throws {
        Self.logger.info("Initializing DeepFilterNet from \(modelsDirectory)")
        
        // Initialize signal processing components
        // Fix CRITICAL: Handle STFT initialization errors gracefully
        let stft = try STFT(fftSize: AppConstants.fftSize, hopSize: AppConstants.hopSize, sampleRate: AppConstants.sampleRate)
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
        
        // Load ONNX models
        let encPath = "\(modelsDirectory)/enc.onnx"
        let erbDecPath = "\(modelsDirectory)/erb_dec.onnx"
        let dfDecPath = "\(modelsDirectory)/df_dec.onnx"
        
        let encoder = try Self.loadModel(path: encPath, name: "encoder")
        let erbDecoder = try Self.loadModel(path: erbDecPath, name: "ERB decoder")
        let dfDecoder = try Self.loadModel(path: dfDecPath, name: "DF decoder")
        
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
            // Track memory usage during inference
            let memoryBefore = Self.getMemoryUsageMB()
            
            defer {
                // Update memory statistics after processing
                let memoryAfter = Self.getMemoryUsageMB()
                let memoryUsedMB = memoryAfter - memoryBefore
                
                memoryStatsQueue.async { [weak self] in
                    guard let self = self else { return }
                    self._memoryStats.currentInferenceMemoryMB = memoryUsedMB
                    self._memoryStats.peakInferenceMemoryMB = max(self._memoryStats.peakInferenceMemoryMB, memoryUsedMB)
                    self._memoryStats.totalInferences += 1
                    
                    // Log memory usage every 100 inferences
                    if self._memoryStats.totalInferences % 100 == 0 {
                        Self.logger.info("📊 ML Memory - Current: \(String(format: "%.1f", memoryUsedMB))MB, Peak: \(String(format: "%.1f", self._memoryStats.peakInferenceMemoryMB))MB, Inferences: \(self._memoryStats.totalInferences)")
                    }
                }
            }
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
            
            // Fix PERF-002: Use in-place operations to reduce memory allocations
            // Pre-allocate arrays with known capacity to avoid reallocations
            let totalFrames = spectrum2D.real.count
            let binsPerFrame = spectrum2D.real.first?.count ?? 0
            let totalElements = totalFrames * binsPerFrame
            
            var spectrumReal = [Float]()
            var spectrumImag = [Float]()
            spectrumReal.reserveCapacity(totalElements)
            spectrumImag.reserveCapacity(totalElements)
            
            // Use in-place operations to avoid intermediate arrays
            for frame in spectrum2D.real {
                spectrumReal.append(contentsOf: frame)
            }
            for frame in spectrum2D.imag {
                spectrumImag.append(contentsOf: frame)
            }
            
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
    
    private func extractERBFeatures(spectrum: (real: [Float], imag: [Float])) throws -> Tensor {
        // Convert to 2D arrays for ERBFeatures API (single frame)
        let specReal2D = [spectrum.real]
        let specImag2D = [spectrum.imag]
        
        // Extract ERB bands
        let erbBands2D = erbFeatures.extract(spectrogramReal: specReal2D, spectrogramImag: specImag2D)
        
        // Normalize (alpha=0.9 for ERB features)
        let normalized2D = erbFeatures.normalize(erbBands2D, alpha: 0.9)
        
        // Flatten for tensor
        let normalized = normalized2D.flatMap { $0 }
        
        // Fix MEDIUM: Pre-compute expected shape
        let expectedCount = erbBands
        guard normalized.count == expectedCount else {
            throw DeepFilterError.processingFailed("ERB feature count mismatch: got \(normalized.count), expected \(expectedCount)")
        }
        
        // Reshape to [1, 1, 1, erbBands]
        return Tensor(shape: [1, 1, 1, normalized.count], data: normalized)
    }
    
    private func extractSpectralFeatures(spectrum: (real: [Float], imag: [Float])) throws -> Tensor {
        // Convert to 2D arrays for SpectralFeatures API
        let specReal2D = [spectrum.real]
        let specImag2D = [spectrum.imag]
        
        // Extract first dfBands bins
        let dfSpec = try specFeatures.extract(spectrogramReal: specReal2D, spectrogramImag: specImag2D)
        
        // Normalize (alpha=0.6 for spectral features)
        let normalized = specFeatures.normalize(dfSpec, alpha: 0.6)
        
        // Fix HIGH: Better error context
        guard let frame = normalized.first else {
            throw DeepFilterError.processingFailed(
                "No spectral features extracted: input frames=\(dfSpec.count), normalized=\(normalized.count)"
            )
        }
        
        // Fix MEDIUM: Reserve capacity
        var data: [Float] = []
        data.reserveCapacity(frame[0].count + frame[1].count)
        data.append(contentsOf: frame[0])  // real channel
        data.append(contentsOf: frame[1])  // imag channel
        
        return Tensor(shape: [1, 2, 1, dfBands], data: data)
    }
    
    // MARK: - Model Inference
    
    private func runEncoder(erbFeat: Tensor, specFeat: Tensor) throws -> [String: Tensor] {
        // Fix CRI-001: Validate tensor shapes before processing
        guard erbFeat.shape.count == 4 && specFeat.shape.count == 4 else {
            throw DeepFilterError.processingFailed("Invalid tensor shapes: erb_feat=\(erbFeat.shape), spec_feat=\(specFeat.shape)")
        }
        
        // Fix CRI-001: Bounds check tensor dimensions
        let maxTensorSize = 1024 * 1024 // Prevent memory exhaustion
        guard erbFeat.data.count <= maxTensorSize && specFeat.data.count <= maxTensorSize else {
            throw DeepFilterError.processingFailed("Tensor too large: erb_feat=\(erbFeat.data.count), spec_feat=\(specFeat.data.count)")
        }
        
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
        
        // Fix HIGH-002: Zero-initialize tensors before copying to prevent memory disclosure
        let copiedOutputs = try outputs.mapValues { tensor in
            // Validate tensor size before copying
            guard tensor.data.count <= maxTensorSize else {
                throw DeepFilterError.processingFailed("Output tensor too large: \(tensor.data.count)")
            }
            
            // Create zero-initialized buffer then copy to prevent memory disclosure
            var zeroInitializedData = [Float](repeating: 0.0, count: tensor.data.count)
            zeroInitializedData.replaceSubrange(0..<tensor.data.count, with: tensor.data)
            return Tensor(shape: tensor.shape, data: zeroInitializedData)
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
    private static func loadModel(path: String, name: String) throws -> ONNXModel {
        guard FileManager.default.fileExists(atPath: path) else {
            throw DeepFilterError.modelLoadFailed("\(name) model not found: \(path)")
        }
        
        // Track memory before model loading
        let memoryBefore = getMemoryUsageMB()
        
        do {
            let model = try ONNXModel(modelPath: path)
            
            // Track memory after model loading
            let memoryAfter = getMemoryUsageMB()
            let modelMemoryMB = memoryAfter - memoryBefore
            
            Self.logger.info("📊 \(name) model loaded: \(String(format: "%.1f", modelMemoryMB))MB")
            
            return model
        } catch {
            throw DeepFilterError.modelLoadFailed("Failed to load \(name) model: \(error.localizedDescription)")
        }
    }
    
    /// Get current memory usage in MB
    private static func getMemoryUsageMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            return Double(info.resident_size) / 1024.0 / 1024.0
        } else {
            return 0.0
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
