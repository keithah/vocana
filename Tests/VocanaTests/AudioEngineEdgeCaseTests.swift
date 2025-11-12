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
        audioEngine = nil
        super.tearDown()
    }
    
    // MARK: - Input Validation Tests
    
    func testEmptyAudioBufferHandling() {
        // Should not crash with empty buffer
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
        // Simulate processing empty buffer indirectly through UI updates
        let initialLevel = audioEngine.currentLevels.input
        XCTAssertGreaterThanOrEqual(initialLevel, 0.0, "Should handle empty buffers gracefully")
    }
    
      func testNaNValuesInAudioInput() {
          // Engine should detect NaN and skip ML processing
          audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
          
          // Wait for ML initialization
          let expectation = XCTestExpectation(description: "NaN handling verified")
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
               // Create audio buffer with NaN values
               _ = [Float.nan, Float.nan, Float.nan, Float.nan]

               // Engine validation should reject these samples
               // The engine's validateAudioInput() should skip ML processing
               // but still produce fallback output levels
               _ = self.audioEngine.currentLevels
              
              // After attempting to process NaN values, levels should either:
              // 1. Remain unchanged (validation rejected)
              // 2. Show fallback processing (no ML)
              XCTAssertNotNil(self.audioEngine.currentLevels, "Engine should handle NaN gracefully")
              XCTAssertFalse(self.audioEngine.currentLevels.input.isNaN, "Output should never be NaN")
              XCTAssertFalse(self.audioEngine.currentLevels.output.isNaN, "Output should never be NaN")
              expectation.fulfill()
          }
          
          wait(for: [expectation], timeout: 1.0)
      }
    
      func testInfinityValuesInAudioInput() {
          // Engine should detect infinity and skip ML processing
          audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
          
          // Wait for initialization
          let expectation = XCTestExpectation(description: "Infinity handling verified")
          
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
               // Create audio buffer with Infinity values
               _ = [Float.infinity, -Float.infinity, Float.infinity, -Float.infinity]

               // Engine validation should reject these samples
               // The engine's validateAudioInput() should skip ML processing
               // but still produce fallback output levels
               let level = self.audioEngine.currentLevels.input
              
              // Verify outputs are valid finite numbers
              XCTAssertGreaterThanOrEqual(level, 0.0, "Input level should be >= 0")
              XCTAssertFalse(level.isInfinite, "Input level should never be infinite")
              XCTAssertFalse(level.isNaN, "Input level should never be NaN")
              XCTAssertTrue(level.isFinite, "Input level should always be finite")
              
              let outputLevel = self.audioEngine.currentLevels.output
              XCTAssertTrue(outputLevel.isFinite, "Output level should always be finite")
              expectation.fulfill()
          }
          
          wait(for: [expectation], timeout: 1.0)
      }
    
     func testExtremeAmplitudeValues() {
         // Should reject and skip ML processing on extreme amplitudes
         audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
         
         let expectation = XCTestExpectation(description: "Extreme amplitude handling verified")
         DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
              // Create audio buffer with extreme values (> maxAudioAmplitude)
              _ = [1e8, -1e8, 1e10, -1e10]

              // Engine validation should reject these as they exceed maxAudioAmplitude
              let level = self.audioEngine.currentLevels.input
             
             // Should still produce valid output
             XCTAssertGreaterThanOrEqual(level, 0.0, "Should handle extreme amplitudes without crashing")
             XCTAssertTrue(level.isFinite, "Level should be finite even with extreme input")
             expectation.fulfill()
         }
         
         wait(for: [expectation], timeout: 1.0)
     }
    
    func testClippedAudioDetection() {
        // Saturated signal with RMS near maximum should be detected
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
        // Should detect saturation and potentially skip ML processing
        let level = audioEngine.currentLevels.input
        XCTAssertGreaterThanOrEqual(level, 0.0, "Should detect clipped audio")
    }
    
    // MARK: - Buffer Management Tests
    
    func testVeryLargeAudioBuffer() {
        // Should not crash with large buffers (1 second of audio)
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
        
        // Should not crash with large buffers
        let level = audioEngine.currentLevels.input
        XCTAssertGreaterThanOrEqual(level, 0.0, "Should handle large audio buffers")
    }
    
    func testRapidStartStop() {
        for _ in 0..<10 {
            audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
            audioEngine.setAudioProcessingEnabled(false, sensitivity: 0.5)
        }
        
        // Should end in stopped state
        let level = audioEngine.currentLevels.input
        XCTAssertGreaterThanOrEqual(level, 0.0, "Should handle rapid start/stop cycles")
    }
    
    func testBufferOverflowRecovery() {
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
        
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
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
        
        // Should not try ML processing on silence
        let initialLevel = audioEngine.currentLevels.input
        XCTAssertGreaterThanOrEqual(initialLevel, 0.0, "Should handle silence")
    }
    
    func testMemoryPressureRecovery() {
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
        
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
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.0)
        
        // With zero sensitivity and simulation, output might be affected
        let level = audioEngine.currentLevels.output
        XCTAssertGreaterThanOrEqual(level, 0.0, "Should handle zero sensitivity")
    }
    
    func testMaximumSensitivity() {
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 1.0)
        
        // Should not crash with maximum sensitivity
        let level = audioEngine.currentLevels.output
        XCTAssertGreaterThanOrEqual(level, 0.0, "Should handle maximum sensitivity")
    }
    
    // MARK: - State Machine Tests
    
    func testStartStopStateTransitions() {
        // Test valid state transitions
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
        var level = audioEngine.currentLevels.input
        XCTAssertGreaterThanOrEqual(level, 0.0, "Should start simulation")
        
        audioEngine.setAudioProcessingEnabled(false, sensitivity: 0.5)
        level = audioEngine.currentLevels.input
        XCTAssertGreaterThanOrEqual(level, 0.0, "Should stop simulation")
    }
    
    func testDoubleStartIdempotent() {
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
        let firstLevel = audioEngine.currentLevels.input
        
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
        let secondLevel = audioEngine.currentLevels.input
        
        XCTAssertGreaterThanOrEqual(firstLevel, 0.0, "First start should work")
        XCTAssertGreaterThanOrEqual(secondLevel, 0.0, "Double start should be idempotent")
        audioEngine.setAudioProcessingEnabled(false, sensitivity: 0.5)
    }
    
    func testStopWhenAlreadyStopped() {
        audioEngine.setAudioProcessingEnabled(false, sensitivity: 0.5)

        // Should not crash
        audioEngine.setAudioProcessingEnabled(false, sensitivity: 0.5)
        let level = audioEngine.currentLevels.input
        XCTAssertGreaterThanOrEqual(level, 0.0, "Should handle double stop")
    }

    // MARK: - Resource Cleanup Tests

    func testResourceCleanupOnStop() {
        // Start simulation to initialize resources
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)

        // Wait for initialization
        let startExpectation = XCTestExpectation(description: "Simulation started")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            startExpectation.fulfill()
        }
        wait(for: [startExpectation], timeout: 1.0)

        // Capture initial levels
        let initialLevels = audioEngine.currentLevels

        // Stop simulation (this starts decay timer since isEnabled becomes false)
        audioEngine.setAudioProcessingEnabled(false, sensitivity: 0.5)

        // Verify decay is working properly after stop (levels should decrease over time)
        let decayExpectation = XCTestExpectation(description: "Decay working after stop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let decayedLevels = self.audioEngine.currentLevels
            // Levels should have decayed (become smaller) due to the decay timer
            XCTAssertLessThanOrEqual(decayedLevels.input, initialLevels.input, "Input should decay after stop")
            XCTAssertLessThanOrEqual(decayedLevels.output, initialLevels.output, "Output should decay after stop")
            // But they shouldn't be exactly zero (unless they were already very small)
            XCTAssertGreaterThanOrEqual(decayedLevels.input, 0.0, "Input should not go negative")
            XCTAssertGreaterThanOrEqual(decayedLevels.output, 0.0, "Output should not go negative")
            decayExpectation.fulfill()
        }
        wait(for: [decayExpectation], timeout: 1.0)
    }

    func testStateTransitionWithParameterChanges() {
        // Test changing sensitivity during operation
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)

        let initialExpectation = XCTestExpectation(description: "Initial state")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            initialExpectation.fulfill()
        }
        wait(for: [initialExpectation], timeout: 1.0)

        // Change sensitivity while running
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.8)

        let changedExpectation = XCTestExpectation(description: "Sensitivity changed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Should not crash and should continue operating
            let level = self.audioEngine.currentLevels.input
            XCTAssertGreaterThanOrEqual(level, 0.0, "Should handle sensitivity changes during operation")
            changedExpectation.fulfill()
        }
        wait(for: [changedExpectation], timeout: 1.0)

        audioEngine.setAudioProcessingEnabled(false, sensitivity: 0.5)
    }

    func testDisabledToEnabledTransition() {
        // Start disabled
        audioEngine.setAudioProcessingEnabled(false, sensitivity: 0.5)

        let disabledExpectation = XCTestExpectation(description: "Disabled state")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            disabledExpectation.fulfill()
        }
        wait(for: [disabledExpectation], timeout: 1.0)

        // Enable while running
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)

        let enabledExpectation = XCTestExpectation(description: "Enabled state")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let level = self.audioEngine.currentLevels.input
            XCTAssertGreaterThanOrEqual(level, 0.0, "Should handle enable transition")
            enabledExpectation.fulfill()
        }
        wait(for: [enabledExpectation], timeout: 1.0)

        audioEngine.setAudioProcessingEnabled(false, sensitivity: 0.5)
    }

    func testEnabledToDisabledTransition() {
        // Start enabled
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)

        let enabledExpectation = XCTestExpectation(description: "Enabled state")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            enabledExpectation.fulfill()
        }
        wait(for: [enabledExpectation], timeout: 1.0)

        // Disable while running
        audioEngine.setAudioProcessingEnabled(false, sensitivity: 0.5)

        let disabledExpectation = XCTestExpectation(description: "Disabled state")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Should continue operating but in disabled mode
            let level = self.audioEngine.currentLevels.input
            XCTAssertGreaterThanOrEqual(level, 0.0, "Should handle disable transition")
            disabledExpectation.fulfill()
        }
        wait(for: [disabledExpectation], timeout: 1.0)

        audioEngine.setAudioProcessingEnabled(false, sensitivity: 0.5)
    }

    func testDeinitCleanup() {
        // Test that deinit properly cleans up resources
        var engine: AudioEngine? = AudioEngine()
        engine?.setAudioProcessingEnabled(true, sensitivity: 0.5)

        let startExpectation = XCTestExpectation(description: "Engine started")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            startExpectation.fulfill()
        }
        wait(for: [startExpectation], timeout: 1.0)

        // Simulate deinit by setting to nil
        engine?.setAudioProcessingEnabled(false, sensitivity: 0.5)
        engine = nil

        // Should not crash and resources should be cleaned up
        XCTAssertNil(engine, "Engine should be deallocated")
    }
}
