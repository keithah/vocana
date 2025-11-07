import XCTest
@testable import Vocana

final class DeepFilterNetTests: XCTestCase {
    
    // MARK: - ONNX Model Tests
    
    func testONNXModelLoading() throws {
        // Get path to test models
        let modelsPath = getModelsPath()
        
        // Test encoder loading
        let encPath = "\(modelsPath)/enc.onnx"
        let encoder = try ONNXModel(modelPath: encPath)
        XCTAssertNotNil(encoder)
        
        // Test ERB decoder loading
        let erbDecPath = "\(modelsPath)/erb_dec.onnx"
        let erbDecoder = try ONNXModel(modelPath: erbDecPath)
        XCTAssertNotNil(erbDecoder)
        
        // Test DF decoder loading
        let dfDecPath = "\(modelsPath)/df_dec.onnx"
        let dfDecoder = try ONNXModel(modelPath: dfDecPath)
        XCTAssertNotNil(dfDecoder)
    }
    
    func testONNXEncoderInference() throws {
        let modelsPath = getModelsPath()
        let encoder = try ONNXModel(modelPath: "\(modelsPath)/enc.onnx")
        
        // Create dummy inputs
        let timeSteps = 1
        let erbFeat = Tensor(shape: [1, 1, timeSteps, 32], constant: 0.1)
        let specFeat = Tensor(shape: [1, 2, timeSteps, 96], constant: 0.1)
        
        let inputs: [String: Tensor] = [
            "erb_feat": erbFeat,
            "spec_feat": specFeat
        ]
        
        // Run inference
        let outputs = try encoder.infer(inputs: inputs)
        
        // Verify outputs exist
        XCTAssertTrue(outputs.keys.contains("e0"))
        XCTAssertTrue(outputs.keys.contains("e1"))
        XCTAssertTrue(outputs.keys.contains("e2"))
        XCTAssertTrue(outputs.keys.contains("e3"))
        XCTAssertTrue(outputs.keys.contains("emb"))
        XCTAssertTrue(outputs.keys.contains("c0"))
        XCTAssertTrue(outputs.keys.contains("lsnr"))
        
        // Verify output shapes
        XCTAssertEqual(outputs["e0"]?.shape[3], 96)
        XCTAssertEqual(outputs["lsnr"]?.shape[2], 1)
    }
    
    func testTensorOperations() {
        // Test tensor creation
        let tensor1 = Tensor(shape: [2, 3], constant: 1.0)
        XCTAssertEqual(tensor1.count, 6)
        XCTAssertEqual(tensor1.data, [1.0, 1.0, 1.0, 1.0, 1.0, 1.0])
        
        // Test tensor reshape
        let tensor2 = Tensor(shape: [6], data: [1, 2, 3, 4, 5, 6])
        let reshaped = tensor2.reshaped([2, 3])
        XCTAssertEqual(reshaped.shape, [2, 3])
        XCTAssertEqual(reshaped.data, [1, 2, 3, 4, 5, 6])
    }
    
    // MARK: - Deep Filtering Tests
    
    func testDeepFilteringMaskApplication() {
        let timeSteps = 2
        let freqBins = 10
        
        // Create test spectrum
        let real = Array(repeating: 1.0 as Float, count: timeSteps * freqBins)
        let imag = Array(repeating: 0.5 as Float, count: timeSteps * freqBins)
        let spectrum = (real: real, imag: imag)
        
        // Create test mask (0.8 gain)
        let mask = Array(repeating: 0.8 as Float, count: timeSteps * freqBins)
        
        // Apply mask
        let masked = DeepFiltering.applyMask(spectrum: spectrum, mask: mask, timeSteps: timeSteps)
        
        // Verify masking
        XCTAssertEqual(masked.real[0], 0.8, accuracy: 0.001)
        XCTAssertEqual(masked.imag[0], 0.4, accuracy: 0.001)
    }
    
    func testDeepFilteringCoefficients() {
        let timeSteps = 1
        let freqBins = 100
        
        // Create test spectrum
        let real = Array(repeating: 1.0 as Float, count: timeSteps * freqBins)
        let imag = Array(repeating: 0.0 as Float, count: timeSteps * freqBins)
        let spectrum = (real: real, imag: imag)
        
        // Create test coefficients (96 bins, 5 taps)
        let numCoefs = timeSteps * 96 * 5
        let coefficients = Array(repeating: 0.2 as Float, count: numCoefs)
        
        // Apply filtering
        let filtered = DeepFiltering.apply(
            spectrum: spectrum,
            coefficients: coefficients,
            timeSteps: timeSteps
        )
        
        // Verify filtering was applied (values should change)
        XCTAssertNotEqual(filtered.real, spectrum.real)
    }
    
