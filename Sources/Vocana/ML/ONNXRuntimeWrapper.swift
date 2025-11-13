import Foundation

import OSLog

/// Swift wrapper for ONNX Runtime C API
///
/// This provides a Swift-friendly interface to ONNX Runtime while maintaining
/// compatibility with the mock implementation during development.
///
/// Usage:
/// ```swift
/// let runtime = try ONNXRuntimeWrapper()
/// let session = try runtime.createSession(modelPath: "model.onnx")
/// let outputs = try session.run(inputs: ["input": tensorData])
/// ```
class ONNXRuntimeWrapper {
    nonisolated private static let logger = Logger(subsystem: "Vocana", category: "ONNXRuntime")

    // MARK: - Configuration
    
    enum RuntimeMode {
        case mock           // Use mock implementation (no ONNX Runtime required)
        case native         // Use real ONNX Runtime C API
        case automatic      // Try native, fall back to mock
    }
    
    private let mode: RuntimeMode
    private var isNativeAvailable: Bool = false
    
    // MARK: - Initialization
    
    init(mode: RuntimeMode = .automatic) {
        self.mode = mode
        
        // Check if ONNX Runtime library is available
        self.isNativeAvailable = checkONNXRuntimeAvailability()
        
        if mode == .automatic {
            if isNativeAvailable {
                Self.logger.info("ONNX Runtime native library detected")
            } else {
                Self.logger.warning("ONNX Runtime not found - using mock implementation")
                Self.logger.info("To install ONNX Runtime: Download from https://github.com/microsoft/onnxruntime/releases")
            }
        }
    }
    
    /// Check if ONNX Runtime native library is available
    private func checkONNXRuntimeAvailability() -> Bool {
        // Try to find libonnxruntime.dylib
        let searchPaths = [
            "Frameworks/onnxruntime/lib/libonnxruntime.dylib",
            "/usr/local/lib/libonnxruntime.dylib",
            "/opt/homebrew/lib/libonnxruntime.dylib"
        ]
        
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
        }
        
        return false
    }
    
    // MARK: - Session Creation
    
    func createSession(modelPath: String, options: SessionOptions = SessionOptions()) throws -> InferenceSession {
        let useNative = (mode == .native) || (mode == .automatic && isNativeAvailable)
        
        if useNative {
            return try NativeInferenceSession(modelPath: modelPath, options: options)
        } else {
            return try MockInferenceSession(modelPath: modelPath, options: options)
        }
    }
}

// MARK: - Session Options

struct SessionOptions {
    var intraOpNumThreads: Int = 4
    var graphOptimizationLevel: GraphOptimizationLevel = .all
    var enableCPUMemArena: Bool = true
    var enableMemPattern: Bool = true
    
    enum GraphOptimizationLevel: Int {
        case none = 0
        case basic = 1
        case extended = 2
        case all = 3
    }
}

// MARK: - Inference Session Protocol

protocol InferenceSession {
    var inputNames: [String] { get }
    var outputNames: [String] { get }
    
    func run(inputs: [String: TensorData]) throws -> [String: TensorData]
}

// MARK: - Tensor Data

struct TensorData {
    let shape: [Int64]
    let data: [Float]
    
    /// Create tensor data with validation
    /// - Parameters:
    ///   - shape: Tensor shape dimensions
    ///   - data: Flattened tensor data
    /// - Throws: ONNXError if validation fails
    init(shape: [Int64], data: [Float]) throws {
        self.shape = shape
        self.data = data
        
        // Validate with overflow checking
        var expectedSize = Int64(1)
        for dim in shape {
            let (product, overflow) = expectedSize.multipliedReportingOverflow(by: dim)
            if overflow {
                throw ONNXError.runtimeError("Shape dimensions overflow Int64")
            }
            expectedSize = product
        }
        
        // Safe conversion for comparison
        guard let expectedInt = Int(exactly: expectedSize) else {
            throw ONNXError.runtimeError("Expected size exceeds Int range")
        }
        
        guard data.count == expectedInt else {
            throw ONNXError.runtimeError("Data size doesn't match expected shape")
        }
    }
    
    /// Convenience initializer that uses precondition for cases where validation is guaranteed
    /// Use this only when you're certain the shape and data are valid
    init(unsafeShape shape: [Int64], data: [Float]) {
        self.shape = shape
        self.data = data
    }
    
