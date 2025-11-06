import XCTest
@testable import Vocana

final class AudioLevelsTests: XCTestCase {
    
    func testAudioLevelsInitialization() {
        let levels = AudioLevels(input: 0.5, output: 0.3)
        XCTAssertEqual(levels.input, 0.5)
        XCTAssertEqual(levels.output, 0.3)
    }
    
    func testAudioLevelsZero() {
        let zero = AudioLevels.zero
        XCTAssertEqual(zero.input, 0.0)
        XCTAssertEqual(zero.output, 0.0)
    }
    
    func testAudioLevelsRange() {
        let levels = AudioLevels(input: 1.0, output: 0.0)
        XCTAssertTrue(levels.input >= 0.0 && levels.input <= 1.0)
        XCTAssertTrue(levels.output >= 0.0 && levels.output <= 1.0)
    }
}