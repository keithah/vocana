import XCTest
@testable import Vocana

@MainActor
final class AudioEngineTests: XCTestCase {
    var audioEngine: AudioEngine!
    
    override func setUp() {
        super.setUp()
        audioEngine = AudioEngine()
    }
    
    override func tearDown() {
        audioEngine.stopSimulation()
        audioEngine = nil
        super.tearDown()
    }
    
    func testInitialState() {
        XCTAssertEqual(audioEngine.currentLevels.input, 0.0)
        XCTAssertEqual(audioEngine.currentLevels.output, 0.0)
    }
    
    func testStartSimulation() {
        audioEngine.startSimulation(isEnabled: true, sensitivity: 0.5)

        let expectation = XCTestExpectation(description: "Audio levels update")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)

        XCTAssertGreaterThan(audioEngine.currentLevels.input, 0.0, "Input level should be > 0.0 after simulation starts")
        XCTAssertGreaterThan(audioEngine.currentLevels.output, 0.0, "Output level should be > 0.0 after simulation starts")
    }
    
    func testStopSimulation() {
        audioEngine.startSimulation(isEnabled: true, sensitivity: 0.5)
        audioEngine.stopSimulation()
        
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
        
        // Start simulation in disabled mode
        audioEngine.startSimulation(isEnabled: false, sensitivity: 0.5)
        
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
}