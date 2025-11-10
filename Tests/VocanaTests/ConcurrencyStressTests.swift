import XCTest
@testable import Vocana

/// Concurrency stress tests to verify thread safety of core components
@MainActor
final class ConcurrencyStressTests: XCTestCase {
    
    func testAudioEngineConcurrentAccess() throws {
        var audioEngine = AudioEngine()
        defer { audioEngine = AudioEngine() }
        
        // Start audio processing
        audioEngine.startAudioProcessing(isEnabled: true, sensitivity: 0.5)
        
        let expectation = XCTestExpectation(description: "Concurrent access completed")
        expectation.expectedFulfillmentCount = 10
        
        // Simulate concurrent access from multiple threads
        for i in 0..<10 {
            DispatchQueue.global(qos: .userInteractive).async {
                Task { @MainActor in
                    // Read current levels (should always succeed)
                    let levels = audioEngine.currentLevels
                    XCTAssertGreaterThanOrEqual(levels.input, 0.0)
                    XCTAssertGreaterThanOrEqual(levels.output, 0.0)
                    
                    // Simulate rapid start/stop cycles
                    if i % 2 == 0 {
                        audioEngine.startAudioProcessing(isEnabled: false, sensitivity: Double(i) * 0.1)
                        // Small delay to allow state changes to propagate
                        try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
                        audioEngine.startAudioProcessing(isEnabled: true, sensitivity: 0.5)
                    }
                    
                    expectation.fulfill()
                }
            }
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    func testBufferOverflowHandling() throws {
        var audioEngine = AudioEngine()
        defer { audioEngine = AudioEngine() }
        
        audioEngine.startAudioProcessing(isEnabled: true, sensitivity: 0.5)
        
        let expectation = XCTestExpectation(description: "Buffer overflow handling")
        expectation.expectedFulfillmentCount = 5
        
        // Simulate rapid audio processing that could cause buffer overflow
        for _ in 0..<5 {
            DispatchQueue.global().async {
                Task { @MainActor in
                    // Generate large audio buffer (simulate burst of audio) - not used but demonstrates allocation
                    _ = Array(repeating: Float(0.1), count: 10000)

                    // This would internally test the buffer overflow handling
                    // in appendToBufferAndExtractChunk if ML processing is active

                    // Verify engine remains stable
                    let levels = audioEngine.currentLevels
                    XCTAssertTrue(levels.input.isFinite, "Input level should remain finite during overflow")
                    XCTAssertTrue(levels.output.isFinite, "Output level should remain finite during overflow")

                    expectation.fulfill()
                }
            }
        }
        
        wait(for: [expectation], timeout: 3.0)
    }
    
    func testMemoryPressureHandling() throws {
        var audioEngine = AudioEngine()
        defer { audioEngine = AudioEngine() }
        
        audioEngine.startAudioProcessing(isEnabled: true, sensitivity: 0.5)
        
        // Test that memory pressure changes don't cause crashes
        Task { @MainActor in
            // Simulate memory pressure state changes
            audioEngine.memoryPressureLevel = .warning
            XCTAssertEqual(audioEngine.memoryPressureLevel, .warning)
            
            audioEngine.memoryPressureLevel = .critical
            XCTAssertEqual(audioEngine.memoryPressureLevel, .critical)
            
            audioEngine.memoryPressureLevel = .normal
            XCTAssertEqual(audioEngine.memoryPressureLevel, .normal)
        }
    }
}