//
//  MetalNeuralLayers.swift
//  Vocana
//
//  GPU-accelerated neural network layers using Metal compute shaders
//

import Metal
import MetalPerformanceShaders
import os.log

// MARK: - Advanced GPU Operation Structures

struct BatchConv1DConstants {
    let batchSize: Int32
    let inputChannels: Int32
    let outputChannels: Int32
    let kernelSize: Int32
    let stride: Int32
    let inputLength: Int32
    let outputLength: Int32
}

struct AttentionConstants {
    let batchSize: Int32
    let seqLength: Int32
    let numHeads: Int32
    let headDim: Int32
    let modelDim: Int32
}

struct FusedConvActivationConstants {
    let inputChannels: Int32
    let outputChannels: Int32
    let kernelSize: Int32
    let stride: Int32
    let inputLength: Int32
    let outputLength: Int32
    let activationType: Int32
}

struct QuantizedConvConstants {
    let inputChannels: Int32
    let outputChannels: Int32
    let kernelSize: Int32
    let stride: Int32
    let inputLength: Int32
    let outputLength: Int32
    let scale: Float
    let zeroPoint: Int32
}

struct AdvancedSTFTConstants {
    let fftSize: Int32
    let hopSize: Int32
    let windowSize: Int32
    let numFrames: Int32
    let numChannels: Int32
    let useHannWindow: Bool
    let scaleFactor: Float
}

struct TransformerConstants {
    let batchSize: Int32
    let seqLength: Int32
    let modelDim: Int32
    let numHeads: Int32
    let ffDim: Int32
}

/// Metal-based GPU acceleration for neural network operations
class MetalNeuralProcessor {
    private let logger = Logger(subsystem: "com.vocana.ml", category: "metal")

    // Metal components
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var library: MTLLibrary?

    // Compute pipelines for different operations
    private var conv1DPipeline: MTLComputePipelineState?
    private var linearPipeline: MTLComputePipelineState?
    private var gruPipeline: MTLComputePipelineState?
    private var reluPipeline: MTLComputePipelineState?
    private var sigmoidPipeline: MTLComputePipelineState?
    private var tanhPipeline: MTLComputePipelineState?

    // MPS components for optimized operations
    private var mpsMatrixMultiplication: MPSMatrixMultiplication?

