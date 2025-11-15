//
//  MetalNeuralLayers.swift
//  Vocana
//
//  GPU-accelerated neural network layers using Metal compute shaders
//

import Metal
import MetalPerformanceShaders
import os.log

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
        guard let mtlDevice = device else {
            throw MetalError.notInitialized
        }
        guard let function = library?.makeFunction(name: functionName) else {
            throw MetalError.functionNotFound(functionName)
        }

        return try mtlDevice.makeComputePipelineState(function: function)
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

            // Enforce pool size limit - if full, don't add the buffer
            if buffers.count >= self.bufferPoolMaxSize {
                // Buffer will be deallocated automatically when it goes out of scope
                self.logger.debug("Buffer pool full for size \(size), discarding returned buffer")
                return
            }

            buffers.append(buffer)
            self.bufferPool[size] = buffers
            self.logger.debug("Returned buffer to pool: size \(size), pool count \(buffers.count)")
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
        guard device != nil else {
            throw MetalError.notInitialized
        }

        let fftSize = input.count
        let log2fftSize = Int(log2(Float(fftSize)))

        guard fftSize > 0 && (1 << log2fftSize) == fftSize else {
            throw MetalError.invalidInput // FFT size must be power of 2
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

        // Ensure buffers are returned even on early exit
        defer {
            returnBuffer(inputBuffer)
            returnBuffer(outputRealBuffer)
            returnBuffer(outputImagBuffer)
        }

        // Copy input data safely
        input.withUnsafeBytes { inputPtr in
            guard let inputBase = inputPtr.baseAddress else { return }
            memcpy(inputBuffer.contents(), inputBase, input.count * MemoryLayout<Float>.size)
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
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

            return (realResult, imagResult)
        } else {
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
        guard device != nil else {
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
        guard device != nil else {
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
        guard let mtlDevice = device else {
            completion(.failure(.notInitialized))
            return
        }

        let inputSize = input.count
        let outputSize = bias.count

        let mps = MPSMatrixMultiplication(
            device: mtlDevice,
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
    case functionNotFound(String)
    case commandBufferCreationFailed
    case mpsNotAvailable
    case invalidInput

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Metal GPU acceleration not initialized"
        case .libraryCreationFailed:
            return "Failed to create Metal library"
        case .functionNotFound(let name):
            return "Metal function '\(name)' not found"
        case .commandBufferCreationFailed:
            return "Failed to create Metal command buffer"
        case .mpsNotAvailable:
            return "Metal Performance Shaders not available"
        case .invalidInput:
            return "Invalid input parameters"
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
        // Initialize weights as 2D array for MPS compatibility
        self.weights = (0..<outputSize).map { _ in
            weightInit.initialize(fanIn: inputSize, fanOut: outputSize, count: inputSize)
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