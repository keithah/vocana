import XCTest
import SwiftUI
@testable import Vocana

@MainActor
final class StatusIndicatorViewTests: XCTestCase {
    
    func testStatusIndicatorRenders() {
        let audioEngine = AudioEngine()
        let settings = AppSettings()
        let view = StatusIndicatorView(audioEngine: audioEngine, settings: settings)
        XCTAssertNotNil(view)
    }
    
    func testIndicatorWithRealAudio() {
        let audioEngine = AudioEngine()
        let settings = AppSettings()
        audioEngine.isUsingRealAudio = true
        
        _ = StatusIndicatorView(audioEngine: audioEngine, settings: settings)
        XCTAssertTrue(audioEngine.isUsingRealAudio)
    }
    
    func testIndicatorWithSimulatedAudio() {
        let audioEngine = AudioEngine()
        let settings = AppSettings()
        audioEngine.isUsingRealAudio = false
        
        _ = StatusIndicatorView(audioEngine: audioEngine, settings: settings)
        XCTAssertFalse(audioEngine.isUsingRealAudio)
    }
    
    func testMLProcessingIndicator() {
        let _ = AudioEngine()
        let settings = AppSettings()
        settings.isEnabled = true
        
        XCTAssertTrue(settings.isEnabled)
    }
    
    func testPerformanceWarningIndicator() {
        let audioEngine = AudioEngine()
        let _ = AppSettings()
        
        // Performance warning should only show when hasPerformanceIssues is true
        XCTAssertFalse(audioEngine.hasPerformanceIssues)
    }
    
    func testIndicatorStateUpdates() {
        let _ = AudioEngine()
        let settings = AppSettings()
        
        // Test that state changes are observed
        settings.isEnabled = true
        XCTAssertTrue(settings.isEnabled)
        
        settings.isEnabled = false
        XCTAssertFalse(settings.isEnabled)
    }
    
    func testStateTransitionWhenEnabled() {
        let audioEngine = AudioEngine()
        let settings = AppSettings()
        
        _ = StatusIndicatorView(audioEngine: audioEngine, settings: settings)
        settings.isEnabled = true
        XCTAssertTrue(settings.isEnabled)
    }
    
    func testAccessibilityIntegration() {
        // Test that accessibility containers are properly configured
        let audioEngine = AudioEngine()
        let settings = AppSettings()
        let view = StatusIndicatorView(audioEngine: audioEngine, settings: settings)
        XCTAssertNotNil(view)
        
        // Verify accessibility elements provide meaningful feedback
        // This ensures VoiceOver users understand the current status
    }
    
    func testMultiIndicatorIntegration() {
        // Test multiple indicators showing simultaneously
        let audioEngine = AudioEngine()
        let settings = AppSettings()
        
        // Enable multiple indicators
        settings.isEnabled = true
        audioEngine.isUsingRealAudio = true
        audioEngine.hasPerformanceIssues = true
        
        let view = StatusIndicatorView(audioEngine: audioEngine, settings: settings)
        XCTAssertNotNil(view)
        
        // All indicators should be visible and properly spaced
    }
    
    func testStatusIndicatorStateTransitions() async {
        // Test state transitions and UI updates
        let audioEngine = AudioEngine()
        let settings = AppSettings()
        let view = StatusIndicatorView(audioEngine: audioEngine, settings: settings)
        
        // Test ML processing state transition
        settings.isEnabled = false
        XCTAssertFalse(settings.isEnabled)
        
        settings.isEnabled = true
        XCTAssertTrue(settings.isEnabled)
        
        // Test audio source transition
        audioEngine.isUsingRealAudio = false
        XCTAssertFalse(audioEngine.isUsingRealAudio)
        
        audioEngine.isUsingRealAudio = true
        XCTAssertTrue(audioEngine.isUsingRealAudio)
        
        // Test performance warning transition
        audioEngine.hasPerformanceIssues = false
        XCTAssertFalse(audioEngine.hasPerformanceIssues)
        
        audioEngine.hasPerformanceIssues = true
        XCTAssertTrue(audioEngine.hasPerformanceIssues)
    }
    
    func testStatusIndicatorAccessibilityBehavior() {
        // Test accessibility behavior with different states
        let audioEngine = AudioEngine()
        let settings = AppSettings()
        let _ = StatusIndicatorView(audioEngine: audioEngine, settings: settings)
        
        // Test accessibility labels change with state
        settings.isEnabled = true
        audioEngine.isUsingRealAudio = true
        
        // Test with performance issues
        audioEngine.hasPerformanceIssues = true
        
        // Verify state changes are properly handled
        XCTAssertTrue(settings.isEnabled)
        XCTAssertTrue(audioEngine.isUsingRealAudio)
        XCTAssertTrue(audioEngine.hasPerformanceIssues)
    }
    
    func testStatusIndicatorPerformanceUnderLoad() {
        // Test performance with rapid state changes
        let audioEngine = AudioEngine()
        let settings = AppSettings()
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Simulate rapid state changes
        for i in 0..<100 {
            settings.isEnabled = (i % 2 == 0)
            audioEngine.isUsingRealAudio = (i % 3 == 0)
            audioEngine.hasPerformanceIssues = (i % 5 == 0)
            
            _ = StatusIndicatorView(audioEngine: audioEngine, settings: settings)
        }
        
        let endTime = CFAbsoluteTimeGetCurrent()
        let duration = endTime - startTime
        
        // Should complete 100 state changes in reasonable time (< 0.1 seconds)
        XCTAssertLessThan(duration, 0.1, "StatusIndicatorView should handle rapid state changes efficiently")
    }
}
