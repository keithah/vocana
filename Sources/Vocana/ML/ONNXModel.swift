import Foundation
import Accelerate

/// ONNX Model wrapper for DeepFilterNet inference
/// 
/// This class provides a Swift interface to ONNX Runtime for running
/// the three DeepFilterNet3 models: encoder, ERB decoder, and DF decoder.
///
/// Supports both mock and native ONNX Runtime implementations.
class ONNXModel {
    enum ONNXError: Error {
        case modelNotFound(String)
        case sessionCreationFailed(String)
        case inferenceError(String)
        case invalidInputShape
        case invalidOutputShape
    }
    
    private let modelPath: String
    private let modelName: String
    private let session: InferenceSession
    
    // Model shapes (from DeepFilterNet3 config)
    private let encoderInputShapes = [
        "erb_feat": [1, 1, -1, 32],     // [B, C, T, F]
        "spec_feat": [1, 2, -1, 96]      // [B, C, T, F]
    ]
    private let encoderOutputShapes = [
        "e0": [1, 1, -1, 96],
        "e1": [1, 32, -1, 48],
        "e2": [1, 64, -1, 24],
        "e3": [1, 128, -1, 12],
        "emb": [1, 256, -1, 6],
        "c0": [1, -1, 256],
        "lsnr": [1, -1, 1]
    ]
    
    /// Initialize ONNX model from file path
    /// - Parameters:
    ///   - modelPath: Path to .onnx model file
    ///   - useNative: If true, try to use native ONNX Runtime (falls back to mock if unavailable)
    init(modelPath: String, useNative: Bool = false) throws {
        self.modelPath = modelPath
        self.modelName = URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
        
        // Verify model exists
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw ONNXError.modelNotFound(modelPath)
        }
        
        // Create ONNX Runtime session
        let runtime = ONNXRuntimeWrapper(mode: useNative ? .automatic : .mock)
        let options = SessionOptions(
            intraOpNumThreads: 4,
            graphOptimizationLevel: .all
        )
        
        do {
            self.session = try runtime.createSession(modelPath: modelPath, options: options)
            print("✓ Loaded ONNX model: \(modelName)")
        } catch {
            throw ONNXError.sessionCreationFailed(error.localizedDescription)
        }
    }
    
    /// Run inference with input tensors
    /// - Parameter inputs: Dictionary of input name to tensor data
    /// - Returns: Dictionary of output name to tensor data
    func infer(inputs: [String: Tensor]) throws -> [String: Tensor] {
        // Convert Tensor to TensorData
        var tensorInputs: [String: TensorData] = [:]
        for (name, tensor) in inputs {
            let shape = tensor.shape.map { Int64($0) }
            tensorInputs[name] = TensorData(shape: shape, data: tensor.data)
        }
        
        // Run inference
        let tensorOutputs = try session.run(inputs: tensorInputs)
        
        // Convert TensorData back to Tensor
        var outputs: [String: Tensor] = [:]
        for (name, tensorData) in tensorOutputs {
            let shape = tensorData.shape.map { Int($0) }
            outputs[name] = Tensor(shape: shape, data: tensorData.data)
        }
        
        return outputs
    }
}

// MARK: - Tensor Structure

/// Simple tensor structure for ONNX data
struct Tensor {
    let shape: [Int]
    var data: [Float]
    
    init(shape: [Int], data: [Float]) {
        self.shape = shape
        self.data = data
        
        // Validate data size matches shape
        let expectedSize = shape.reduce(1, *)
        assert(data.count == expectedSize, "Data size \(data.count) doesn't match shape \(shape) (expected \(expectedSize))")
    }
    
    /// Create tensor filled with a constant value
    init(shape: [Int], constant: Float) {
        let size = shape.reduce(1, *)
        self.shape = shape
        self.data = Array(repeating: constant, count: size)
    }
    
    /// Total number of elements
    var count: Int {
        shape.reduce(1, *)
    }
    
    /// Reshape tensor (must preserve element count)
    func reshaped(_ newShape: [Int]) -> Tensor {
        let newSize = newShape.reduce(1, *)
        assert(newSize == count, "Cannot reshape: size mismatch")
        return Tensor(shape: newShape, data: data)
    }
}

// MARK: - Usage Notes

/*
 The ONNXModel class now uses ONNXRuntimeWrapper which supports both:
 - Mock inference (for development/testing without ONNX Runtime)
 - Native inference (when ONNX Runtime library is available)
 
 To enable native ONNX Runtime:
 1. See ONNXRuntimeWrapper.swift for installation instructions
 2. Create model with useNative = true
 3. Runtime will automatically detect and use available library
 
 Example:
 ```swift
 // Use mock (default)
 let model = try ONNXModel(modelPath: "enc.onnx")
 
 // Try native, fall back to mock if unavailable
 let model = try ONNXModel(modelPath: "enc.onnx", useNative: true)
 ```
 */
