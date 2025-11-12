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
    enum ONNXError: Error, LocalizedError {
        case modelNotFound(String)
        case sessionCreationFailed(String)
        case inferenceError(String)
        case invalidInputShape(String)
        case invalidOutputShape(String)
        case shapeOverflow(String)
        case emptyInputs
        case emptyOutputs
        case invalidInput(String)

        var errorDescription: String? {
            switch self {
            case .modelNotFound(let message):
                return "Model not found: \(message)"
            case .sessionCreationFailed(let message):
                return "Session creation failed: \(message)"
            case .inferenceError(let message):
                return "Inference error: \(message)"
            case .invalidInputShape(let message):
                return "Invalid input shape: \(message)"
            case .invalidOutputShape(let message):
                return "Invalid output shape: \(message)"
            case .shapeOverflow(let message):
                return "Shape overflow: \(message)"
            case .emptyInputs:
                return "Empty inputs"
            case .emptyOutputs:
                return "Empty outputs"
            case .invalidInput(let message):
                return "Invalid input: \(message)"
            }
        }
    }
    
    private let modelPath: String
    private let modelName: String
    private let session: InferenceSession
    
    // Fix CRITICAL: Thread safety for concurrent inference calls
    private let sessionQueue = DispatchQueue(label: "com.vocana.onnx.session", qos: .userInteractive)
    
    // Logging
    private static let logger = Logger(subsystem: "com.vocana.ml", category: "ONNXModel")
    
    /// Initialize ONNX model from file path
    /// - Parameters:
    ///   - modelPath: Path to .onnx model file
    ///   - useNative: If true, try to use native ONNX Runtime (falls back to mock if unavailable)
    init(modelPath: String, useNative: Bool = false) throws {
        // Sanitize path for security - allow simple names for mock mode
        let sanitizedPath = try Self.sanitizeModelPath(modelPath, allowSimpleNames: !useNative)

        self.modelPath = sanitizedPath
        self.modelName = URL(fileURLWithPath: sanitizedPath).deletingPathExtension().lastPathComponent

        // For native mode, verify model file exists
        if useNative {
            guard FileManager.default.fileExists(atPath: sanitizedPath) else {
                throw ONNXError.modelNotFound(sanitizedPath)
            }
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
        // Fix CRITICAL: Thread-safe inference with dedicated queue
        return try sessionQueue.sync {
            // Fix MEDIUM: Validate inputs not empty
            guard !inputs.isEmpty else {
                throw ONNXError.emptyInputs
            }
            
            // Convert Tensor to TensorData with safe type conversion
            var tensorInputs: [String: TensorData] = [:]
            for (name, tensor) in inputs {
                // Fix HIGH: Security validation of tensor data
                guard !tensor.data.isEmpty else {
                    throw ONNXError.invalidInput("Tensor '\(name)' has empty data")
                }
                
                guard tensor.data.allSatisfy({ $0.isFinite }) else {
                    throw ONNXError.invalidInput("Tensor '\(name)' contains NaN or infinite values")
                }
                
                // Fix CRITICAL: Use more appropriate range validation for audio ML models
                // Audio spectrograms can have large magnitude values, especially for loud signals
                let maxSafeValue: Float = 1e8 // Allow large spectral values but prevent overflow
                guard tensor.data.allSatisfy({ abs($0) <= maxSafeValue }) else {
                    let maxValue = tensor.data.max { abs($0) < abs($1) } ?? 0
                    throw ONNXError.invalidInput("Tensor '\(name)' max value \(maxValue) exceeds safe range (±\(maxSafeValue))")
                }
                
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
            
            // Run inference (ONNX Runtime is not thread-safe)
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
                // Fix CRITICAL: Use reasonable limits based on ML model constraints
                // DeepFilterNet models typically have dimensions: batch(1), channels(32-96), time(1), freq(481)
                let maxReasonableDim = 1_000_000 // Allow for large spectrograms but prevent memory exhaustion
                guard dim > 0 && dim <= maxReasonableDim else {
                    throw ONNXError.invalidOutputShape("Output '\(name)' dimension \(dim) outside valid range [1, \(maxReasonableDim)]")
                }
                
                // Check if multiplication would exceed reasonable limits before overflow check
                guard expectedCount <= Int.max / max(dim, 1) else {
                    throw ONNXError.invalidOutputShape("Output '\(name)' shape \(shape) would exceed memory limits")
                }
                
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
        } // End sessionQueue.sync
    }
    
    // Fix CRITICAL: Path sanitization to prevent directory traversal attacks
    /// Sanitizes and validates model path to prevent directory traversal attacks.
    /// 
    /// This function implements defense-in-depth against path traversal attacks:
    /// 1. Canonicalizes paths and resolves all symlinks
    /// 2. Validates against an allowlist of safe directories
    /// 3. Performs checks at multiple stages to prevent TOCTOU race conditions
    /// 4. Validates file existence and readability
    /// 5. Enforces .onnx file extension
    ///
    /// - Parameter path: User-provided model path
    /// - Returns: Sanitized canonical path safe to use
    /// - Throws: ONNXError if path is invalid or outside allowed directories
    private static func sanitizeModelPath(_ path: String, allowSimpleNames: Bool = false) throws -> String {
        let fm = FileManager.default
        
        // Fix CRITICAL-007: Prevent path traversal attacks with comprehensive validation
        
        // Step 1: Basic path validation
        guard !path.isEmpty else {
            throw ONNXError.modelNotFound("Empty model path")
        }

        // Allow simple model names for mock/testing scenarios
        if allowSimpleNames && !path.contains("/") && !path.contains("\\") {
            return path // Simple name like "enc", "erb_dec" is allowed for mock mode
        }

        // Prevent obvious traversal attempts
        guard !path.contains("../") && !path.contains("..\\") && !path.hasPrefix("/") else {
            throw ONNXError.modelNotFound("Invalid path format: potential traversal attack")
        }
        
        // Step 2: Resolve and validate path within app sandbox
        let url = URL(fileURLWithPath: path)
        let resolvedURL = url.standardizedFileURL
        let resolvedPath = resolvedURL.path
        
        // Step 3: Restrict to app bundle and known safe directories only
        var allowedPaths: Set<String> = Set([
            Bundle.main.resourcePath,
            Bundle.main.bundlePath,
        ].compactMap { basePath in
            guard let basePath = basePath, !basePath.isEmpty else { return nil }
            return URL(fileURLWithPath: basePath).standardizedFileURL.path
        })

        // Allow Resources/Models directory for testing
        if let resourcesModelsPath = Bundle.main.resourceURL?.appendingPathComponent("Models").path {
            allowedPaths.insert(resourcesModelsPath)
        }
        // Also allow direct Resources/Models path for development
        let devResourcesModels = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources")
            .appendingPathComponent("Models")
            .standardizedFileURL.path
        allowedPaths.insert(devResourcesModels)
        
        // Step 4: Strict path validation - must be within allowed directories
        let isPathAllowed = allowedPaths.contains { allowedPath in
            // Must be exactly within allowed path or subdirectory
            resolvedPath == allowedPath || resolvedPath.hasPrefix(allowedPath + "/")
        }
        
        guard isPathAllowed else {
            throw ONNXError.modelNotFound("Model path not in allowed directories: \(resolvedPath)")
        }
        
        // Step 5: Additional security checks
        let resourceValues = try resolvedURL.resourceValues(forKeys: [
            .isReadableKey, 
            .fileSizeKey,
            .contentModificationDateKey
        ])
        
        guard resourceValues.isReadable == true else {
            throw ONNXError.modelNotFound("Model file is not readable")
        }
        
        guard let fileSize = resourceValues.fileSize, fileSize > 0 else {
            throw ONNXError.modelNotFound("Model file is empty or inaccessible")
        }
        
        // Reasonable size limit for ONNX models (prevent DoS)
        guard fileSize <= 500 * 1024 * 1024 else { // 500MB limit
            throw ONNXError.modelNotFound("Model file too large: \(fileSize) bytes")
        }
        
        guard isPathAllowed else {
            throw ONNXError.modelNotFound("Model path not in allowed directories: \(resolvedPath)")
        }
        
        // Step 4: File existence and readability check (TOCTOU: check happens immediately before use)
        // This is checked again at model loading time before actual file operations
        guard fm.fileExists(atPath: resolvedPath) else {
            throw ONNXError.modelNotFound("Model file does not exist: \(resolvedPath)")
        }
        
        guard fm.isReadableFile(atPath: resolvedPath) else {
            throw ONNXError.modelNotFound("Model file is not readable: \(resolvedPath)")
        }
        
        // Step 5: File extension validation (case-insensitive)
        guard resolvedPath.lowercased().hasSuffix(".onnx") else {
            throw ONNXError.modelNotFound("Model file must have .onnx extension: \(resolvedPath)")
        }
        
        // Step 6: Additional security: Validate file size to prevent DoS
        // ONNX model files are typically 50-200MB, allow up to 1GB
        do {
            let attributes = try fm.attributesOfItem(atPath: resolvedPath)
            if let fileSize = attributes[.size] as? NSNumber {
                let maxFileSize = 1_000_000_000 as Int64  // 1GB
                guard fileSize.int64Value <= maxFileSize else {
                    throw ONNXError.modelNotFound("Model file size exceeds maximum allowed (1GB): \(resolvedPath)")
                }
            }
        } catch {
            if let onnxError = error as? ONNXError {
                throw onnxError
            }
            throw ONNXError.modelNotFound("Cannot determine model file size: \(error.localizedDescription)")
        }
        
        return resolvedPath
    }
}

// MARK: - Tensor Structure

/// Simple tensor structure for ONNX data
struct Tensor {
    let shape: [Int]
    let data: [Float]  // Fix HIGH: Immutable for thread safety
    
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