    var count: Int {
        get throws {
            // Fix CRITICAL: Check overflow during reduce, not after
            var product = Int64(1)
            for dim in shape {
                let (result, overflow) = product.multipliedReportingOverflow(by: dim)
                guard !overflow else {
                    throw ONNXError.runtimeError("Tensor size overflow during multiplication")
                }
                product = result
            }
            
            guard let intValue = Int(exactly: product) else {
                throw ONNXError.runtimeError("Tensor size exceeds Int range")
            }
            return intValue
        }
    }
}

// MARK: - Mock Implementation

class MockInferenceSession: InferenceSession {
    private let modelPath: String
    private let modelName: String
    private let options: SessionOptions
    
    /// Safe conversion from Int64 to Int with overflow checking
    private func safeIntCount(_ values: [Int64]) throws -> Int {
        // Fix CRITICAL: Safe overflow checking during multiplication
        var product = Int64(1)
        for dim in values {
            let (result, overflow) = product.multipliedReportingOverflow(by: dim)
            guard !overflow else {
                throw ONNXError.runtimeError("Shape dimensions overflow during multiplication")
            }
            product = result
        }
        
        guard let count = Int(exactly: product) else {
            throw ONNXError.runtimeError("Tensor size exceeds Int.max")
        }
        return count
    }
    
    var inputNames: [String] {
        switch modelName {
        case "enc": return ["erb_feat", "spec_feat"]
        case "erb_dec": return ["e0", "e1", "e2", "e3", "emb", "c0", "lsnr"]
        case "df_dec": return ["e0", "e1", "e2", "e3", "emb", "c0", "lsnr"]
        default: return []
        }
    }
    
    var outputNames: [String] {
        switch modelName {
        case "enc": return ["e0", "e1", "e2", "e3", "emb", "c0", "lsnr"]
        case "erb_dec": return ["m"]
        case "df_dec": return ["coefs"]
        default: return []
        }
    }
    
    init(modelPath: String, options: SessionOptions) throws {
        self.modelPath = modelPath
        self.options = options
        self.modelName = URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
        
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw ONNXError.modelNotFound(modelPath)
        }
    }
    
    func run(inputs: [String: TensorData]) throws -> [String: TensorData] {
        // Mock inference - return dummy data with correct shapes
        switch modelName {
        case "enc":
            return try runEncoder(inputs: inputs)
        case "erb_dec":
            return try runERBDecoder(inputs: inputs)
        case "df_dec":
            return try runDFDecoder(inputs: inputs)
        default:
            throw ONNXError.unknownModel(modelName)
        }
    }
    
    private func runEncoder(inputs: [String: TensorData]) throws -> [String: TensorData] {
        guard let erbFeat = inputs["erb_feat"] else {
            throw ONNXError.invalidInput("Missing erb_feat")
        }
        
        // Validate shape array bounds
        guard erbFeat.shape.count >= 3 else {
            throw ONNXError.invalidInput("erb_feat shape too small: \(erbFeat.shape.count)")
        }
        
        let T = erbFeat.shape[2]  // Time dimension
        
        // Use safe count calculation to prevent integer overflow
        return [
            "e0": TensorData(unsafeShape: [1, 1, T, 96], data: Array(repeating: AppConstants.defaultTensorValue, count: try safeIntCount([1, 1, T, 96]))),
            "e1": TensorData(unsafeShape: [1, 32, T, 48], data: Array(repeating: AppConstants.defaultTensorValue, count: try safeIntCount([1, 32, T, 48]))),
            "e2": TensorData(unsafeShape: [1, 64, T, 24], data: Array(repeating: AppConstants.defaultTensorValue, count: try safeIntCount([1, 64, T, 24]))),
            "emb": TensorData(unsafeShape: [1, 256, T, 6], data: Array(repeating: AppConstants.defaultTensorValue, count: try safeIntCount([1, 256, T, 6]))),
            "c0": TensorData(unsafeShape: [1, T, 256], data: Array(repeating: AppConstants.defaultTensorValue, count: try safeIntCount([1, T, 256]))),
            "lsnr": TensorData(unsafeShape: [1, T, 1], data: Array(repeating: AppConstants.defaultLSNRValue, count: try safeIntCount([1, T, 1])))
        ]
    }
    
    private func runERBDecoder(inputs: [String: TensorData]) throws -> [String: TensorData] {
        guard let e3 = inputs["e3"] else {
            throw ONNXError.invalidInput("Missing e3")
        }
        
        // Validate shape array bounds
        guard e3.shape.count >= 3 else {
            throw ONNXError.invalidInput("e3 shape too small: \(e3.shape.count)")
        }
        
        let T = e3.shape[2]
        let F: Int64 = 481  // Full spectrum
        
        return [
            "m": TensorData(unsafeShape: [1, 1, T, F], data: Array(repeating: 0.8, count: try safeIntCount([1, 1, T, F])))
        ]
    }
    
    private func runDFDecoder(inputs: [String: TensorData]) throws -> [String: TensorData] {
        guard let e3 = inputs["e3"] else {
            throw ONNXError.invalidInput("Missing e3")
        }
        
        // Validate shape array bounds
        guard e3.shape.count >= 3 else {
            throw ONNXError.invalidInput("e3 shape too small: \(e3.shape.count)")
        }
        
        let T = e3.shape[2]
        let dfBins: Int64 = Int64(AppConstants.dfBands)
        let dfOrder: Int64 = Int64(AppConstants.dfOrder)
        
        return [
            "coefs": TensorData(unsafeShape: [T, dfBins, dfOrder], data: Array(repeating: 0.01, count: try safeIntCount([T, dfBins, dfOrder])))
        ]
    }
}

