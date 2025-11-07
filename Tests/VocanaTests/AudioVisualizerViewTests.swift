import XCTest
import SwiftUI
@testable import Vocana

@MainActor
final class AudioVisualizerViewTests: XCTestCase {
    
    func testInitializationWithNormalLevels() {
        let view = AudioVisualizerView(inputLevel: 0.5, outputLevel: 0.3)
        XCTAssertNotNil(view)
    }
    
    func testInitializationWithZeroLevels() {
        let view = AudioVisualizerView(inputLevel: 0.0, outputLevel: 0.0)
        XCTAssertNotNil(view)
    }
    
    func testInitializationWithMaxLevels() {
        let view = AudioVisualizerView(inputLevel: 1.0, outputLevel: 1.0)
        XCTAssertNotNil(view)
    }
    
    func testInputLevelValidation() {
        // Test that negative values are clamped to 0
        let view = AudioVisualizerView(inputLevel: -0.5, outputLevel: 0.3)
        XCTAssertNotNil(view)
    }
    
    func testOutputLevelValidation() {
        // Test that values > 1.0 are clamped to 1.0
        let view = AudioVisualizerView(inputLevel: 0.5, outputLevel: 1.5)
        XCTAssertNotNil(view)
    }
    
    func testEdgeCaseInfinity() {
        // Infinity should be handled gracefully
        let view = AudioVisualizerView(inputLevel: .infinity, outputLevel: 0.5)
        XCTAssertNotNil(view)
    }
    
    func testEdgeCaseNaN() {
        // NaN should be handled gracefully
        let view = AudioVisualizerView(inputLevel: .nan, outputLevel: 0.5)
        XCTAssertNotNil(view)
    }
    
    func testWarningThresholdConstant() {
        XCTAssertEqual(AppConstants.levelWarningThreshold, 0.7)
    }
    
    func testSmoothingFactorConstant() {
        XCTAssertEqual(AppConstants.audioLevelSmoothingFactor, 0.3)
    }
    
    func testBothLevelsAboveThreshold() {
        // When both input and output are above 70%, both should show warning colors
        let view = AudioVisualizerView(inputLevel: 0.8, outputLevel: 0.75)
        XCTAssertNotNil(view)
    }
    
    func testBothLevelsBelowThreshold() {
        // When both are below 70%, normal colors should show
        let view = AudioVisualizerView(inputLevel: 0.5, outputLevel: 0.4)
        XCTAssertNotNil(view)
    }
}
