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
        // Initialize MPS matrix multiplication for efficient linear operations
        mpsMatrixMultiplication = MPSMatrixMultiplication(
            device: device!,
            transposeLeft: false,
            transposeRight: false,
            resultRows: 1,
            resultColumns: 1,
            interiorColumns: 1,
            alpha: 1.0,
            beta: 0.0
        )
    }

    private func createComputePipeline(functionName: String) throws -> MTLComputePipelineState {
        guard let function = library?.makeFunction(name: functionName) else {
            throw MetalError.functionNotFound(functionName)
        }

        return try device!.makeComputePipelineState(function: function)
    }

    // MARK: - GPU-Accelerated Operations

    func conv1D(input: [Float],
                weights: [Float],
                bias: [Float],
                inputChannels: Int,
                outputChannels: Int,
                kernelSize: Int,
                stride: Int) throws -> [Float] {

        guard let pipeline = conv1DPipeline,
              let commandQueue = commandQueue,
              let device = device else {
            throw MetalError.notInitialized
        }

        let inputLength = input.count / inputChannels
        let outputLength = (inputLength - kernelSize) / stride + 1
        let outputSize = outputLength * outputChannels

        // Create Metal buffers
        guard let inputBuffer = device.makeBuffer(bytes: input, length: input.count * MemoryLayout<Float>.size),
              let weightsBuffer = device.makeBuffer(bytes: weights, length: weights.count * MemoryLayout<Float>.size),
              let biasBuffer = device.makeBuffer(bytes: bias, length: bias.count * MemoryLayout<Float>.size),
              let outputBuffer = device.makeBuffer(length: outputSize * MemoryLayout<Float>.size) else {
            throw MetalError.commandBufferCreationFailed
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalError.commandBufferCreationFailed
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
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Extract results
        let outputPtr = outputBuffer.contents().bindMemory(to: Float.self, capacity: outputSize)
        return Array(UnsafeBufferPointer(start: outputPtr, count: outputSize))
    }

    func linear(input: [Float], weights: [[Float]], bias: [Float]) throws -> [Float] {
        // Use MPS for optimized matrix multiplication
        guard let mps = mpsMatrixMultiplication else {
            throw MetalError.mpsNotAvailable
        }

        let inputSize = input.count
        let outputSize = bias.count

        // Create MPS matrices
        let inputMatrix = MPSMatrix(
            buffer: device!.makeBuffer(bytes: input, length: inputSize * MemoryLayout<Float>.size)!,
            descriptor: MPSMatrixDescriptor(rows: 1, columns: inputSize, rowBytes: inputSize * MemoryLayout<Float>.size, dataType: .float32)
        )

        // Flatten weights for MPS
        let weightsFlat = weights.flatMap { $0 }
        let weightsMatrix = MPSMatrix(
            buffer: device!.makeBuffer(bytes: weightsFlat, length: weightsFlat.count * MemoryLayout<Float>.size)!,
            descriptor: MPSMatrixDescriptor(rows: outputSize, columns: inputSize, rowBytes: inputSize * MemoryLayout<Float>.size, dataType: .float32)
        )

        let resultMatrix = MPSMatrix(
            buffer: device!.makeBuffer(length: outputSize * MemoryLayout<Float>.size)!,
            descriptor: MPSMatrixDescriptor(rows: 1, columns: outputSize, rowBytes: outputSize * MemoryLayout<Float>.size, dataType: .float32)
        )

        // Perform matrix multiplication
        guard let commandBuffer = commandQueue?.makeCommandBuffer() else {
            throw MetalError.commandBufferCreationFailed
        }

        mps.encode(commandBuffer: commandBuffer, leftMatrix: weightsMatrix, rightMatrix: inputMatrix, resultMatrix: resultMatrix)

        // TODO: Add bias addition
        // For now, bias is not added - this is a simplified implementation

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Extract results
        let resultPtr = resultMatrix.data.contents().bindMemory(to: Float.self, capacity: outputSize)
        return Array(UnsafeBufferPointer(start: resultPtr, count: outputSize))
    }

    func relu(input: [Float]) throws -> [Float] {
        return try applyActivation(input: input, pipeline: reluPipeline!)
    }

    func sigmoid(input: [Float]) throws -> [Float] {
        return try applyActivation(input: input, pipeline: sigmoidPipeline!)
    }

    func tanh(input: [Float]) throws -> [Float] {
        return try applyActivation(input: input, pipeline: tanhPipeline!)
    }

    private func applyActivation(input: [Float], pipeline: MTLComputePipelineState) throws -> [Float] {
        guard let commandQueue = commandQueue,
              let device = device else {
            throw MetalError.notInitialized
        }

        guard let inputBuffer = device.makeBuffer(bytes: input, length: input.count * MemoryLayout<Float>.size),
              let outputBuffer = device.makeBuffer(length: input.count * MemoryLayout<Float>.size) else {
            throw MetalError.commandBufferCreationFailed
        }

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
        return Array(UnsafeBufferPointer(start: outputPtr, count: input.count))
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

enum MetalError: Error, LocalizedError {
    case notInitialized
    case libraryCreationFailed
    case functionNotFound(String)
    case commandBufferCreationFailed
    case mpsNotAvailable

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
            // Use GPU acceleration
            return try metal.conv1D(
                input: input,
                weights: weights,
                bias: bias,
                inputChannels: inputChannels,
                outputChannels: outputChannels,
                kernelSize: kernelSize,
                stride: stride
            )
        } else {
            // Fallback to CPU implementation
            return try Conv1DLayer(
                inputChannels: inputChannels,
                outputChannels: outputChannels,
                kernelSize: kernelSize,
                stride: stride
            ).forward(input, hiddenStates: &hiddenStates)
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
            // Use GPU acceleration
            return try metal.linear(input: input, weights: weights, bias: bias)
        } else {
            // Fallback to CPU implementation
            return try LinearLayer(inputSize: input.count, outputSize: bias.count).forward(input, hiddenStates: &hiddenStates)
        }
    }
}