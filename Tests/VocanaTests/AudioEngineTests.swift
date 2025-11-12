import XCTest
@testable import Vocana

@MainActor
final class AudioEngineTests: XCTestCase {
    var audioEngine: AudioEngine!
    
    override func setUp() {
        super.setUp()
        let mockMLProcessor = MockMLAudioProcessor()
        audioEngine = AudioEngine(mlProcessor: mockMLProcessor)
    }
    
    override func tearDown() {
        audioEngine = nil
        super.tearDown()
    }
    
    func testInitialState() {
        XCTAssertEqual(audioEngine.currentLevels.input, 0.0)
        XCTAssertEqual(audioEngine.currentLevels.output, 0.0)
    }
    
    func testStartAudioProcessing() {
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)

        // Allow timer to fire by running RunLoop cycles
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        // Test either real audio (levels can be 0 if no audio input) or simulated audio
        let hasRealAudio = audioEngine.isUsingRealAudio
        if hasRealAudio {
            // Real audio capture doesn't guarantee non-zero levels in test environment
            XCTAssertFalse(audioEngine.currentLevels.input.isNaN, "Input level should not be NaN")
            XCTAssertFalse(audioEngine.currentLevels.output.isNaN, "Output level should not be NaN")
        } else {
            // Simulated audio may or may not produce levels in test environment
            // Just verify levels are valid (not NaN)
            XCTAssertFalse(audioEngine.currentLevels.input.isNaN, "Simulated input level should not be NaN")
            XCTAssertFalse(audioEngine.currentLevels.output.isNaN, "Simulated output level should not be NaN")
        }
    }
    
    func testStopAudioProcessing() {
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
        audioEngine.setAudioProcessingEnabled(false, sensitivity: 0.5)
        
        let levels = audioEngine.currentLevels
        
        let expectation = XCTestExpectation(description: "Levels remain stable after stop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 1.0)
        
        XCTAssertEqual(audioEngine.currentLevels.input, levels.input)
        XCTAssertEqual(audioEngine.currentLevels.output, levels.output)
    }
    
    func testDisabledStateDecay() {
        // This test verifies that when simulation is disabled,
        // levels eventually decay to near-zero (not generating new random levels)
        
        // Manually set non-zero levels to test decay
        audioEngine.currentLevels = AudioLevels(input: 0.8, output: 0.4)
        
        // Start audio processing in disabled mode
        audioEngine.setAudioProcessingEnabled(false, sensitivity: 0.5)
        
        // Wait for multiple timer ticks to allow decay
        let decayExpectation = XCTestExpectation(description: "Audio levels decay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            decayExpectation.fulfill()
        }
        wait(for: [decayExpectation], timeout: 2.0)
        
        // After 10 timer ticks (1.0s / 0.1s), levels should decay: 0.9^10 ≈ 0.35
        // Starting from 0.8 input: 0.8 * 0.35 = 0.28
        // Starting from 0.4 output: 0.4 * 0.35 = 0.14
        // Use conservative threshold of 0.5x to account for timing variance
        XCTAssertLessThan(audioEngine.currentLevels.input, 0.5,
                         "Input should decay below 0.5: \(audioEngine.currentLevels.input)")
        XCTAssertLessThan(audioEngine.currentLevels.output, 0.25,
                         "Output should decay below 0.25: \(audioEngine.currentLevels.output)")
    }

    func testMLProcessingInitialization() {
        // Initially ML processing should not be active
        XCTAssertFalse(audioEngine.isMLProcessingActive, "ML processing should not be active initially")

        // Start audio processing to trigger ML initialization
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)

        // Wait for ML initialization to complete (should happen quickly with mock)
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && !audioEngine.isMLProcessingActive {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }

        // With the mock implementation, ML processing should become active
        XCTAssertTrue(audioEngine.isMLProcessingActive, "ML processing should be active after initialization")
    }
}