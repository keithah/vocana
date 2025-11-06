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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 1.0)
        
        XCTAssertGreaterThan(audioEngine.currentLevels.input, 0.0)
        XCTAssertGreaterThan(audioEngine.currentLevels.output, 0.0)
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
        audioEngine.startSimulation(isEnabled: true, sensitivity: 0.5)
        
        let expectation = XCTestExpectation(description: "Audio levels update")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        
        let activeLevels = audioEngine.currentLevels
        audioEngine.startSimulation(isEnabled: false, sensitivity: 0.5)
        
        let decayExpectation = XCTestExpectation(description: "Audio levels decay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            decayExpectation.fulfill()
        }
        wait(for: [decayExpectation], timeout: 1.0)
        
        XCTAssertLessThan(audioEngine.currentLevels.input, activeLevels.input)
        XCTAssertLessThan(audioEngine.currentLevels.output, activeLevels.output)
    }
}