// MARK: - Native Implementation

class NativeInferenceSession: InferenceSession {
    private let modelPath: String
    private let options: SessionOptions
    
    // TODO: Add OpaquePointer for OrtSession when C bridge is linked
    
    var inputNames: [String] = []
    var outputNames: [String] = []
    
    init(modelPath: String, options: SessionOptions) throws {
        self.modelPath = modelPath
        self.options = options
        
        // TODO: Initialize ONNX Runtime session via C bridge
        // Example:
        // let env = ONNXCreateEnv(...)
        // let sessionOptions = ONNXCreateSessionOptions(...)
        // let session = ONNXCreateSession(env, modelPath, sessionOptions)
        // self.inputNames = queryInputNames(session)
        // self.outputNames = queryOutputNames(session)
        
        throw ONNXError.notImplemented("Native ONNX Runtime not yet implemented")
    }
    
    func run(inputs: [String: TensorData]) throws -> [String: TensorData] {
        // TODO: Run actual ONNX inference
        // Example:
        // Convert TensorData to OrtValue
        // Call ONNXSessionRun
        // Convert OrtValue back to TensorData
        
        throw ONNXError.notImplemented("Native ONNX Runtime not yet implemented")
    }
}

// MARK: - Error Types

enum ONNXError: Error {
    case modelNotFound(String)
    case invalidInput(String)
    case unknownModel(String)
    case runtimeError(String)
    case notImplemented(String)
}

// MARK: - Integration Guide

// Integrating Real ONNX Runtime
//
// Step 1: Download ONNX Runtime
//   cd /path/to/Vocana
//   curl -L https://github.com/microsoft/onnxruntime/releases/download/v1.23.2/onnxruntime-osx-universal2-1.23.2.tgz -o onnxruntime.tgz
//   tar -xzf onnxruntime.tgz
//   mkdir -p Frameworks/onnxruntime
//   mv onnxruntime-osx-universal2-1.23.2/* Frameworks/onnxruntime/
//
// Step 2: Update Package.swift
//   .executableTarget(
//       name: "Vocana",
//       dependencies: [],
//       linkerSettings: [
//           .unsafeFlags(["-L", "Frameworks/onnxruntime/lib"]),
//           .linkedLibrary("onnxruntime")
//       ]
//   )
//
// Step 3: Implement NativeInferenceSession
//   - Use ONNXRuntimeBridge.h C functions
//   - Create OrtEnv, OrtSession
//   - Convert TensorData ↔ OrtValue
//   - Handle errors properly
//
// Step 4: Test
//   let runtime = try ONNXRuntimeWrapper(mode: .native)
//   let session = try runtime.createSession(modelPath: "enc.onnx")
//   let outputs = try session.run(inputs: inputs)
//
// Performance Tips:
//   - Use .enableCPUMemArena = true for faster allocation
//   - Set .graphOptimizationLevel = .all for maximum optimization
//   - Consider CoreML ExecutionProvider on macOS for GPU acceleration
//   - Reuse sessions instead of creating new ones per inference
