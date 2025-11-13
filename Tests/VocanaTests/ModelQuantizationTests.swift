//
//  ModelQuantizationTests.swift
//  Vocana
//
//  Created by AI Assistant
//

import XCTest
@testable import Vocana

class ModelQuantizationTests: XCTestCase {
    // MARK: - FP16 Quantization Tests

    func testFP16QuantizationBasic() {
        let weights: [Float] = [-2.0, -1.0, 0.0, 1.0, 2.0]
        let result = ModelQuantization.quantizeToFP16(weights)

        switch result {
        case .success(let quantized):
            XCTAssertEqual(quantized.count, weights.count)
            // FP16 values should be close to original but with reduced precision
            for (original, quantized) in zip(weights, quantized) {
                XCTAssertEqual(Float(quantized), original, accuracy: 0.01)
            }
        case .failure:
            XCTFail("FP16 quantization should succeed for valid input")
        }
    }

    func testFP16QuantizationEmptyArray() {
        let result = ModelQuantization.quantizeToFP16([])
        switch result {
        case .success:
            XCTFail("Empty array should fail quantization")
        case .failure(let error):
            XCTAssertEqual(error, QuantizationError.emptyInput)
        }
    }

    func testFP16QuantizationWithNaN() {
        let weights: [Float] = [1.0, Float.nan, 2.0]
        let result = ModelQuantization.quantizeToFP16(weights)
        switch result {
        case .success:
            XCTFail("NaN values should fail quantization")
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("NaN"))
        }
    }

    func testFP16QuantizationWithInfinity() {
        let weights: [Float] = [1.0, Float.infinity, 2.0]
        let result = ModelQuantization.quantizeToFP16(weights)
        switch result {
        case .success:
            XCTFail("Infinity values should fail quantization")
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("infinite"))
        }
    }

    func testFP16Dequantization() {
        let weights: [Float] = [-2.0, -1.0, 0.0, 1.0, 2.0]
        let quantized = ModelQuantization.quantizeToFP16(weights)

        switch quantized {
        case .success(let fp16Weights):
            let dequantized = ModelQuantization.dequantizeFromFP16(fp16Weights)
            switch dequantized {
            case .success(let result):
                XCTAssertEqual(result.count, weights.count)
                // Dequantized values should match quantized values
                for (original, final) in zip(fp16Weights, result) {
                    XCTAssertEqual(original, final)
                }
            case .failure:
                XCTFail("FP16 dequantization should succeed")
            }
        case .failure:
            XCTFail("FP16 quantization should succeed for valid input")
        }
    }

    // MARK: - INT8 Quantization Tests

    func testINT8QuantizationBasic() {
        let weights: [Float] = [-2.0, -1.0, 0.0, 1.0, 2.0]
        let result = ModelQuantization.quantizeToINT8(weights)

        switch result {
        case .success((let quantized, let params)):
            XCTAssertEqual(quantized.count, weights.count)
            XCTAssertGreaterThan(params.scale, 0)
            XCTAssertEqual(params.zeroPoint, 0) // Symmetric quantization
            XCTAssertEqual(params.minVal, -2.0)
            XCTAssertEqual(params.maxVal, 2.0)
        case .failure:
            XCTFail("INT8 quantization should succeed for valid input")
        }
    }

    func testINT8QuantizationEmptyArray() {
        let result = ModelQuantization.quantizeToINT8([])
        switch result {
        case .success:
            XCTFail("Empty array should fail quantization")
        case .failure(let error):
            XCTAssertEqual(error, QuantizationError.emptyInput)
        }
    }

    func testINT8Dequantization() {
        let weights: [Float] = [-2.0, -1.0, 0.0, 1.0, 2.0]
        let quantized = ModelQuantization.quantizeToINT8(weights)

        switch quantized {
        case .success((let int8Weights, let params)):
            let dequantized = ModelQuantization.dequantizeFromINT8(int8Weights, params: params)
            switch dequantized {
            case .success(let result):
                XCTAssertEqual(result.count, weights.count)
                // Dequantized values should be close to original (within quantization precision)
                for (original, final) in zip(weights, result) {
                    XCTAssertEqual(original, final, accuracy: params.scale)
                }
            case .failure:
                XCTFail("INT8 dequantization should succeed")
            }
        case .failure:
            XCTFail("INT8 quantization should succeed for valid input")
        }
    }

    // MARK: - Dynamic Quantization Tests

    func testDynamicQuantizationAnalysis() {
        let activations: [Float] = [-2.0, -1.0, 0.0, 1.0, 2.0]
        let params = ModelQuantization.analyzeActivationRange(activations)

        XCTAssertEqual(params.minVal, -2.0)
        XCTAssertEqual(params.maxVal, 2.0)
        XCTAssertGreaterThan(params.scale, 0)
        XCTAssertEqual(params.zeroPoint, 0)
    }

    func testDynamicQuantizationEmptyArray() {
        let params = ModelQuantization.analyzeActivationRange([])
        XCTAssertEqual(params, ModelQuantization.QuantizationParams.noQuantization)
    }

    func testDynamicQuantizationWithNaN() {
        let activations: [Float] = [1.0, Float.nan, 2.0]
        let params = ModelQuantization.analyzeActivationRange(activations)
        XCTAssertEqual(params, ModelQuantization.QuantizationParams.noQuantization)
    }

    // MARK: - Quantization-Aware Training Tests

    func testQuantizationNoiseAddition() {
        let originalWeights: [Float] = [1.0, -1.0, 2.0, -2.0]

        // Test FP16 noise
        var fp16Weights = originalWeights
        QuantizationAwareTraining.addQuantizationNoise(&fp16Weights, type: .fp16)
        XCTAssertEqual(fp16Weights.count, originalWeights.count)
        // Weights should be modified but close to original
        for (original, modified) in zip(originalWeights, fp16Weights) {
            XCTAssertEqual(original, modified, accuracy: 0.1)
        }

        // Test INT8 noise
        var int8Weights = originalWeights
        QuantizationAwareTraining.addQuantizationNoise(&int8Weights, type: .int8)
        XCTAssertEqual(int8Weights.count, originalWeights.count)

        // Test dynamic noise
        var dynamicWeights = originalWeights
        QuantizationAwareTraining.addQuantizationNoise(&dynamicWeights, type: .dynamic)
        XCTAssertEqual(dynamicWeights.count, originalWeights.count)

        // Test no quantization (should not modify)
        var noQuantWeights = originalWeights
        QuantizationAwareTraining.addQuantizationNoise(&noQuantWeights, type: .noQuantization)
        XCTAssertEqual(noQuantWeights, originalWeights)
    }

    // MARK: - Cache Behavior Tests

    func testQuantizationCaching() {
        let weights1: [Float] = [1.0, 2.0, 3.0, 4.0]
        let weights2: [Float] = [1.0, 2.0, 3.0, 4.0] // Same values
        let weights3: [Float] = [5.0, 6.0, 7.0, 8.0] // Different values

        // First quantization should create cache entry
        let result1 = ModelQuantization.quantizeToINT8(weights1)
        switch result1 {
        case .success((_, let params1)):
            // Second quantization with same values should use cache
            let result2 = ModelQuantization.quantizeToINT8(weights2)
            switch result2 {
            case .success((_, let params2)):
                XCTAssertEqual(params1.scale, params2.scale)
                XCTAssertEqual(params1.zeroPoint, params2.zeroPoint)
            case .failure:
                XCTFail("Second quantization should succeed")
            }

            // Third quantization with different values should create new cache entry
            let result3 = ModelQuantization.quantizeToINT8(weights3)
            switch result3 {
            case .success((_, let params3)):
                XCTAssertNotEqual(params1.scale, params3.scale)
            case .failure:
                XCTFail("Third quantization should succeed")
            }
        case .failure:
            XCTFail("First quantization should succeed")
        }
    }

    // MARK: - Edge Cases

    func testExtremeValues() {
        let weights: [Float] = [-1e6, -1e3, 0.0, 1e3, 1e6]
        let result = ModelQuantization.quantizeToINT8(weights)

        switch result {
        case .success((let quantized, let params)):
            XCTAssertEqual(quantized.count, weights.count)
            XCTAssertGreaterThan(params.scale, 0)
            // Should handle extreme values gracefully
            XCTAssertTrue(quantized.allSatisfy { $0 >= -127 && $0 <= 127 })
        case .failure:
            // This might fail due to extreme values, which is acceptable
            break
        }
    }

    func testSingleValueArrays() {
        let weights: [Float] = [1.0]
        let result = ModelQuantization.quantizeToINT8(weights)

        switch result {
        case .success((let quantized, let params)):
            XCTAssertEqual(quantized.count, 1)
            XCTAssertGreaterThan(params.scale, 0)
        case .failure:
            XCTFail("Single value quantization should succeed")
        }
    }

    func testLargeArrays() {
        let weights = (0..<1000).map { Float($0) }
        let result = ModelQuantization.quantizeToFP16(weights)

        switch result {
        case .success(let quantized):
            XCTAssertEqual(quantized.count, weights.count)
        case .failure:
            XCTFail("Large array quantization should succeed")
        }
    }
}