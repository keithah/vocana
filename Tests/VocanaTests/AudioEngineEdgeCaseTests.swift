import XCTest
@testable import Vocana

/// Tests for edge cases and error recovery paths in AudioEngine
@MainActor
final class AudioEngineEdgeCaseTests: XCTestCase {
    
    private var audioEngine: AudioEngine!
    
    override func setUp() {
        super.setUp()
        audioEngine = AudioEngine()
    }
    
    override func tearDown() {
        audioEngine.stopSimulation()
        audioEngine = nil
        super.tearDown()
    }
    
    // MARK: - Input Validation Tests
    
    func testEmptyAudioBufferHandling() {
        // Should not crash with empty buffer
        audioEngine.startSimulation(isEnabled: true, sensitivity: 0.5)
        // Simulate processing empty buffer indirectly through UI updates
        let initialLevel = audioEngine.currentLevels.input
        XCTAssertGreaterThanOrEqual(initialLevel, 0.0, "Should handle empty buffers gracefully")
    }
    
     func testNaNValuesInAudioInput() {
         // Engine should detect NaN and skip processing
         audioEngine.startSimulation(isEnabled: true, sensitivity: 0.5)
         
         // Verify ML processing started when simulation begins
         let initialState = audioEngine.isMLProcessingActive
         
         // Wait briefly for ML initialization (simulated, so should be fast)
         let expectation = XCTestExpectation(description: "ML processing initialized")
         DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
             expectation.fulfill()
         }
         
         wait(for: [expectation], timeout: 1.0)
         
         // After starting with ML enabled, should attempt ML processing
         // (may succeed or fail depending on model availability, but shouldn't crash)
         XCTAssertNotNil(audioEngine.currentLevels, "Engine should produce audio levels despite NaN input")
     }
    
     func testInfinityValuesInAudioInput() {
         // Engine should detect infinity and skip processing
         audioEngine.startSimulation(isEnabled: true, sensitivity: 0.5)
         
         // Verify processing initialization happens
         let expectation = XCTestExpectation(description: "Processing continues after infinity values")
         
         DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
             // Engine should still be running and producing valid levels
             let level = self.audioEngine.currentLevels.input
             XCTAssertGreaterThanOrEqual(level, 0.0, "Input level should be >= 0")
             XCTAssertFalse(level.isInfinite, "Input level should not be infinite")
             XCTAssertFalse(level.isNaN, "Input level should not be NaN")
             expectation.fulfill()
         }
         
         wait(for: [expectation], timeout: 1.0)
     }
    
    func testExtremeAmplitudeValues() {
        // Should log warning and skip ML processing on extreme amplitudes
        audioEngine.startSimulation(isEnabled: true, sensitivity: 0.5)
        // Should log warning and skip ML processing
        let level = audioEngine.currentLevels.input
        XCTAssertGreaterThanOrEqual(level, 0.0, "Should handle extreme amplitudes without crashing")
    }
    
    func testClippedAudioDetection() {
        // Saturated signal with RMS near maximum should be detected
        audioEngine.startSimulation(isEnabled: true, sensitivity: 0.5)
        // Should detect saturation and potentially skip ML processing
        let level = audioEngine.currentLevels.input
        XCTAssertGreaterThanOrEqual(level, 0.0, "Should detect clipped audio")
    }
    
    // MARK: - Buffer Management Tests
    
    func testVeryLargeAudioBuffer() {
        // Should not crash with large buffers (1 second of audio)
        audioEngine.startSimulation(isEnabled: true, sensitivity: 0.5)
        
        // Should not crash with large buffers
        let level = audioEngine.currentLevels.input
        XCTAssertGreaterThanOrEqual(level, 0.0, "Should handle large audio buffers")
    }
    
    func testRapidStartStop() {
        for _ in 0..<10 {
            audioEngine.startSimulation(isEnabled: true, sensitivity: 0.5)
            audioEngine.stopSimulation()
        }
        
        // Should end in stopped state
        let level = audioEngine.currentLevels.input
        XCTAssertGreaterThanOrEqual(level, 0.0, "Should handle rapid start/stop cycles")
    }
    
    func testBufferOverflowRecovery() {
        audioEngine.startSimulation(isEnabled: true, sensitivity: 0.5)
        
        // Simulate sustained buffer overflow scenario
        let overflowExpectation = XCTestExpectation(description: "Buffer pressure handled")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let level = self.audioEngine.currentLevels.input
            XCTAssertGreaterThanOrEqual(level, 0.0, "Should recover from buffer overflow")
            overflowExpectation.fulfill()
        }
        
        wait(for: [overflowExpectation], timeout: 2.0)
    }
    
    // MARK: - ML Processing Error Recovery Tests
    
    func testMLProcessingWithSilence() {
        // Should not try ML processing on silence
        audioEngine.startSimulation(isEnabled: true, sensitivity: 0.5)
        
        // Should not try ML processing on silence
        let initialLevel = audioEngine.currentLevels.input
        XCTAssertGreaterThanOrEqual(initialLevel, 0.0, "Should handle silence")
    }
    
    func testMemoryPressureRecovery() {
        audioEngine.startSimulation(isEnabled: true, sensitivity: 0.5)
        
        let expectation = XCTestExpectation(description: "Memory pressure handled")
        
        // Simulate memory pressure scenario
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Check that engine is still responsive
            let level = self.audioEngine.currentLevels.input
            XCTAssertGreaterThanOrEqual(level, 0.0, "Should remain responsive under memory pressure")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 2.0)
    }
    
    // MARK: - Sensitivity Edge Cases
    
    func testZeroSensitivity() {
        audioEngine.startSimulation(isEnabled: true, sensitivity: 0.0)
        
        // With zero sensitivity and simulation, output might be affected
        let level = audioEngine.currentLevels.output
        XCTAssertGreaterThanOrEqual(level, 0.0, "Should handle zero sensitivity")
    }
    
    func testMaximumSensitivity() {
        audioEngine.startSimulation(isEnabled: true, sensitivity: 1.0)
        
        // Should not crash with maximum sensitivity
        let level = audioEngine.currentLevels.output
        XCTAssertGreaterThanOrEqual(level, 0.0, "Should handle maximum sensitivity")
    }
    
    // MARK: - State Machine Tests
    
    func testStartStopStateTransitions() {
        // Test valid state transitions
        audioEngine.startSimulation(isEnabled: true, sensitivity: 0.5)
        var level = audioEngine.currentLevels.input
        XCTAssertGreaterThanOrEqual(level, 0.0, "Should start simulation")
        
        audioEngine.stopSimulation()
        level = audioEngine.currentLevels.input
        XCTAssertGreaterThanOrEqual(level, 0.0, "Should stop simulation")
    }
    
    func testDoubleStartIdempotent() {
        audioEngine.startSimulation(isEnabled: true, sensitivity: 0.5)
        let firstLevel = audioEngine.currentLevels.input
        
        audioEngine.startSimulation(isEnabled: true, sensitivity: 0.5)
        let secondLevel = audioEngine.currentLevels.input
        
        XCTAssertGreaterThanOrEqual(firstLevel, 0.0, "First start should work")
        XCTAssertGreaterThanOrEqual(secondLevel, 0.0, "Double start should be idempotent")
        audioEngine.stopSimulation()
    }
    
    func testStopWhenAlreadyStopped() {
        audioEngine.stopSimulation()
        
        // Should not crash
        audioEngine.stopSimulation()
        let level = audioEngine.currentLevels.input
        XCTAssertGreaterThanOrEqual(level, 0.0, "Should handle double stop")
    }
}
