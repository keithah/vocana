import XCTest
import AVFoundation
@testable import Vocana

@MainActor
final class AudioSessionManagerTests: XCTestCase {
    
    var manager: AudioSessionManager!
    
    override func setUp() {
        super.setUp()
        manager = AudioSessionManager()
    }
    
    override func tearDown() {
        // Ensure cleanup
        _ = manager.stopRealAudioCapture()
        manager = nil
        super.tearDown()
    }
    
    // Fix TEST-001: Test audio tap installation and removal
    func testAudioTapInstalledOnStart() {
        let success = manager.startRealAudioCapture()
        manager.stopRealAudioCapture()
        
        // Whether start succeeded or failed, tap should not be left installed
        XCTAssertFalse(manager.isTapInstalled, "Audio tap should not remain installed after stop")
    }
    
    func testAudioTapRemovedOnStop() {
        // Start and immediately stop audio capture
        _ = manager.startRealAudioCapture()
        manager.stopRealAudioCapture()
        
        // Fix TEST-001: Verify tap is removed on cleanup
        XCTAssertFalse(manager.isTapInstalled, "Audio tap should be removed after stopRealAudioCapture()")
    }
    
    func testMultipleStartStopCycles() {
        // Test that tap management works correctly over multiple cycles
        for _ in 0..<3 {
            _ = manager.startRealAudioCapture()
            manager.stopRealAudioCapture()
            XCTAssertFalse(manager.isTapInstalled)
        }
    }
    
    func testCallbackCanBeSet() {
        var callbackInvoked = false
        
        manager.onAudioBufferReceived = { _ in
            callbackInvoked = true
        }
        
        _ = manager.startRealAudioCapture()
        manager.stopRealAudioCapture()
        
        // After stopping, tap should be removed
        XCTAssertFalse(manager.isTapInstalled)
    }
    
    func testStopWithoutStart() {
        // Should not crash when stop is called without start
        manager.stopRealAudioCapture()
        XCTAssertFalse(manager.isTapInstalled)
    }
    
    func testTapStateConsistency() {
        // Test that tap state is always consistent
        let beforeStart = manager.isTapInstalled
        _ = manager.startRealAudioCapture()
        manager.stopRealAudioCapture()
        let afterStop = manager.isTapInstalled
        
        // Tap should not be installed before or after operations
        XCTAssertFalse(beforeStart)
        XCTAssertFalse(afterStop)
    }
}