    // Buffer pool for memory management
    private var bufferPool: [Int: [MTLBuffer]] = [:] // Size -> [Buffers]
    private let bufferPoolMaxSize = 10 // Maximum buffers per size
    private let bufferPoolQueue = DispatchQueue(label: "com.vocana.metal.bufferpool")

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            logger.warning("Metal device not available, GPU acceleration disabled")
            return nil
        }

        self.device = device
        self.commandQueue = device.makeCommandQueue()

        do {
            try setupMetalShaders()
            try setupMPS()
            logger.info("✅ Metal GPU acceleration initialized successfully")
        } catch {
            logger.error("Failed to initialize Metal GPU acceleration: \(error.localizedDescription)")
            return nil
        }
    }

    private func setupMetalShaders() throws {
        // Load Metal shaders from bundle
        guard let library = device?.makeDefaultLibrary() else {
            throw MetalError.libraryCreationFailed
        }
        self.library = library

        // Create compute pipelines
        conv1DPipeline = try createComputePipeline(functionName: "conv1d_forward")
        linearPipeline = try createComputePipeline(functionName: "linear_forward")
        gruPipeline = try createComputePipeline(functionName: "gru_forward")
        reluPipeline = try createComputePipeline(functionName: "relu_activation")
        sigmoidPipeline = try createComputePipeline(functionName: "sigmoid_activation")
        tanhPipeline = try createComputePipeline(functionName: "tanh_activation")
    }

    private func setupMPS() throws {
        // MPS matrix multiplication will be created per-call with actual dimensions
        // (Deferred until linear() knows the real matrix sizes)
    }

    private func createComputePipeline(functionName: String) throws -> MTLComputePipelineState {
        guard let device = device else {
            throw MetalError.notInitialized
        }
        guard let function = library?.makeFunction(name: functionName) else {
            throw MetalError.functionNotFound(functionName)
        }

        return try device.makeComputePipelineState(function: function)
    }

    // MARK: - Buffer Pool Management

    private func getBuffer(size: Int) -> MTLBuffer? {
        return bufferPoolQueue.sync {
            if var buffers = bufferPool[size], !buffers.isEmpty {
                let buffer = buffers.removeLast()
                bufferPool[size] = buffers
                return buffer
            }
            return nil
        }
    }

    private func returnBuffer(_ buffer: MTLBuffer) {
        bufferPoolQueue.async {
            let size = buffer.length
            var buffers = self.bufferPool[size] ?? []
            if buffers.count < self.bufferPoolMaxSize {
                buffers.append(buffer)
                self.bufferPool[size] = buffers
            }
            // If pool is full, buffer will be deallocated automatically
        }
    }

    private func createReusableBuffer(length: Int) -> MTLBuffer? {
        // Try to get from pool first
        if let pooledBuffer = getBuffer(size: length) {
            return pooledBuffer
        }

        // Create new buffer if none available in pool
        return device?.makeBuffer(length: length)
    }

    /// Creates a Metal buffer from array data
    private func createBuffer<T>(data: [T]) -> MTLBuffer {
        guard let device = device else {
            fatalError("Metal device not available")
        }
        let length = data.count * MemoryLayout<T>.size
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            fatalError("Failed to create Metal buffer")
        }
        memcpy(buffer.contents(), data, length)
        return buffer
    }

    deinit {
        // Clear buffer pool on deinit
        bufferPoolQueue.sync {
            self.bufferPool.removeAll()
        }
        logger.info("MetalNeuralProcessor deinitialized, buffer pool cleared")
    }

    // MARK: - GPU-Accelerated Operations

    /// Perform Fast Fourier Transform (FFT) using Metal GPU acceleration
    ///
    /// Computes the FFT of real-valued input signal using GPU-accelerated radix-2 algorithm.
    /// Supports both forward and inverse transforms with proper scaling.
    ///
    /// - Parameter input: Real-valued input signal
    /// - Parameter inverse: Whether to perform inverse FFT
    /// - Returns: Tuple of (real, imaginary) components of the frequency domain representation
    /// - Throws: MetalError if GPU operation fails
    ///
    /// - Performance: GPU-accelerated FFT computation
    /// - Memory: Uses buffer pooling for efficient memory management
    /// - Accuracy: Radix-2 FFT with bit-reversal permutation
    func fft(input: [Float], inverse: Bool = false) throws -> (real: [Float], imag: [Float]) {
        guard let device = device else {
            throw MetalError.notInitialized
        }

        let fftSize = input.count
        let log2fftSize = Int(log2(Float(fftSize)))

        guard fftSize > 0 && (1 << log2fftSize) == fftSize else {
            throw MetalError.commandBufferCreationFailed // FFT size must be power of 2
        }

        guard let fftPipeline = try? createComputePipeline(functionName: inverse ? "fft_inverse" : "fft_forward"),
              let commandQueue = commandQueue else {
            throw MetalError.notInitialized
        }

        // Create Metal buffers
        guard let inputBuffer = createReusableBuffer(length: input.count * MemoryLayout<Float>.size),
              let outputRealBuffer = createReusableBuffer(length: fftSize * MemoryLayout<Float>.size),
              let outputImagBuffer = createReusableBuffer(length: fftSize * MemoryLayout<Float>.size) else {
            throw MetalError.commandBufferCreationFailed
        }

        // Copy input data
        memcpy(inputBuffer.contents(), input, input.count * MemoryLayout<Float>.size)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            returnBuffer(inputBuffer)
            returnBuffer(outputRealBuffer)
            returnBuffer(outputImagBuffer)
            throw MetalError.commandBufferCreationFailed
        }

        // Configure compute pipeline
        encoder.setComputePipelineState(fftPipeline)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(outputRealBuffer, offset: 0, index: 1)
        encoder.setBuffer(outputImagBuffer, offset: 0, index: 2)

        // Set FFT constants
        var constants = FFTConstants(
            fftSize: Int32(fftSize),
            log2fftSize: Int32(log2fftSize),
            inverse: inverse
        )
        encoder.setBytes(&constants, length: MemoryLayout<FFTConstants>.size, index: 3)

        // Dispatch compute
        let threadsPerGroup = MTLSize(width: 256, height: 1, depth: 1)
        let numGroups = MTLSize(width: (fftSize + 255) / 256, height: 1, depth: 1)
        encoder.dispatchThreadgroups(numGroups, threadsPerThreadgroup: threadsPerGroup)

        encoder.endEncoding()

        // Wait for completion and extract results
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if commandBuffer.status == .completed {
            let realPtr = outputRealBuffer.contents().bindMemory(to: Float.self, capacity: fftSize)
            let imagPtr = outputImagBuffer.contents().bindMemory(to: Float.self, capacity: fftSize)

            let realResult = Array(UnsafeBufferPointer(start: realPtr, count: fftSize))
            let imagResult = Array(UnsafeBufferPointer(start: imagPtr, count: fftSize))

            // Return buffers to pool
            returnBuffer(inputBuffer)
            returnBuffer(outputRealBuffer)
            returnBuffer(outputImagBuffer)

            return (realResult, imagResult)
        } else {
            returnBuffer(inputBuffer)
            returnBuffer(outputRealBuffer)
            returnBuffer(outputImagBuffer)
            throw MetalError.commandBufferCreationFailed
        }
    }

    /// Perform Short-Time Fourier Transform (STFT) using Metal GPU acceleration
    ///
    /// Computes the STFT of an audio signal using overlapping windows and FFT.
    /// Supports both analysis (forward) and synthesis (inverse) operations.
    ///
    /// - Parameter input: Audio signal to transform
    /// - Parameter windowSize: Size of the analysis window
    /// - Parameter hopSize: Hop size between consecutive frames
    /// - Parameter inverse: Whether to perform inverse STFT (synthesis)
    /// - Returns: STFT matrix as tuple of (real, imaginary) components
    /// - Throws: MetalError if GPU operation fails
    ///
    /// - Performance: GPU-accelerated STFT computation with windowing
    /// - Memory: Efficient buffer management for large audio signals
    /// - Quality: Hann windowing with overlap-add reconstruction
    func stft(input: [Float], windowSize: Int, hopSize: Int, inverse: Bool = false) throws -> (real: [Float], imag: [Float]) {
        guard let device = device else {
            throw MetalError.notInitialized
        }

        let numFrames = (input.count - windowSize) / hopSize + 1
        let fftSize = windowSize // Assume window size equals FFT size

        guard let stftPipeline = try? createComputePipeline(functionName: inverse ? "stft_synthesis" : "stft_analysis"),
              let windowPipeline = try? createComputePipeline(functionName: "generate_hann_window"),
              let commandQueue = commandQueue else {
            throw MetalError.notInitialized
        }

        // Generate Hann window
        guard let windowBuffer = createReusableBuffer(length: windowSize * MemoryLayout<Float>.size) else {
            throw MetalError.commandBufferCreationFailed
        }

        // Create window generation command buffer
        guard let windowCommandBuffer = commandQueue.makeCommandBuffer(),
              let windowEncoder = windowCommandBuffer.makeComputeCommandEncoder() else {
            returnBuffer(windowBuffer)
            throw MetalError.commandBufferCreationFailed
        }

        windowEncoder.setComputePipelineState(windowPipeline)
        windowEncoder.setBuffer(windowBuffer, offset: 0, index: 0)
        var winSize = Int32(windowSize)
        windowEncoder.setBytes(&winSize, length: MemoryLayout<Int32>.size, index: 1)

        let windowThreadsPerGroup = MTLSize(width: 256, height: 1, depth: 1)
        let windowNumGroups = MTLSize(width: (windowSize + 255) / 256, height: 1, depth: 1)
        windowEncoder.dispatchThreadgroups(windowNumGroups, threadsPerThreadgroup: windowThreadsPerGroup)
        windowEncoder.endEncoding()
        windowCommandBuffer.commit()
        windowCommandBuffer.waitUntilCompleted()

        // Create STFT buffers
        guard let inputBuffer = createReusableBuffer(length: input.count * MemoryLayout<Float>.size),
              let stftRealBuffer = createReusableBuffer(length: numFrames * fftSize * MemoryLayout<Float>.size),
              let stftImagBuffer = createReusableBuffer(length: numFrames * fftSize * MemoryLayout<Float>.size) else {
            returnBuffer(windowBuffer)
            throw MetalError.commandBufferCreationFailed
        }

        // Copy input data
        memcpy(inputBuffer.contents(), input, input.count * MemoryLayout<Float>.size)

        // Create STFT command buffer
        guard let stftCommandBuffer = commandQueue.makeCommandBuffer(),
              let stftEncoder = stftCommandBuffer.makeComputeCommandEncoder() else {
            returnBuffer(windowBuffer)
            returnBuffer(inputBuffer)
            returnBuffer(stftRealBuffer)
            returnBuffer(stftImagBuffer)
            throw MetalError.commandBufferCreationFailed
        }

        stftEncoder.setComputePipelineState(stftPipeline)
        stftEncoder.setBuffer(inputBuffer, offset: 0, index: 0)
        stftEncoder.setBuffer(windowBuffer, offset: 0, index: 1)
        stftEncoder.setBuffer(stftRealBuffer, offset: 0, index: 2)
        stftEncoder.setBuffer(stftImagBuffer, offset: 0, index: 3)

        // Set STFT constants
        var constants = STFTConstants(
            fftSize: Int32(fftSize),
            hopSize: Int32(hopSize),
            windowSize: Int32(windowSize),
            numFrames: Int32(numFrames),
            inverse: inverse
        )
        stftEncoder.setBytes(&constants, length: MemoryLayout<STFTConstants>.size, index: 4)

        let stftThreadsPerGroup = MTLSize(width: 64, height: 1, depth: 1)
        let stftNumGroups = MTLSize(width: numFrames, height: 1, depth: 1)
        stftEncoder.dispatchThreadgroups(stftNumGroups, threadsPerThreadgroup: stftThreadsPerGroup)
        stftEncoder.endEncoding()
        stftCommandBuffer.commit()
        stftCommandBuffer.waitUntilCompleted()

        if stftCommandBuffer.status == .completed {
            let realPtr = stftRealBuffer.contents().bindMemory(to: Float.self, capacity: numFrames * fftSize)
            let imagPtr = stftImagBuffer.contents().bindMemory(to: Float.self, capacity: numFrames * fftSize)

            let realResult = Array(UnsafeBufferPointer(start: realPtr, count: numFrames * fftSize))
            let imagResult = Array(UnsafeBufferPointer(start: imagPtr, count: numFrames * fftSize))

            // Return buffers to pool
            returnBuffer(windowBuffer)
            returnBuffer(inputBuffer)
            returnBuffer(stftRealBuffer)
            returnBuffer(stftImagBuffer)

            return (realResult, imagResult)
        } else {
            returnBuffer(windowBuffer)
            returnBuffer(inputBuffer)
            returnBuffer(stftRealBuffer)
            returnBuffer(stftImagBuffer)
            throw MetalError.commandBufferCreationFailed
        }
    }

    /// Apply ERB (Equivalent Rectangular Bandwidth) filtering using Metal GPU acceleration
    ///
    /// Computes ERB filterbank analysis of audio spectrum using GPU-accelerated filtering.
    /// ERB filters provide perceptually motivated frequency analysis similar to human hearing.
    ///
    /// - Parameter spectrum: Frequency domain spectrum as (real, imaginary) tuple
    /// - Parameter numBands: Number of ERB bands to compute
    /// - Parameter sampleRate: Audio sample rate in Hz
    /// - Returns: ERB-filtered spectrum as tuple of (real, imaginary) components
    /// - Throws: MetalError if GPU operation fails
    ///
    /// - Performance: GPU-accelerated ERB filtering with parallel band processing
    /// - Accuracy: Perceptually motivated frequency analysis
    /// - Memory: Efficient filterbank generation and application
    func erbFilter(spectrum: (real: [Float], imag: [Float]), numBands: Int, sampleRate: Float) throws -> (real: [Float], imag: [Float]) {
        guard let device = device else {
            throw MetalError.notInitialized
        }

        let fftSize = spectrum.real.count

        guard let filterbankPipeline = try? createComputePipeline(functionName: "generate_erb_filterbank"),
              let applyPipeline = try? createComputePipeline(functionName: "apply_erb_filtering"),
              let commandQueue = commandQueue else {
            throw MetalError.notInitialized
        }

        // Create filterbank buffer
        guard let filterbankBuffer = createReusableBuffer(length: (fftSize / 2) * numBands * MemoryLayout<Float>.size) else {
            throw MetalError.commandBufferCreationFailed
        }

        // Generate ERB filterbank
        guard let filterbankCommandBuffer = commandQueue.makeCommandBuffer(),
              let filterbankEncoder = filterbankCommandBuffer.makeComputeCommandEncoder() else {
            returnBuffer(filterbankBuffer)
            throw MetalError.commandBufferCreationFailed
        }

        filterbankEncoder.setComputePipelineState(filterbankPipeline)
        filterbankEncoder.setBuffer(filterbankBuffer, offset: 0, index: 0)

        var erbConstants = ERBConstants(
            numBands: Int32(numBands),
            fftSize: Int32(fftSize),
            sampleRate: sampleRate,
            minFreq: 20.0,  // 20 Hz minimum
            maxFreq: sampleRate / 2.0  // Nyquist frequency
        )
        filterbankEncoder.setBytes(&erbConstants, length: MemoryLayout<ERBConstants>.size, index: 1)

        let filterbankThreadsPerGroup = MTLSize(width: 256, height: 1, depth: 1)
        let filterbankNumGroups = MTLSize(width: ((fftSize / 2) * numBands + 255) / 256, height: 1, depth: 1)
        filterbankEncoder.dispatchThreadgroups(filterbankNumGroups, threadsPerThreadgroup: filterbankThreadsPerGroup)
        filterbankEncoder.endEncoding()
        filterbankCommandBuffer.commit()
        filterbankCommandBuffer.waitUntilCompleted()

        // Apply ERB filtering
        guard let spectrumRealBuffer = createReusableBuffer(length: spectrum.real.count * MemoryLayout<Float>.size),
              let spectrumImagBuffer = createReusableBuffer(length: spectrum.imag.count * MemoryLayout<Float>.size),
              let filteredRealBuffer = createReusableBuffer(length: (fftSize / 2) * numBands * MemoryLayout<Float>.size),
              let filteredImagBuffer = createReusableBuffer(length: (fftSize / 2) * numBands * MemoryLayout<Float>.size) else {
            returnBuffer(filterbankBuffer)
            throw MetalError.commandBufferCreationFailed
        }

        // Copy spectrum data
        memcpy(spectrumRealBuffer.contents(), spectrum.real, spectrum.real.count * MemoryLayout<Float>.size)
        memcpy(spectrumImagBuffer.contents(), spectrum.imag, spectrum.imag.count * MemoryLayout<Float>.size)

        guard let applyCommandBuffer = commandQueue.makeCommandBuffer(),
              let applyEncoder = applyCommandBuffer.makeComputeCommandEncoder() else {
            returnBuffer(filterbankBuffer)
            returnBuffer(spectrumRealBuffer)
            returnBuffer(spectrumImagBuffer)
            returnBuffer(filteredRealBuffer)
            returnBuffer(filteredImagBuffer)
            throw MetalError.commandBufferCreationFailed
        }

        applyEncoder.setComputePipelineState(applyPipeline)
        applyEncoder.setBuffer(spectrumRealBuffer, offset: 0, index: 0)
        applyEncoder.setBuffer(spectrumImagBuffer, offset: 0, index: 1)
        applyEncoder.setBuffer(filterbankBuffer, offset: 0, index: 2)
        applyEncoder.setBuffer(filteredRealBuffer, offset: 0, index: 3)
        applyEncoder.setBuffer(filteredImagBuffer, offset: 0, index: 4)
        applyEncoder.setBytes(&erbConstants, length: MemoryLayout<ERBConstants>.size, index: 5)

        let applyThreadsPerGroup = MTLSize(width: 256, height: 1, depth: 1)
        let applyNumGroups = MTLSize(width: (fftSize / 2 + 255) / 256, height: 1, depth: 1)
        applyEncoder.dispatchThreadgroups(applyNumGroups, threadsPerThreadgroup: applyThreadsPerGroup)
        applyEncoder.endEncoding()
        applyCommandBuffer.commit()
        applyCommandBuffer.waitUntilCompleted()

        if applyCommandBuffer.status == .completed {
            let realPtr = filteredRealBuffer.contents().bindMemory(to: Float.self, capacity: (fftSize / 2) * numBands)
            let imagPtr = filteredImagBuffer.contents().bindMemory(to: Float.self, capacity: (fftSize / 2) * numBands)

            let realResult = Array(UnsafeBufferPointer(start: realPtr, count: (fftSize / 2) * numBands))
            let imagResult = Array(UnsafeBufferPointer(start: imagPtr, count: (fftSize / 2) * numBands))

            // Return buffers to pool
            returnBuffer(filterbankBuffer)
            returnBuffer(spectrumRealBuffer)
            returnBuffer(spectrumImagBuffer)
            returnBuffer(filteredRealBuffer)
            returnBuffer(filteredImagBuffer)

            return (realResult, imagResult)
        } else {
            returnBuffer(filterbankBuffer)
            returnBuffer(spectrumRealBuffer)
            returnBuffer(spectrumImagBuffer)
            returnBuffer(filteredRealBuffer)
            returnBuffer(filteredImagBuffer)
            throw MetalError.commandBufferCreationFailed
        }
    }

    /// Perform 1D convolution using Metal GPU acceleration
    ///
    /// This function executes a 1D convolution operation on the GPU using Metal compute shaders,
    /// providing significant performance improvements over CPU-based implementations.
    /// The operation includes bias addition and uses asynchronous execution with completion handlers.
    ///
    /// - Parameter input: Input tensor as flattened Float32 array
    /// - Parameter weights: Convolution weights as flattened Float32 array
    /// - Parameter bias: Bias terms for each output channel
    /// - Parameter inputChannels: Number of input channels
    /// - Parameter outputChannels: Number of output channels
    /// - Parameter kernelSize: Size of the convolution kernel
    /// - Parameter stride: Stride for the convolution operation
    /// - Parameter completion: Completion handler called with convolution result or error
    ///
    /// - Performance: GPU-accelerated, significantly faster than CPU for large tensors
    /// - Memory: Uses buffer pooling for efficient memory management
    /// - Threading: Asynchronous execution, results delivered via completion handler
    ///
    /// - Note: Input tensor should be flattened with shape [inputChannels, inputLength]
    ///         Weights should be flattened with shape [outputChannels, inputChannels, kernelSize]
    func conv1D(input: [Float],
                weights: [Float],
                bias: [Float],
                inputChannels: Int,
                outputChannels: Int,
                kernelSize: Int,
                stride: Int,
                completion: @escaping (Result<[Float], MetalError>) -> Void) {
        guard let pipeline = conv1DPipeline,
              let commandQueue = commandQueue else {
            completion(.failure(.notInitialized))
            return
        }

        let inputLength = input.count / inputChannels
        let outputLength = (inputLength - kernelSize) / stride + 1
        let outputSize = outputLength * outputChannels

        // Create Metal buffers using pool
        guard let inputBuffer = createReusableBuffer(length: input.count * MemoryLayout<Float>.size),
              let weightsBuffer = createReusableBuffer(length: weights.count * MemoryLayout<Float>.size),
              let biasBuffer = createReusableBuffer(length: bias.count * MemoryLayout<Float>.size),
              let outputBuffer = createReusableBuffer(length: outputSize * MemoryLayout<Float>.size) else {
            completion(.failure(.commandBufferCreationFailed))
            return
        }

        // Copy data to buffers
        memcpy(inputBuffer.contents(), input, input.count * MemoryLayout<Float>.size)
        memcpy(weightsBuffer.contents(), weights, weights.count * MemoryLayout<Float>.size)
        memcpy(biasBuffer.contents(), bias, bias.count * MemoryLayout<Float>.size)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            returnBuffer(inputBuffer)
            returnBuffer(weightsBuffer)
            returnBuffer(biasBuffer)
            returnBuffer(outputBuffer)
            completion(.failure(.commandBufferCreationFailed))
            return
        }

        // Configure compute pipeline
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(weightsBuffer, offset: 0, index: 1)
        encoder.setBuffer(biasBuffer, offset: 0, index: 2)
        encoder.setBuffer(outputBuffer, offset: 0, index: 3)

        // Set constants
        var constants = Conv1DConstants(
            inputChannels: Int32(inputChannels),
            outputChannels: Int32(outputChannels),
            kernelSize: Int32(kernelSize),
            stride: Int32(stride),
            inputLength: Int32(inputLength),
            outputLength: Int32(outputLength)
        )
        encoder.setBytes(&constants, length: MemoryLayout<Conv1DConstants>.size, index: 4)

        // Dispatch compute
        let threadsPerGroup = MTLSize(width: 256, height: 1, depth: 1)
        let numGroups = MTLSize(width: (outputSize + 255) / 256, height: 1, depth: 1)
        encoder.dispatchThreadgroups(numGroups, threadsPerThreadgroup: threadsPerGroup)

        encoder.endEncoding()

        // Add completion handler
        commandBuffer.addCompletedHandler { [weak self] commandBuffer in
            guard let self = self else { return }

            if commandBuffer.status == .completed {
                // Extract results
                let outputPtr = outputBuffer.contents().bindMemory(to: Float.self, capacity: outputSize)
                let result = Array(UnsafeBufferPointer(start: outputPtr, count: outputSize))

                // Return buffers to pool for reuse
                self.returnBuffer(inputBuffer)
                self.returnBuffer(weightsBuffer)
                self.returnBuffer(biasBuffer)
                self.returnBuffer(outputBuffer)

                completion(.success(result))
            } else {
                // Return buffers even on failure
                self.returnBuffer(inputBuffer)
                self.returnBuffer(weightsBuffer)
                self.returnBuffer(biasBuffer)
                self.returnBuffer(outputBuffer)

                let error = MetalError.commandBufferCreationFailed
                completion(.failure(error))
            }
        }

        commandBuffer.commit()
    }

    /// Perform linear transformation (fully connected layer) using Metal GPU acceleration
    ///
    /// This function executes a linear transformation (matrix multiplication + bias addition)
    /// using Metal Performance Shaders (MPS) for optimized GPU acceleration.
    /// The operation performs: output = input × weights + bias
    ///
    /// - Parameter input: Input tensor as Float32 array
    /// - Parameter weights: Weight matrix as 2D array [outputSize, inputSize]
    /// - Parameter bias: Bias vector for each output neuron
    /// - Parameter completion: Completion handler called with transformation result or error
    ///
    /// - Performance: GPU-accelerated using MPS, highly optimized for matrix operations
    /// - Memory: Uses buffer pooling and MPS matrices for efficient memory management
    /// - Threading: Asynchronous execution, results delivered via completion handler
    ///
    /// - Note: Includes bias addition as part of the linear operation for completeness.
    ///         MPS provides highly optimized matrix multiplication kernels.
    func linear(input: [Float], weights: [[Float]], bias: [Float], completion: @escaping (Result<[Float], MetalError>) -> Void) {
        guard let device = device else {
            completion(.failure(.notInitialized))
            return
        }

        let inputSize = input.count
        let outputSize = bias.count

        let mps = MPSMatrixMultiplication(
            device: device,
            transposeLeft: false,
            transposeRight: false,
            resultRows: outputSize,
            resultColumns: 1,
            interiorColumns: inputSize,
            alpha: 1.0,
            beta: 0.0
        )

        // Create MPS matrices using buffer pool
        guard let inputBuffer = createReusableBuffer(length: inputSize * MemoryLayout<Float>.size),
              let weightsBuffer = createReusableBuffer(length: weights.flatMap { $0 }.count * MemoryLayout<Float>.size),
              let resultBuffer = createReusableBuffer(length: outputSize * MemoryLayout<Float>.size) else {
            completion(.failure(.commandBufferCreationFailed))
            return
        }

        // Copy data to buffers
        memcpy(inputBuffer.contents(), input, inputSize * MemoryLayout<Float>.size)
        let weightsFlat = weights.flatMap { $0 }
        memcpy(weightsBuffer.contents(), weightsFlat, weightsFlat.count * MemoryLayout<Float>.size)

        let inputMatrix = MPSMatrix(
            buffer: inputBuffer,
            descriptor: MPSMatrixDescriptor(
                rows: inputSize,
                columns: 1,
                rowBytes: MemoryLayout<Float>.size,
                dataType: .float32
            )
        )

        let weightsMatrix = MPSMatrix(
            buffer: weightsBuffer,
            descriptor: MPSMatrixDescriptor(rows: outputSize, columns: inputSize, rowBytes: inputSize * MemoryLayout<Float>.size, dataType: .float32)
        )

        let resultMatrix = MPSMatrix(
            buffer: resultBuffer,
            descriptor: MPSMatrixDescriptor(
                rows: outputSize,
                columns: 1,
                rowBytes: MemoryLayout<Float>.size,
                dataType: .float32
            )
        )

        // Perform matrix multiplication
        guard let commandBuffer = commandQueue?.makeCommandBuffer() else {
            returnBuffer(inputBuffer)
            returnBuffer(weightsBuffer)
            returnBuffer(resultBuffer)
            completion(.failure(.commandBufferCreationFailed))
            return
        }

        mps.encode(commandBuffer: commandBuffer, leftMatrix: weightsMatrix, rightMatrix: inputMatrix, resultMatrix: resultMatrix)

        // Add completion handler
        commandBuffer.addCompletedHandler { [weak self] commandBuffer in
            guard let self = self else { return }

            if commandBuffer.status == .completed {
                // Add bias to the result after MPS operation completes
                let resultPtr = resultMatrix.data.contents().bindMemory(to: Float.self, capacity: outputSize)
                for i in 0..<outputSize {
                    resultPtr[i] += bias[i]
                }

                // Extract results
                let result = Array(UnsafeBufferPointer(start: resultPtr, count: outputSize))

                // Return buffers to pool for reuse
                self.returnBuffer(inputBuffer)
                self.returnBuffer(weightsBuffer)
                self.returnBuffer(resultBuffer)

                completion(.success(result))
            } else {
                // Return buffers even on failure
                self.returnBuffer(inputBuffer)
                self.returnBuffer(weightsBuffer)
                self.returnBuffer(resultBuffer)

                let error = MetalError.commandBufferCreationFailed
                completion(.failure(error))
            }
        }

        commandBuffer.commit()
    }

    /// Apply ReLU activation function using GPU acceleration
    ///
    /// Computes the Rectified Linear Unit activation: max(0, x) for each element.
    /// Uses Metal compute shaders for efficient parallel processing on GPU.
    ///
    /// - Parameter input: Input tensor as Float32 array
    /// - Returns: Output tensor with ReLU applied element-wise
    /// - Throws: MetalError if GPU operation fails
    ///
    /// - Performance: GPU-accelerated parallel processing
    /// - Memory: Minimal additional memory usage with buffer pooling
    func relu(input: [Float]) throws -> [Float] {
        guard let pipeline = reluPipeline else {
            throw MetalError.notInitialized
        }
        return try applyActivation(input: input, pipeline: pipeline)
    }

    /// Apply sigmoid activation function using GPU acceleration
    ///
    /// Computes the sigmoid activation: 1 / (1 + exp(-x)) for each element.
    /// Uses Metal compute shaders for efficient parallel processing on GPU.
    ///
    /// - Parameter input: Input tensor as Float32 array
    /// - Returns: Output tensor with sigmoid applied element-wise
    /// - Throws: MetalError if GPU operation fails
    ///
    /// - Performance: GPU-accelerated parallel processing
    /// - Memory: Minimal additional memory usage with buffer pooling
    func sigmoid(input: [Float]) throws -> [Float] {
        guard let pipeline = sigmoidPipeline else {
            throw MetalError.notInitialized
        }
        return try applyActivation(input: input, pipeline: pipeline)
    }

    /// Apply tanh activation function using GPU acceleration
    ///
    /// Computes the hyperbolic tangent activation: tanh(x) for each element.
    /// Uses Metal compute shaders for efficient parallel processing on GPU.
    ///
    /// - Parameter input: Input tensor as Float32 array
    /// - Returns: Output tensor with tanh applied element-wise
    /// - Throws: MetalError if GPU operation fails
    ///
    /// - Performance: GPU-accelerated parallel processing
    /// - Memory: Minimal additional memory usage with buffer pooling
    func tanh(input: [Float]) throws -> [Float] {
        guard let pipeline = tanhPipeline else {
            throw MetalError.notInitialized
        }
        return try applyActivation(input: input, pipeline: pipeline)
    }

    private func applyActivation(input: [Float], pipeline: MTLComputePipelineState) throws -> [Float] {
        guard let commandQueue = commandQueue else {
            throw MetalError.notInitialized
        }

        guard let inputBuffer = createReusableBuffer(length: input.count * MemoryLayout<Float>.size),
              let outputBuffer = createReusableBuffer(length: input.count * MemoryLayout<Float>.size) else {
            throw MetalError.commandBufferCreationFailed
        }

        // Copy data to input buffer
        memcpy(inputBuffer.contents(), input, input.count * MemoryLayout<Float>.size)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            returnBuffer(inputBuffer)
            returnBuffer(outputBuffer)
            throw MetalError.commandBufferCreationFailed
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 1)

        let threadsPerGroup = MTLSize(width: 256, height: 1, depth: 1)
        let numGroups = MTLSize(width: (input.count + 255) / 256, height: 1, depth: 1)
        encoder.dispatchThreadgroups(numGroups, threadsPerThreadgroup: threadsPerGroup)

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        guard commandBuffer.status == .completed else {
            returnBuffer(inputBuffer)
            returnBuffer(outputBuffer)
            throw MetalError.commandBufferCreationFailed
        }

        let outputPtr = outputBuffer.contents().bindMemory(to: Float.self, capacity: input.count)
        let result = Array(UnsafeBufferPointer(start: outputPtr, count: input.count))

        // Return buffers to pool for reuse
        returnBuffer(inputBuffer)
        returnBuffer(outputBuffer)

        return result
    }
}

