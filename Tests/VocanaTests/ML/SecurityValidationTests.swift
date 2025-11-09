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
        
        // Test with extremely large audio buffer to trigger tensor bounds check
        let hugeAudio = Array(repeating: 0.1 as Float, count: 48_000 * 100) // ~100 seconds
        
        XCTAssertThrowsError(try denoiser.processBuffer(hugeAudio)) { error in
            XCTAssertTrue(error.localizedDescription.contains("too large") || 
                         error.localizedDescription.contains("buffer"))
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
        var rateLimitTriggered = false
        
        // Simulate rapid buffer additions that exceed rate limit
        for _ in 0..<1500 { // Exceeds maxOperationsPerSecond
            let result = bufferManager.appendToBufferAndExtractChunk(samples: samples) { _ in }
            
            // Rate limiting returns nil to reject the operation
            if result == nil {
                rateLimitTriggered = true
                break
            }
        }
        
        // Should trigger rate limiting during rapid operations
        XCTAssertTrue(rateLimitTriggered, "Rate limiting should trigger for rapid buffer operations")
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
        // Test NaN input is sanitized to 0.0
        let nanLevel = AudioLevelValidator.validateAudioLevel(Float.nan)
        XCTAssertEqual(nanLevel, 0.0, "NaN should be sanitized to 0.0")
        
        // Test Infinity input is sanitized to 0.0
        let infinityLevel = AudioLevelValidator.validateAudioLevel(Float.infinity)
        XCTAssertEqual(infinityLevel, 0.0, "Infinity should be sanitized to 0.0")
        
        // Test negative Infinity is sanitized to 0.0
        let negInfinityLevel = AudioLevelValidator.validateAudioLevel(-Float.infinity)
        XCTAssertEqual(negInfinityLevel, 0.0, "Negative Infinity should be sanitized to 0.0")
        
         // Test extreme positive values are rejected as malformed input (safety measure)
         let extremePositive = AudioLevelValidator.validateAudioLevel(1000.0)
         XCTAssertEqual(extremePositive, 0.0, "Extreme positive values indicate corruption and should return 0.0")
        
        // Test extreme negative values are clamped to 0.0
        let extremeNegative = AudioLevelValidator.validateAudioLevel(-1000.0)
        XCTAssertEqual(extremeNegative, 0.0, "Extreme negative values should be clamped to 0.0")
        
        // Test denormal values are sanitized to 0.0
        let denormalLevel = AudioLevelValidator.validateAudioLevel(Float.leastNormalMagnitude / 2)
        XCTAssertEqual(denormalLevel, 0.0, "Denormal values should be sanitized to 0.0")
        
        // Test normal range values are preserved and clamped properly
        let normalLevel = AudioLevelValidator.validateAudioLevel(0.5)
        XCTAssertEqual(normalLevel, 0.5, "Normal values in range should be preserved")
        
        // Test boundary values
        let zeroLevel = AudioLevelValidator.validateAudioLevel(0.0)
        XCTAssertEqual(zeroLevel, 0.0, "Zero should be preserved")
        
        let oneLevel = AudioLevelValidator.validateAudioLevel(1.0)
        XCTAssertEqual(oneLevel, 1.0, "One should be preserved")
    }
    
    // MARK: - Memory Exhaustion Tests
    
    func testMemoryExhaustionProtection() throws {
        let denoiser = try DeepFilterNet.withDefaultModels()
        
        // Test buffer exceeding maximum configured size (avoid huge memory allocation)
        // maxAudioProcessingSeconds = 3600, so max samples at 48kHz = 172,800,000
        let maxAllowed = 48_000 * 3600
        let oversizedAudio = Array(repeating: 0.1 as Float, count: maxAllowed + 1)
        
        XCTAssertThrowsError(try denoiser.processBuffer(oversizedAudio)) { error in
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
        let audio = generateValidAudio()
        
        // Test rapid processing to verify system handles load gracefully
        // Should not hang or crash under high-frequency calls
        for _ in 0..<10 {
            do {
                _ = try denoiser.process(audio: audio)
            } catch {
                // Acceptable - protections may limit concurrent processing
                break
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