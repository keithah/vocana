import Foundation
import Accelerate
import os.log

/// ONNX Model wrapper for DeepFilterNet inference
/// 
/// This class provides a Swift interface to ONNX Runtime for running
/// the three DeepFilterNet3 models: encoder, ERB decoder, and DF decoder.
///
/// Supports both mock and native ONNX Runtime implementations.
final class ONNXModel {
    enum ONNXError: Error {
        case modelNotFound(String)
        case sessionCreationFailed(String)
        case inferenceError(String)
        case invalidInputShape(String)
        case invalidOutputShape(String)
        case shapeOverflow(String)
        case emptyInputs
        case emptyOutputs
    }
    
    private let modelPath: String
    private let modelName: String
    private let session: InferenceSession
    
    // Logging
    private static let logger = Logger(subsystem: "com.vocana.ml", category: "ONNXModel")
    
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
            intraOpNumThreads: ProcessInfo.processInfo.activeProcessorCount,
            graphOptimizationLevel: .all
        )
        
        do {
            self.session = try runtime.createSession(modelPath: modelPath, options: options)
            Self.logger.info("✓ Loaded ONNX model: \(self.modelName)")
        } catch {
            throw ONNXError.sessionCreationFailed(error.localizedDescription)
        }
    }
    
    // Fix MEDIUM: Mark deinit as nonisolated for consistency
    nonisolated deinit {
        // Session cleanup is handled by InferenceSession protocol implementations automatically
        Self.logger.debug("ONNXModel \(self.modelName) deinitialized")
    }
    
    /// Run inference with input tensors
    /// - Parameter inputs: Dictionary of input name to tensor data
    /// - Returns: Dictionary of output name to tensor data
    /// - Throws: ONNXError if inference fails
    func infer(inputs: [String: Tensor]) throws -> [String: Tensor] {
        // Fix MEDIUM: Validate inputs not empty
        guard !inputs.isEmpty else {
            throw ONNXError.emptyInputs
        }
        
        // Convert Tensor to TensorData with safe type conversion
        var tensorInputs: [String: TensorData] = [:]
        for (name, tensor) in inputs {
            // Fix CRITICAL: Safe Int to Int64 conversion with proper error handling
            let shape = try tensor.shape.map { value in
                guard let int64Value = Int64(exactly: value) else {
                    throw ONNXError.invalidInputShape("Shape dimension \(value) cannot be converted to Int64")
                }
                return int64Value
            }
            // Use throwing initializer for validation
            tensorInputs[name] = try TensorData(shape: shape, data: tensor.data)
        }
        
        // Run inference
        let tensorOutputs = try session.run(inputs: tensorInputs)
        
        // Fix MEDIUM: Validate outputs not empty
        guard !tensorOutputs.isEmpty else {
            throw ONNXError.emptyOutputs
        }
        
        // Convert TensorData back to Tensor with safe type conversion
        var outputs: [String: Tensor] = [:]
        for (name, tensorData) in tensorOutputs {
            // Safe Int64 to Int conversion with bounds checking
            let shape = try tensorData.shape.map { value in
                guard let intValue = Int(exactly: value) else {
                    throw ONNXError.invalidOutputShape("Shape dimension \(value) exceeds Int range")
                }
                return intValue
            }
            
            // Fix CRITICAL: Validate element count before Tensor construction to avoid precondition failure
            var expectedCount = 1
            for dim in shape {
                let (product, overflow) = expectedCount.multipliedReportingOverflow(by: dim)
                guard !overflow else {
                    throw ONNXError.invalidOutputShape("Output '\(name)' shape \(shape) causes overflow")
                }
                expectedCount = product
            }
            
            guard tensorData.data.count == expectedCount else {
                throw ONNXError.invalidOutputShape(
                    "Output '\(name)' expected \(expectedCount) elements for shape \(shape), got \(tensorData.data.count)"
                )
            }
            
            outputs[name] = Tensor(shape: shape, data: tensorData.data)
        }
        
        return outputs
    }
}

// MARK: - Tensor Structure

/// Simple tensor structure for ONNX data
struct Tensor {
    let shape: [Int]
    var data: [Float]  // Fix MEDIUM: Consider making immutable (let) for thread safety
    
    init(shape: [Int], data: [Float]) {
        self.shape = shape
        self.data = data
        
        // Fix HIGH: Safe overflow checking in shape calculation
        let expectedSize = shape.reduce(1) { result, dim in
            let (product, overflow) = result.multipliedReportingOverflow(by: dim)
            precondition(!overflow, "Shape dimensions overflow Int: \(shape)")
            return product
        }
        
        // Fix LOW: Better error message
        precondition(data.count == expectedSize, 
                    "Data size \(data.count) doesn't match shape \(shape) (expected \(expectedSize))")
    }
    
    /// Create tensor filled with a constant value
    init(shape: [Int], constant: Float) {
        // Fix HIGH: Safe overflow checking
        let size = shape.reduce(1) { result, dim in
            let (product, overflow) = result.multipliedReportingOverflow(by: dim)
            precondition(!overflow, "Shape dimensions overflow Int: \(shape)")
            return product
        }
        
        self.shape = shape
        self.data = Array(repeating: constant, count: size)
    }
    
    /// Total number of elements
    var count: Int {
        // Fix HIGH: Safe overflow checking
        shape.reduce(1) { result, dim in
            let (product, overflow) = result.multipliedReportingOverflow(by: dim)
            precondition(!overflow, "Tensor size overflow: \(shape)")
            return product
        }
    }
    
    /// Reshape tensor (must preserve element count)
    func reshaped(_ newShape: [Int]) -> Tensor {
        // Fix HIGH: Safe overflow checking
        let newSize = newShape.reduce(1) { result, dim in
            let (product, overflow) = result.multipliedReportingOverflow(by: dim)
            precondition(!overflow, "New shape dimensions overflow Int: \(newShape)")
            return product
        }
        
        precondition(newSize == count, 
                    "Cannot reshape: size mismatch (current: \(count), new: \(newSize))")
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
 
 Thread Safety:
 - ONNXModel instances should not be shared across threads
 - Create separate instances per thread if needed
 - Tensor struct is value type (copy-on-write safe)
 */