// MARK: - Supporting Types

struct Conv1DConstants {
    var inputChannels: Int32
    var outputChannels: Int32
    var kernelSize: Int32
    var stride: Int32
    var inputLength: Int32
    var outputLength: Int32
}

struct FFTConstants {
    var fftSize: Int32
    var log2fftSize: Int32
    var inverse: Bool
}

struct STFTConstants {
    var fftSize: Int32
    var hopSize: Int32
    var windowSize: Int32
    var numFrames: Int32
    var inverse: Bool
}

struct ERBConstants {
    var numBands: Int32
    var fftSize: Int32
    var sampleRate: Float
    var minFreq: Float
    var maxFreq: Float
}

enum MetalError: Error, LocalizedError {
    case notInitialized
    case libraryCreationFailed
    case pipelineCreationFailed
    case bufferCreationFailed
    case commandBufferFailed
    case functionNotFound(String)
    case bufferAllocationFailed
    case kernelExecutionFailed(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Metal GPU acceleration not initialized"
        case .libraryCreationFailed:
            return "Failed to create Metal library"
        case .pipelineCreationFailed:
            return "Failed to create compute pipeline"
        case .bufferCreationFailed:
            return "Failed to create Metal buffer"
        case .commandBufferFailed:
            return "Failed to create command buffer"
        case .functionNotFound(let name):
            return "Metal function '\(name)' not found in library"
        case .bufferAllocationFailed:
            return "Failed to allocate Metal buffer"
        case .kernelExecutionFailed(let reason):
            return "Kernel execution failed: \(reason)"
        case .executionFailed(let reason):
            return "Execution failed: \(reason)"
        case .commandBufferCreationFailed:
            return "Failed to create Metal command buffer"
        case .mpsNotAvailable:
            return "Metal Performance Shaders not available"
        }
    }

    // MARK: - Advanced GPU Operations

    /// Performs batch convolution for processing multiple audio streams simultaneously
    /// - Parameters:
    ///   - input: Input tensor [batch, channels, length]
    ///   - weights: Weight tensor [out_channels, in_channels, kernel]
    ///   - bias: Bias tensor [out_channels]
    ///   - batchSize: Number of audio streams to process
    ///   - inputChannels: Number of input channels per stream
    ///   - outputChannels: Number of output channels per stream
    ///   - inputLength: Length of input sequence
    ///   - kernelSize: Convolution kernel size
    ///   - stride: Convolution stride
    /// - Returns: Output tensor [batch, out_channels, out_length]
    func batchConv1D(input: [Float], weights: [Float], bias: [Float],
                    batchSize: Int, inputChannels: Int, outputChannels: Int,
                    inputLength: Int, kernelSize: Int, stride: Int) async throws -> [Float] {
        guard let device = self.device, let commandQueue = self.commandQueue else {
            throw MetalError.notInitialized
        }

        let outputLength = (inputLength - kernelSize) / stride + 1
        let outputSize = batchSize * outputChannels * outputLength

        let constants = BatchConv1DConstants(
            batchSize: Int32(batchSize),
            inputChannels: Int32(inputChannels),
            outputChannels: Int32(outputChannels),
            kernelSize: Int32(kernelSize),
            stride: Int32(stride),
            inputLength: Int32(inputLength),
            outputLength: Int32(outputLength)
        )

        return try await executeComputeKernel(
            kernelName: "batch_conv1d_forward",
            inputBuffers: [
                createBuffer(data: input),
                createBuffer(data: weights),
                createBuffer(data: bias)
            ],
            outputSize: outputSize,
            constants: constants,
            threadGroups: MTLSize(width: batchSize, height: outputChannels, depth: outputLength)
        )
    }

    /// Performs multi-head attention computation
    /// - Parameters:
    ///   - query: Query tensor [batch, seq, model_dim]
    ///   - key: Key tensor [batch, seq, model_dim]
    ///   - value: Value tensor [batch, seq, model_dim]
    ///   - weightsQ: Query weights [model_dim, model_dim]
    ///   - weightsK: Key weights [model_dim, model_dim]
    ///   - weightsV: Value weights [model_dim, model_dim]
    ///   - weightsO: Output weights [model_dim, model_dim]
    ///   - batchSize: Batch size
    ///   - seqLength: Sequence length
    ///   - numHeads: Number of attention heads
    ///   - modelDim: Model dimension
    /// - Returns: Attention output [batch, seq, model_dim]
    func multiHeadAttention(query: [Float], key: [Float], value: [Float],
                           weightsQ: [Float], weightsK: [Float], weightsV: [Float], weightsO: [Float],
                           batchSize: Int, seqLength: Int, numHeads: Int, modelDim: Int) async throws -> [Float] {
        guard let device = self.device, let commandQueue = self.commandQueue else {
            throw MetalError.notInitialized
        }

        let headDim = modelDim / numHeads
        let outputSize = batchSize * seqLength * modelDim

        let constants = AttentionConstants(
            batchSize: Int32(batchSize),
            seqLength: Int32(seqLength),
            numHeads: Int32(numHeads),
            headDim: Int32(headDim),
            modelDim: Int32(modelDim)
        )

        return try await executeComputeKernel(
            kernelName: "multihead_attention",
            inputBuffers: [
                createBuffer(data: query),
                createBuffer(data: key),
                createBuffer(data: value),
                createBuffer(data: weightsQ),
                createBuffer(data: weightsK),
                createBuffer(data: weightsV),
                createBuffer(data: weightsO)
            ],
            outputSize: outputSize,
            constants: constants,
            threadGroups: MTLSize(width: batchSize, height: seqLength, depth: numHeads)
        )
    }

    /// Performs fused convolution + activation for better performance
    /// - Parameters:
    ///   - input: Input tensor [channels, length]
    ///   - weights: Weight tensor [out_channels, in_channels, kernel]
    ///   - bias: Bias tensor [out_channels]
    ///   - kernelSize: Convolution kernel size
    ///   - stride: Convolution stride
    ///   - activationType: 0=ReLU, 1=GELU, 2=Swish
    /// - Returns: Output tensor [out_channels, out_length]
    func fusedConv1DActivation(input: [Float], weights: [Float], bias: [Float],
                              inputChannels: Int, outputChannels: Int, inputLength: Int,
                              kernelSize: Int, stride: Int, activationType: Int) async throws -> [Float] {
        guard let device = self.device, let commandQueue = self.commandQueue else {
            throw MetalError.notInitialized
        }

        let outputLength = (inputLength - kernelSize) / stride + 1
        let outputSize = outputChannels * outputLength

        let constants = FusedConvActivationConstants(
            inputChannels: Int32(inputChannels),
            outputChannels: Int32(outputChannels),
            kernelSize: Int32(kernelSize),
            stride: Int32(stride),
            inputLength: Int32(inputLength),
            outputLength: Int32(outputLength),
            activationType: Int32(activationType)
        )

        return try await executeComputeKernel(
            kernelName: "fused_conv1d_activation",
            inputBuffers: [
                createBuffer(data: input),
                createBuffer(data: weights),
                createBuffer(data: bias)
            ],
            outputSize: outputSize,
            constants: constants
        )
    }

    /// Performs 8-bit quantized convolution for memory efficiency
    /// - Parameters:
    ///   - input: Quantized input tensor
    ///   - weights: Quantized weight tensor
    ///   - bias: Float bias tensor
    ///   - scale: Dequantization scale factor
    ///   - zeroPoint: Quantization zero point
    /// - Returns: Dequantized output tensor
    func quantizedConv1D(input: [Int8], weights: [Int8], bias: [Float],
                        inputChannels: Int, outputChannels: Int, inputLength: Int,
                        kernelSize: Int, stride: Int, scale: Float, zeroPoint: Int) async throws -> [Float] {
        guard let device = self.device, let commandQueue = self.commandQueue else {
            throw MetalError.notInitialized
        }

        let outputLength = (inputLength - kernelSize) / stride + 1
        let outputSize = outputChannels * outputLength

        let constants = QuantizedConvConstants(
            inputChannels: Int32(inputChannels),
            outputChannels: Int32(outputChannels),
            kernelSize: Int32(kernelSize),
            stride: Int32(stride),
            inputLength: Int32(inputLength),
            outputLength: Int32(outputLength),
            scale: scale,
            zeroPoint: Int32(zeroPoint)
        )

        return try await executeComputeKernel(
            kernelName: "quantized_conv1d_forward",
            inputBuffers: [
                createBuffer(data: input),
                createBuffer(data: weights),
                createBuffer(data: bias)
            ],
            outputSize: outputSize,
            constants: constants
        )
    }

    /// Performs advanced STFT with multi-channel support
    /// - Parameters:
    ///   - input: Multi-channel audio input [channels, samples]
    ///   - window: Window function
    ///   - fftSize: FFT size
    ///   - hopSize: Hop size between frames
    ///   - numChannels: Number of audio channels
    ///   - numFrames: Number of STFT frames
    ///   - useHannWindow: Whether to use Hann windowing
    /// - Returns: STFT result (real, imaginary) [channels, frames, fft_size/2]
    func advancedSTFT(input: [Float], window: [Float], fftSize: Int, hopSize: Int,
                     numChannels: Int, numFrames: Int, useHannWindow: Bool,
                     scaleFactor: Float = 1.0) async throws -> (real: [Float], imag: [Float]) {
        guard let device = self.device, let commandQueue = self.commandQueue else {
            throw MetalError.notInitialized
        }

        let windowSize = window.count
        let outputSize = numChannels * numFrames * (fftSize / 2)

        let constants = AdvancedSTFTConstants(
            fftSize: Int32(fftSize),
            hopSize: Int32(hopSize),
            windowSize: Int32(windowSize),
            numFrames: Int32(numFrames),
            numChannels: Int32(numChannels),
            useHannWindow: useHannWindow,
            scaleFactor: scaleFactor
        )

        let realOutput = try await executeComputeKernel(
            kernelName: "advanced_stft_analysis",
            inputBuffers: [
                createBuffer(data: input),
                createBuffer(data: window)
            ],
            outputSize: outputSize,
            constants: constants,
            threadGroups: MTLSize(width: numChannels, height: numFrames, depth: fftSize / 2)
        )

        let imagOutput = try await executeComputeKernel(
            kernelName: "advanced_stft_analysis",
            inputBuffers: [
                createBuffer(data: input),
                createBuffer(data: window)
            ],
            outputSize: outputSize,
            constants: constants,
            threadGroups: MTLSize(width: numChannels, height: numFrames, depth: fftSize / 2),
            outputIndex: 1  // Get imaginary output
        )

        return (real: realOutput, imag: imagOutput)
    }

    /// Performs transformer feed-forward network computation
    /// - Parameters:
    ///   - input: Input tensor [batch, seq, model_dim]
    ///   - weights1: First layer weights [model_dim, ff_dim]
    ///   - weights2: Second layer weights [ff_dim, model_dim]
    ///   - bias1: First layer bias [ff_dim]
    ///   - bias2: Second layer bias [model_dim]
    ///   - batchSize: Batch size
    ///   - seqLength: Sequence length
    ///   - modelDim: Model dimension
    ///   - ffDim: Feed-forward dimension
    /// - Returns: Transformer output [batch, seq, model_dim]
    func transformerFeedForward(input: [Float], weights1: [Float], weights2: [Float],
                               bias1: [Float], bias2: [Float],
                               batchSize: Int, seqLength: Int, modelDim: Int, ffDim: Int) async throws -> [Float] {
        guard let device = self.device, let commandQueue = self.commandQueue else {
            throw MetalError.notInitialized
        }

        let outputSize = batchSize * seqLength * modelDim

        let constants = TransformerConstants(
            batchSize: Int32(batchSize),
            seqLength: Int32(seqLength),
            modelDim: Int32(modelDim),
            numHeads: 0,  // Not used in feed-forward
            ffDim: Int32(ffDim)
        )

        return try await executeComputeKernel(
            kernelName: "transformer_feedforward",
            inputBuffers: [
                createBuffer(data: input),
                createBuffer(data: weights1),
                createBuffer(data: weights2),
                createBuffer(data: bias1),
                createBuffer(data: bias2)
            ],
            outputSize: outputSize,
            constants: constants,
            threadGroups: MTLSize(width: batchSize, height: seqLength, depth: modelDim)
        )
    }

    // MARK: - Helper Methods for Advanced Operations

    /// Executes a compute kernel with advanced parameters
    private func executeComputeKernel(kernelName: String, inputBuffers: [MTLBuffer],
                                    outputSize: Int, constants: Any,
                                    threadGroups: MTLSize? = nil,
                                    outputIndex: Int = 0) async throws -> [Float] {
        guard let device = self.device, let commandQueue = self.commandQueue,
              let library = self.library else {
            throw MetalError.notInitialized
        }

        guard let kernelFunction = library.makeFunction(name: kernelName),
              let pipeline = try? device.makeComputePipelineState(function: kernelFunction) else {
            throw MetalError.pipelineCreationFailed
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalError.commandBufferCreationFailed
        }

        // Set compute pipeline
        encoder.setComputePipelineState(pipeline)

        // Set input buffers
        for (index, buffer) in inputBuffers.enumerated() {
            encoder.setBuffer(buffer, offset: 0, index: index)
        }

        // Create output buffer
        guard let outputBuffer = device.makeBuffer(length: outputSize * MemoryLayout<Float>.size,
                                                  options: .storageModeShared) else {
            encoder.endEncoding()
            throw MetalError.bufferCreationFailed
        }

        encoder.setBuffer(outputBuffer, offset: 0, index: inputBuffers.count + outputIndex)

        // Set constants buffer
        let constantsBuffer = createConstantsBuffer(constants)
        encoder.setBuffer(constantsBuffer, offset: 0, index: inputBuffers.count + 1)

        // Calculate thread groups
        let threadsPerGroup = MTLSize(width: min(256, outputSize), height: 1, depth: 1)
        let groups: MTLSize
        if let customGroups = threadGroups {
            groups = customGroups
        } else {
            let groupWidth = (outputSize + threadsPerGroup.width - 1) / threadsPerGroup.width
            groups = MTLSize(width: groupWidth, height: 1, depth: 1)
        }

        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw MetalError.kernelExecutionFailed(error.localizedDescription)
        }

        // Return output data
        let outputPtr = outputBuffer.contents().bindMemory(to: Float.self, capacity: outputSize)
        return Array(UnsafeBufferPointer(start: outputPtr, count: outputSize))
    }

    /// Creates a constants buffer from various constant structures
    private func createConstantsBuffer(_ constants: Any) -> MTLBuffer {
        switch constants {
        case let batchConv as BatchConv1DConstants:
            return createBuffer(data: [batchConv])
        case let attention as AttentionConstants:
            return createBuffer(data: [attention])
        case let fused as FusedConvActivationConstants:
            return createBuffer(data: [fused])
        case let quantized as QuantizedConvConstants:
            return createBuffer(data: [quantized])
        case let stft as AdvancedSTFTConstants:
            return createBuffer(data: [stft])
        case let transformer as TransformerConstants:
            return createBuffer(data: [transformer])
        default:
            fatalError("Unsupported constants type")
        }
    }
}

