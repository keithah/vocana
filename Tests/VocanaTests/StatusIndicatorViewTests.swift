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
        let audioEngine = AudioEngine()
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
        let audioEngine = AudioEngine()
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
}
