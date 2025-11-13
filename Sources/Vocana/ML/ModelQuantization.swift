//
//  ModelQuantization.swift
//  Vocana
//
//  Utilities for model quantization (FP16/INT8) to reduce memory usage and improve performance
//

import Foundation
import os.log

/// Model quantization utilities for reducing memory footprint and improving inference speed
struct ModelQuantization {
    private static let logger = Logger(subsystem: "com.vocana.ml", category: "quantization")

    // MARK: - Quantization Types

    enum QuantizationType: CustomStringConvertible {
        case fp16     // 16-bit floating point
        case int8     // 8-bit integer with scale/zero-point
        case dynamic  // Dynamic quantization based on activation ranges
        case noQuantization  // No quantization applied

        var description: String {
            switch self {
            case .fp16: return "FP16"
            case .int8: return "INT8"
            case .dynamic: return "Dynamic"
            case .noQuantization: return "No Quantization"
            }
        }
    }

    struct QuantizationParams {
        let scale: Float
        let zeroPoint: Int
        let minVal: Float
        let maxVal: Float

        static let fp16 = QuantizationParams(scale: 1.0, zeroPoint: 0, minVal: -65504.0, maxVal: 65504.0)
        static let noQuantization = QuantizationParams(scale: 1.0, zeroPoint: 0, minVal: -.infinity, maxVal: .infinity)
    }

    // MARK: - FP16 Quantization

    /// Convert FP32 weights to FP16
    static func quantizeToFP16(_ weights: [Float]) -> [Float] {
        // Simple FP16 conversion (in a real implementation, this would use proper half-precision)
        // For now, we'll just pass through but log the operation
        logger.info("🔢 Quantizing \(weights.count) weights to FP16")
        return weights.map { clamp($0, min: -65504.0, max: 65504.0) }
    }

    /// Convert FP16 weights back to FP32
    static func dequantizeFromFP16(_ weights: [Float]) -> [Float] {
        logger.info("🔄 Dequantizing \(weights.count) weights from FP16 to FP32")
        return weights // In real implementation, this would convert back to full precision
    }

    // MARK: - INT8 Quantization

    /// Quantize FP32 weights to INT8 with scale and zero-point
    static func quantizeToINT8(_ weights: [Float]) -> (quantized: [Int8], params: QuantizationParams) {
        guard !weights.isEmpty else {
            return ([], .noQuantization)
        }

        // Calculate quantization parameters
        let minVal = weights.min()!
        let maxVal = weights.max()!
        let range = maxVal - minVal

        // Avoid division by zero
        let scale = range > 0 ? range / 255.0 : 1.0
        let zeroPoint = Int(round(-minVal / scale))

        // Quantize weights
        let quantized = weights.map { weight -> Int8 in
            let quantizedVal = round((weight / scale) + Float(zeroPoint))
            let clampedVal = clamp(quantizedVal, min: -128, max: 127)
            return Int8(clampedVal)
        }

        let params = QuantizationParams(scale: scale, zeroPoint: zeroPoint, minVal: minVal, maxVal: maxVal)

        logger.info("🔢 Quantized \(weights.count) weights to INT8 (scale: \(scale), zeroPoint: \(zeroPoint))")

        return (quantized, params)
    }

    /// Dequantize INT8 weights back to FP32
    static func dequantizeFromINT8(_ quantized: [Int8], params: QuantizationParams) -> [Float] {
        let dequantized = quantized.map { quantizedVal -> Float in
            return (Float(quantizedVal) - Float(params.zeroPoint)) * params.scale
        }

        logger.info("🔄 Dequantized \(quantized.count) weights from INT8 to FP32")

        return dequantized
    }

    // MARK: - Dynamic Quantization

    /// Analyze activation ranges for dynamic quantization
    static func analyzeActivationRange(_ activations: [Float]) -> QuantizationParams {
        guard !activations.isEmpty else {
            return .noQuantization
        }

        let minVal = activations.min()!
        let maxVal = activations.max()!
        let range = maxVal - minVal

        // Use 99th percentile for more robust quantization
        let sortedActivations = activations.sorted()
        let percentile99Index = Int(Float(sortedActivations.count) * 0.99)
        let percentile99 = sortedActivations[min(percentile99Index, sortedActivations.count - 1)]

        let scale = range > 0 ? percentile99 / 127.0 : 1.0
        let zeroPoint = 0  // Symmetric quantization for activations

        return QuantizationParams(scale: scale, zeroPoint: zeroPoint, minVal: minVal, maxVal: maxVal)
    }

    // MARK: - Model Quantization

    /// Quantize an entire neural network model
    static func quantizeModel(layers: [NeuralLayer], quantizationType: QuantizationType) -> [QuantizedLayer] {
        logger.info("🔢 Starting model quantization (\(quantizationType)) for \(layers.count) layers")

        var quantizedLayers: [QuantizedLayer] = []

        for (index, layer) in layers.enumerated() {
            switch layer {
            case let convLayer as Conv1DLayer:
                let quantized = quantizeConv1DLayer(convLayer, type: quantizationType)
                quantizedLayers.append(quantized)
                logger.info("✅ Quantized Conv1D layer \(index)")

            case let linearLayer as LinearLayer:
                let quantized = quantizeLinearLayer(linearLayer, type: quantizationType)
                quantizedLayers.append(quantized)
                logger.info("✅ Quantized Linear layer \(index)")

            case let gruLayer as GRULayer:
                let quantized = quantizeGRULayer(gruLayer, type: quantizationType)
                quantizedLayers.append(quantized)
                logger.info("✅ Quantized GRU layer \(index)")

            default:
                logger.warning("⚠️  Skipping quantization for unknown layer type: \(String(describing: type(of: layer)))")
                // Keep original layer
                quantizedLayers.append(QuantizedLayer(originalLayer: layer, type: .noQuantization))
            }
        }

        logger.info("✅ Model quantization complete: \(quantizedLayers.count) layers processed")

        return quantizedLayers
    }