    func testDeepFilteringEnhance() {
        let timeSteps = 1
        let freqBins = 100
        
        let spectrum = (
            real: Array(repeating: 1.0 as Float, count: timeSteps * freqBins),
            imag: Array(repeating: 0.5 as Float, count: timeSteps * freqBins)
        )
        
        let mask = Array(repeating: 0.9 as Float, count: timeSteps * freqBins)
        let coefficients = Array(repeating: 0.1 as Float, count: timeSteps * 96 * 5)
        
        let enhanced = DeepFiltering.enhance(
            spectrum: spectrum,
            mask: mask,
            coefficients: coefficients,
            timeSteps: timeSteps
        )
        
        // Verify output has same length
        XCTAssertEqual(enhanced.real.count, spectrum.real.count)
        XCTAssertEqual(enhanced.imag.count, spectrum.imag.count)
    }
    
    // MARK: - DeepFilterNet Integration Tests
    
    func testDeepFilterNetInitialization() throws {
        let modelsPath = getModelsPath()
        let denoiser = try DeepFilterNet(modelsDirectory: modelsPath)
        XCTAssertNotNil(denoiser)
    }
    
    func testDeepFilterNetSingleFrame() throws {
        let modelsPath = getModelsPath()
        let denoiser = try DeepFilterNet(modelsDirectory: modelsPath)
        
        // Create test audio (960 samples = 20ms @ 48kHz, minimum for STFT)
        let testAudio = createTestAudio(samples: 960, frequency: 440)
        
        // Process frame
        let enhanced = try denoiser.process(audio: testAudio)
        
        // Verify output (at least hopSize samples)
        XCTAssertGreaterThanOrEqual(enhanced.count, 480)
        XCTAssertTrue(enhanced.allSatisfy { !$0.isNaN && !$0.isInfinite })
    }
    
    func testDeepFilterNetBuffer() throws {
        let modelsPath = getModelsPath()
        let denoiser = try DeepFilterNet(modelsDirectory: modelsPath)
        
        // Create longer test audio (1 second)
        let testAudio = createTestAudio(samples: 48000, frequency: 440)
        
        // Process buffer
        let enhanced = try denoiser.processBuffer(testAudio)
        
        // Verify output
        XCTAssertEqual(enhanced.count, testAudio.count)
        XCTAssertTrue(enhanced.allSatisfy { !$0.isNaN && !$0.isInfinite })
    }
    
    func testDeepFilterNetPerformance() throws {
        let modelsPath = getModelsPath()
        let denoiser = try DeepFilterNet(modelsDirectory: modelsPath)
        
        // Create test audio (960 samples = 20ms @ 48kHz)
        let testAudio = createTestAudio(samples: 960, frequency: 440)
        
        // Measure performance
        var totalLatency: Double = 0
        let iterations = 10
        
        for _ in 0..<iterations {
            let (_, latency) = try denoiser.processWithTiming(audio: testAudio)
            totalLatency += latency
        }
        
        let avgLatency = totalLatency / Double(iterations)
        print("Average latency: \(String(format: "%.2f", avgLatency)) ms")
        
        // Target: <15ms for real-time
        // Note: With mock ONNX, this should be very fast
        // With real ONNX Runtime, aim for <15ms
        XCTAssertLessThan(avgLatency, 50.0, "Latency too high for real-time processing")
    }
    
    func testDeepFilterNetReset() throws {
        let modelsPath = getModelsPath()
        let denoiser = try DeepFilterNet(modelsDirectory: modelsPath)
        
        // Process some frames
        let testAudio = createTestAudio(samples: 960, frequency: 440)
        _ = try denoiser.process(audio: testAudio)
        _ = try denoiser.process(audio: testAudio)
        
        // Reset state
        denoiser.reset()
        
        // Should still work after reset
        let enhanced = try denoiser.process(audio: testAudio)
        XCTAssertGreaterThanOrEqual(enhanced.count, 480)
    }
    
    // MARK: - Helpers
    
    private func getModelsPath() -> String {
        // Try multiple locations
        let locations = [
            "../Resources/Models",  // From test bundle
            "Resources/Models",     // Relative
            FileManager.default.currentDirectoryPath + "/Resources/Models"
        ]
        
        for location in locations {
            let encPath = "\(location)/enc.onnx"
            if FileManager.default.fileExists(atPath: encPath) {
                return location
            }
        }
        
        // Fallback to ml-models directory
        return "../ml-models/pretrained/tmp/export"
    }
    
    private func createTestAudio(samples: Int, frequency: Float) -> [Float] {
        let sampleRate: Float = 48000
        var audio = [Float](repeating: 0, count: samples)
        
        for i in 0..<samples {
            let t = Float(i) / sampleRate
            audio[i] = sin(2 * .pi * frequency * t) * 0.5
        }
        
        return audio
    }
}