// MARK: - GPU-Accelerated Neural Layers

class MetalConv1DLayer: NeuralLayer {
    private let metalProcessor: MetalNeuralProcessor?
    private let weights: [Float]
    private let bias: [Float]
    private let inputChannels: Int
    private let outputChannels: Int
    private let kernelSize: Int
    private let stride: Int

    init(inputChannels: Int, outputChannels: Int, kernelSize: Int, stride: Int, weightInit: WeightInit = .kaimingUniform) {
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.kernelSize = kernelSize
        self.stride = stride

        // Initialize weights and bias
        let weightCount = inputChannels * outputChannels * kernelSize
        self.weights = weightInit.initialize(fanIn: inputChannels, fanOut: outputChannels, count: weightCount)
        self.bias = WeightInit.constant(0.0).initialize(fanIn: 1, fanOut: outputChannels, count: outputChannels)

        // Try to initialize Metal processor
        self.metalProcessor = MetalNeuralProcessor()
    }

    func forward(_ input: [Float], hiddenStates: inout [String: [Float]]) throws -> [Float] {
        if let metal = metalProcessor {
            // Use GPU acceleration with semaphore to maintain synchronous interface
            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<[Float], MetalError>?

            metal.conv1D(
                input: input,
                weights: weights,
                bias: bias,
                inputChannels: inputChannels,
                outputChannels: outputChannels,
                kernelSize: kernelSize,
                stride: stride
            ) { gpuResult in
                result = gpuResult
                semaphore.signal()
            }

            // Wait for GPU completion (with timeout)
            if semaphore.wait(timeout: .now() + 5.0) == .timedOut {
                throw MetalError.commandBufferCreationFailed
            }

            switch result {
            case .success(let output):
                return output
            case .failure(let error):
                throw error
            case .none:
                throw MetalError.commandBufferCreationFailed
            }
        } else {
            // Fallback to CPU implementation using stored trained parameters
            let inputLength = input.count / inputChannels
            let outputLength = ((inputLength - kernelSize) / stride) + 1
            guard inputLength >= kernelSize, outputLength > 0 else {
                throw MetalError.commandBufferCreationFailed
            }

            var output = [Float](repeating: 0.0, count: outputChannels * outputLength)
            for outC in 0..<outputChannels {
                for t in 0..<outputLength {
                    var acc = bias[outC]
                    for inC in 0..<inputChannels {
                        let baseInput = inC * inputLength
                        let baseWeight = outC * inputChannels * kernelSize + inC * kernelSize
                        for k in 0..<kernelSize {
                            let inputIndex = baseInput + t * stride + k
                            acc += input[inputIndex] * weights[baseWeight + k]
                        }
                    }
                     output[outC * outputLength + t] = max(0.0, acc)  // ReLU
                 }
             }
             return output
         }
     }
}