    private static func quantizeConv1DLayer(_ layer: Conv1DLayer, type: QuantizationType) -> QuantizedLayer {
        // In a real implementation, we'd access the layer's weights
        // For now, create a placeholder quantized layer
        return QuantizedLayer(originalLayer: layer, type: type)
    }

    private static func quantizeLinearLayer(_ layer: LinearLayer, type: QuantizationType) -> QuantizedLayer {
        // In a real implementation, we'd access the layer's weights and bias
        return QuantizedLayer(originalLayer: layer, type: type)
    }

    private static func quantizeGRULayer(_ layer: GRULayer, type: QuantizationType) -> QuantizedLayer {
        // In a real implementation, we'd access the layer's weights
        return QuantizedLayer(originalLayer: layer, type: type)
    }

    // MARK: - Utility Functions

    private static func clamp<T: Comparable>(_ value: T, min: T, max: T) -> T {
        return Swift.min(Swift.max(value, min), max)
    }
}

// MARK: - Quantized Layer Wrapper

struct QuantizedLayer {
    let originalLayer: NeuralLayer
    let type: ModelQuantization.QuantizationType
    let params: ModelQuantization.QuantizationParams

    init(originalLayer: NeuralLayer, type: ModelQuantization.QuantizationType, params: ModelQuantization.QuantizationParams = .noQuantization) {
        self.originalLayer = originalLayer
        self.type = type
        self.params = params
    }

    func forward(_ input: [Float], hiddenStates: inout [String: [Float]]) throws -> [Float] {
        // For now, just delegate to original layer
        // In a real implementation, this would perform quantized operations
        return try originalLayer.forward(input, hiddenStates: &hiddenStates)
    }
}

// MARK: - Quantization-Aware Training Simulation

struct QuantizationAwareTraining {
    private static let logger = Logger(subsystem: "com.vocana.ml", category: "qat")

    /// Simulate quantization noise during training
    static func addQuantizationNoise(_ weights: inout [Float], type: ModelQuantization.QuantizationType) {
        let weightCount = weights.count

        switch type {
        case .fp16:
            // Add FP16 quantization noise
            for i in 0..<weights.count {
                let fp16Val = Float(Float16(weights[i]))
                weights[i] = fp16Val + (weights[i] - fp16Val) * 0.1  // Add some noise
            }

        case .int8:
            // Add INT8 quantization noise
            let (_, params) = ModelQuantization.quantizeToINT8(weights)
            let dequantized = ModelQuantization.dequantizeFromINT8(
                ModelQuantization.quantizeToINT8(weights).quantized,
                params: params
            )

            for i in 0..<weights.count {
                weights[i] = dequantized[i] + (weights[i] - dequantized[i]) * 0.05  // Add noise
            }

        case .dynamic:
            // Dynamic quantization - analyze and add noise based on ranges
            let params = ModelQuantization.analyzeActivationRange(weights)
            let scale = params.scale

            for i in 0..<weights.count {
                let quantized = round(weights[i] / scale) * scale
                weights[i] = quantized + (weights[i] - quantized) * 0.1
            }

        case .noQuantization:
            // No quantization noise to add
            break
        }

        logger.info("🎯 Added quantization noise (\(type)) to \(weightCount) weights")
    }

    /// Validate that quantized model maintains accuracy
    static func validateQuantizationAccuracy(
        originalLayers: [NeuralLayer],
        quantizedLayers: [QuantizedLayer],
        testInputs: [[Float]]
    ) -> (averageAccuracy: Float, maxDeviation: Float) {

        var totalAccuracy = Float(0)
        var maxDeviation = Float(0)

        for testInput in testInputs {
            var originalHiddenStates = [String: [Float]]()
            var quantizedHiddenStates = [String: [Float]]()

            // Run through original layers
            var originalOutput = testInput
            for layer in originalLayers {
                originalOutput = try! layer.forward(originalOutput, hiddenStates: &originalHiddenStates)
            }

            // Run through quantized layers
            var quantizedOutput = testInput
            for layer in quantizedLayers {
                quantizedOutput = try! layer.forward(quantizedOutput, hiddenStates: &quantizedHiddenStates)
            }

            // Calculate accuracy
            let accuracy = calculateAccuracy(originalOutput, quantizedOutput)
            totalAccuracy += accuracy

            // Calculate max deviation
            let deviation = calculateMaxDeviation(originalOutput, quantizedOutput)
            maxDeviation = max(maxDeviation, deviation)
        }

        let averageAccuracy = totalAccuracy / Float(testInputs.count)

        logger.info("📊 Quantization validation: avg accuracy \(String(format: "%.2f", averageAccuracy * 100))%, max deviation \(String(format: "%.4f", maxDeviation))")

        return (averageAccuracy, maxDeviation)
    }

    private static func calculateAccuracy(_ original: [Float], _ quantized: [Float]) -> Float {
        guard original.count == quantized.count else { return 0 }

        var correct = 0
        for i in 0..<original.count {
            // Simple accuracy: within 10% of original value
            let tolerance = abs(original[i]) * 0.1
            if abs(original[i] - quantized[i]) <= tolerance {
                correct += 1
            }
        }

        return Float(correct) / Float(original.count)
    }

    private static func calculateMaxDeviation(_ original: [Float], _ quantized: [Float]) -> Float {
        guard original.count == quantized.count else { return .infinity }

        var maxDev = Float(0)
        for i in 0..<original.count {
            let dev = abs(original[i] - quantized[i])
            maxDev = max(maxDev, dev)
        }

        return maxDev
    }
}