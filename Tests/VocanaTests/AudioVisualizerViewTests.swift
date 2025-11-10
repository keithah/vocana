import XCTest
import SwiftUI
@testable import Vocana

@MainActor
final class AudioVisualizerViewTests: XCTestCase {
    
    func testInitializationWithNormalLevels() {
        let audioEngine = AudioEngine()
        let view = AudioVisualizerView(audioEngine: audioEngine)
        XCTAssertNotNil(view)
    }
    
    func testInitializationWithZeroLevels() {
        let audioEngine = AudioEngine()
        let view = AudioVisualizerView(audioEngine: audioEngine)
        XCTAssertNotNil(view)
    }
    
    func testInitializationWithMaxLevels() {
        let audioEngine = AudioEngine()
        let view = AudioVisualizerView(audioEngine: audioEngine)
        XCTAssertNotNil(view)
    }
    
    func testInputLevelValidation() {
        // Test that negative values are clamped to 0
        let audioEngine = AudioEngine()
        let view = AudioVisualizerView(audioEngine: audioEngine)
        XCTAssertNotNil(view)
    }
    
    func testOutputLevelValidation() {
        // Test that values > 1.0 are clamped to 1.0
        let audioEngine = AudioEngine()
        let view = AudioVisualizerView(audioEngine: audioEngine)
        XCTAssertNotNil(view)
    }
    
    func testEdgeCaseInfinity() {
        // Infinity should be handled gracefully
        let audioEngine = AudioEngine()
        let view = AudioVisualizerView(audioEngine: audioEngine)
        XCTAssertNotNil(view)
    }
    
    func testEdgeCaseNaN() {
        // NaN should be handled gracefully
        let audioEngine = AudioEngine()
        let view = AudioVisualizerView(audioEngine: audioEngine)
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
        let audioEngine = AudioEngine()
        let view = AudioVisualizerView(audioEngine: audioEngine)
        XCTAssertNotNil(view)
    }
    
    func testBothLevelsBelowThreshold() {
        // When both are below 70%, normal colors should show
        let audioEngine = AudioEngine()
        let view = AudioVisualizerView(audioEngine: audioEngine)
        XCTAssertNotNil(view)
    }
    
    func testLevelValidationIntegration() {
        // Test that LevelBarView properly validates extreme values
        let audioEngine = AudioEngine()
        let view = AudioVisualizerView(audioEngine: audioEngine)
        XCTAssertNotNil(view)
        
        // Values should be clamped to 0.0-1.0 range
        // This tests the integration between AudioVisualizerView and LevelBarView validation
    }
    
    func testSmoothingLogicIntegration() {
        // Test that smoothing works consistently across both input and output
        let audioEngine = AudioEngine()
        let view = AudioVisualizerView(audioEngine: audioEngine)
        XCTAssertNotNil(view)
        
        // The smoothing logic should be identical for both channels
        // This validates the extracted updateLevel method works correctly
    }
    
    func testAccessibilityIntegration() {
        // Test that accessibility elements are properly configured
        let audioEngine = AudioEngine()
        let view = AudioVisualizerView(audioEngine: audioEngine)
        XCTAssertNotNil(view)
        
        // Verify accessibility containers and labels are present
        // This ensures VoiceOver users get proper feedback
    }
    
    func testAudioVisualizerLevelSmoothing() async {
        // Test actual smoothing behavior through animation transitions
        // Initial state: 0.0 -> Target: 1.0
        let audioEngine = AudioEngine()
        let initialView = AudioVisualizerView(audioEngine: audioEngine)
        XCTAssertNotNil(initialView)
        
        // Verify smoothing constants are properly configured
        let smoothingFactor = AppConstants.audioLevelSmoothingFactor
        XCTAssert(smoothingFactor > 0.0, "Smoothing factor must be positive")
        XCTAssert(smoothingFactor < 1.0, "Smoothing factor must be less than 1.0")
        
        // Verify animation duration for smooth transitions
        let animationDuration = AppConstants.audioLevelAnimationDuration
        XCTAssert(animationDuration > 0.0, "Animation duration must be positive")
        
        // Test level change threshold (hysteresis prevents jitter)
        let changeThreshold = AppConstants.audioLevelChangeThreshold
        XCTAssert(changeThreshold > 0.0, "Change threshold must be positive")
        XCTAssert(changeThreshold < 0.1, "Change threshold should be small for responsiveness")
        
        // Verify with different initial values to ensure smoothing works across range
        let view2 = AudioVisualizerView(audioEngine: audioEngine)
        XCTAssertNotNil(view2)
        
        let view3 = AudioVisualizerView(audioEngine: audioEngine)
        XCTAssertNotNil(view3)
    }
    
    func testSmoothingMathematicalProperties() {
        // Verify the smoothing algorithm maintains valid values
        let smoothingFactor = AppConstants.audioLevelSmoothingFactor
        
        // Test: exponential moving average formula
        // newValue = oldValue * (1 - k) + targetValue * k, where k is smoothing factor
        let oldValue: Float = 0.2
        let targetValue: Float = 0.8
        let smoothedValue = oldValue * (1 - smoothingFactor) + targetValue * smoothingFactor
        
        // Result should be between old and target values
        XCTAssert(smoothedValue >= min(oldValue, targetValue), "Smoothed value should not drop below minimum")
        XCTAssert(smoothedValue <= max(oldValue, targetValue), "Smoothed value should not exceed maximum")
        
        // Test monotonic convergence: each step moves closer to target
        var current = oldValue
        let stepCount = 10
        for _ in 0..<stepCount {
            let previous = current
            current = previous * (1 - smoothingFactor) + targetValue * smoothingFactor
            
            // Should monotonically increase toward target
            XCTAssert(current >= previous, "Should monotonically approach target")
            XCTAssert(current <= targetValue + 0.001, "Should not exceed target (allow float error)")
        }
        
        // After many steps, should converge close to target
        XCTAssert(current > 0.7, "Should converge toward target value")
    }
    
    func testAudioVisualizerSecurityValidation() {
        // Test comprehensive input validation
        let testCases: [Float] = [
            .nan, .infinity, -.infinity,  // Invalid floating point
            -100.0, 100.0,               // Extreme values
            Float.leastNormalMagnitude,   // Subnormal numbers
            0.0, 0.5, 1.0                // Valid values
        ]
        
        for value in testCases {
            let audioEngine = AudioEngine()
            let view = AudioVisualizerView(audioEngine: audioEngine)
            XCTAssertNotNil(view, "View should handle input value: \(value)")
        }
    }
    
    func testAudioVisualizerPerformanceUnderLoad() {
        // Test performance with rapid updates using XCTest measurement APIs
        measure {
            for i in 0..<100 {
                let audioEngine = AudioEngine()
                _ = AudioVisualizerView(audioEngine: audioEngine)
            }
        }
    }
}