class MetalLinearLayer: NeuralLayer {
    private let metalProcessor: MetalNeuralProcessor?
    private let weights: [[Float]]
    private let bias: [Float]

    init(inputSize: Int, outputSize: Int, weightInit: WeightInit = .kaimingUniform) {
        // Validate input parameters
        guard inputSize > 0, outputSize > 0 else {
            fatalError("MetalLinearLayer: inputSize and outputSize must be positive")
        }
        
        // Initialize weights as 2D array for MPS compatibility
        self.weights = (0..<outputSize).map { _ in
            weightInit.initialize(fanIn: inputSize, fanOut: outputSize, count: inputSize)
        }
        
        // Validate weights structure
        guard weights.count == outputSize,
              weights.allSatisfy({ $0.count == inputSize }) else {
            fatalError("MetalLinearLayer: Weights initialization failed - invalid dimensions")
        }
        
        self.bias = WeightInit.constant(0.0).initialize(fanIn: 1, fanOut: outputSize, count: outputSize)

        // Try to initialize Metal processor
        self.metalProcessor = MetalNeuralProcessor()
    }

    func forward(_ input: [Float], hiddenStates: inout [String: [Float]]) throws -> [Float] {
        if let metal = metalProcessor {
            // Use GPU acceleration with semaphore to maintain synchronous interface
            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<[Float], MetalError>?

            metal.linear(input: input, weights: weights, bias: bias) { gpuResult in
                result = gpuResult
                semaphore.signal()
            }

            // Wait for GPU completion (with timeout)
            if semaphore.wait(timeout: .now() + 5.0) == .timedOut {
                throw MetalError.commandBufferCreationFailed
            }

            switch result {
            case .success(let output):
                return output
            case .failure(let error):
                throw error
            case .none:
                throw MetalError.commandBufferCreationFailed
            }
        } else {
            // Fallback to CPU implementation using stored trained parameters
            var output = [Float](repeating: 0.0, count: bias.count)
            for out in 0..<bias.count {
                var sum = bias[out]
                let row = weights[out]
                for inp in 0..<min(input.count, row.count) {
                    sum += input[inp] * row[inp]
                }
                output[out] = sum
            }
            return output
        }
    }
}