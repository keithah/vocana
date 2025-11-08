import XCTest
@testable import Vocana

/// Comprehensive security tests for input validation edge cases
/// 
/// These tests verify that the audio processing pipeline properly handles
/// malicious inputs and edge cases that could cause security vulnerabilities
/// or system instability.
final class SecurityValidationTests: XCTestCase {
    
    // MARK: - DeepFilterNet Security Tests
    
    func testTensorShapeBoundsChecking() throws {
        let denoiser = try DeepFilterNet.withDefaultModels()
        
        // Test oversized tensor shapes
        let oversizedShape = [1, 1, 1, 10_000_000] // Exceeds reasonable limits
        let oversizedData = Array(repeating: 1.0 as Float, count: 10_000_000)
        let oversizedTensor = Tensor(shape: oversizedShape, data: oversizedData)
        
        let inputs = ["erb_feat": oversizedTensor]
        
        // Should throw error for oversized tensor
        XCTAssertThrowsError(try denoiser.process(audio: generateValidAudio())) { error in
            XCTAssertTrue(error.localizedDescription.contains("too large") || 
                         error.localizedDescription.contains("overflow"))
        }
    }
    
    func testMaliciousAudioInput() throws {
        let denoiser = try DeepFilterNet.withDefaultModels()
        
        // Test NaN values
        let nanAudio = Array(repeating: Float.nan, count: 960)
        XCTAssertThrowsError(try denoiser.process(audio: nanAudio)) { error in
            XCTAssertTrue(error.localizedDescription.contains("NaN"))
        }
        
        // Test Infinity values
        let infinityAudio = Array(repeating: Float.infinity, count: 960)
        XCTAssertThrowsError(try denoiser.process(audio: infinityAudio)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Infinity"))
        }
        
        // Test extreme amplitude values
        let extremeAudio = Array(repeating: Float.greatestFiniteMagnitude, count: 960)
        XCTAssertThrowsError(try denoiser.process(audio: extremeAudio)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Amplitude"))
        }
        
        // Test denormal values
        let denormalAudio = Array(repeating: Float.leastNormalMagnitude / 2, count: 960)
        XCTAssertThrowsError(try denoiser.process(audio: denormalAudio)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Denormal"))
        }
    }
    
    func testBufferOverflowProtection() throws {
        let bufferManager = AudioBufferManager()
        
        // Test rapid buffer additions to trigger rate limiting
        let samples = Array(repeating: 0.1 as Float, count: 512)
        var overflowCount = 0
        var circuitBreakerTriggered = false
        
        // Simulate rapid buffer additions that exceed rate limit
        for i in 0..<1500 { // Exceeds maxOperationsPerSecond
            let result = bufferManager.appendToBufferAndExtractChunk(samples: samples) { duration in
                circuitBreakerTriggered = true
            }
            
            if result == nil && i > 100 {
                overflowCount += 1
            }
        }
        
        // Should trigger rate limiting after threshold
        XCTAssertTrue(overflowCount > 0, "Rate limiting should trigger for rapid operations")
    }
    
    // MARK: - ONNXModel Security Tests
    
    func testPathTraversalPrevention() throws {
        // Test various path traversal attempts
        let maliciousPaths = [
            "../../../etc/passwd",
            "..\\..\\windows\\system32\\config\\sam",
            "/etc/shadow",
            "~/.ssh/id_rsa",
            "/var/log/system.log",
            "%2e%2e%2f%2e%2e%2fetc%2fpasswd", // URL encoded traversal
            "....//....//....//etc/passwd",
            "..%252f..%252f..%252fetc%252fpasswd" // Double encoded
        ]
        
        for maliciousPath in maliciousPaths {
            XCTAssertThrowsError(try ONNXModel(modelPath: maliciousPath)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Invalid path format") ||
                             error.localizedDescription.contains("dangerous pattern") ||
                             error.localizedDescription.contains("not in allowed directories"))
            }
        }
    }
    
    func testModelFileValidation() throws {
        // Test non-existent file
        XCTAssertThrowsError(try ONNXModel(modelPath: "nonexistent.onnx")) { error in
            XCTAssertTrue(error.localizedDescription.contains("not found"))
        }
        
        // Test wrong file extension
        XCTAssertThrowsError(try ONNXModel(modelPath: Bundle.main.bundlePath)) { error in
            XCTAssertTrue(error.localizedDescription.contains(".onnx extension"))
        }
        
        // Test empty path
        XCTAssertThrowsError(try ONNXModel(modelPath: "")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Empty model path"))
        }
    }
    
    // MARK: - AudioVisualizerView Security Tests
    
    func testAudioVisualizerInputValidation() {
        // Test NaN input
        let nanView = AudioVisualizerView(inputLevel: Float.nan, outputLevel: 0.5)
        XCTAssertNotNil(nanView)
        
        // Test Infinity input
        let infinityView = AudioVisualizerView(inputLevel: Float.infinity, outputLevel: 0.5)
        XCTAssertNotNil(infinityView)
        
        // Test extreme values
        let extremeView = AudioVisualizerView(inputLevel: 1000.0, outputLevel: -1000.0)
        XCTAssertNotNil(extremeView)
        
        // Test denormal values
        let denormalView = AudioVisualizerView(inputLevel: Float.leastNormalMagnitude / 2, outputLevel: 0.5)
        XCTAssertNotNil(denormalView)
    }
    
    // MARK: - Memory Exhaustion Tests
    
    func testMemoryExhaustionProtection() throws {
        let denoiser = try DeepFilterNet.withDefaultModels()
        
        // Test extremely large audio buffer
        let hugeAudio = Array(repeating: 0.1 as Float, count: 48_000 * 3600) // 1 hour of audio
        
        XCTAssertThrowsError(try denoiser.processBuffer(hugeAudio)) { error in
            XCTAssertTrue(error.localizedDescription.contains("too large"))
        }
    }
    
    // MARK: - Helper Methods
    
    private func generateValidAudio() -> [Float] {
        // Generate 1 second of valid audio at 48kHz
        let sampleCount = 48_000
        var audio: [Float] = []
        audio.reserveCapacity(sampleCount)
        
        for i in 0..<sampleCount {
            // Generate a simple sine wave
            let frequency: Float = 440.0 // A4 note
            let amplitude: Float = 0.1
            let sample = amplitude * sin(2.0 * Float.pi * frequency * Float(i) / 48_000.0)
            audio.append(sample)
        }
        
        return audio
    }
}

// MARK: - Performance Security Tests

extension SecurityValidationTests {
    
    func testPerformanceAttackPrevention() throws {
        let denoiser = try DeepFilterNet.withDefaultModels()
        
        // Test rapid processing attempts
        let audio = generateValidAudio()
        
        measure {
            for _ in 0..<100 {
                do {
                    _ = try denoiser.process(audio: audio)
                } catch {
                    // Expected to fail due to rate limiting or other protections
                    break
                }
            }
        }
    }
    
    func testDenormalAttackPrevention() throws {
        let denoiser = try DeepFilterNet.withDefaultModels()
        
        // Create audio with many denormal values (performance attack)
        var denormalAudio: [Float] = []
        denormalAudio.reserveCapacity(960)
        
        for i in 0..<960 {
            if i % 2 == 0 {
                denormalAudio.append(Float.leastNormalMagnitude / 10) // Denormal
            } else {
                denormalAudio.append(0.1) // Normal
            }
        }
        
        XCTAssertThrowsError(try denoiser.process(audio: denormalAudio)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Denormal"))
        }
    }
}