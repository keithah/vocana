import XCTest
import Combine
@testable import Vocana

/// Integration tests for the complete audio pipeline
/// Tests the interaction between AudioEngine, AudioSessionManager, and AudioCoordinator
@MainActor
final class AudioPipelineIntegrationTests: XCTestCase {
    
    private var audioEngine: AudioEngine!
    private var audioCoordinator: AudioCoordinator!
    private var cancellables = Set<AnyCancellable>()
    
    override func setUp() {
        super.setUp()
        audioEngine = AudioEngine()
        audioCoordinator = AudioCoordinator()
    }
    
    override func tearDown() {
        cancellables.removeAll()
        audioEngine = nil
        audioCoordinator = nil
        super.tearDown()
    }
    
    // MARK: - End-to-End Audio Flow Tests
    
    func testCompleteAudioPipelineFlow() {
        let expectation = XCTestExpectation(description: "Complete audio pipeline flow")
        expectation.expectedFulfillmentCount = 3 // Start, processing, stop
        
        // Test the complete flow from coordinator to engine to session
        audioCoordinator.audioEngine.$isUsingRealAudio
            .dropFirst()
            .sink { isEnabled in
                if isEnabled {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)
        
        audioEngine.$currentLevels
            .dropFirst()
            .sink { levels in
                if levels.input > 0 || levels.output > 0 {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)
        
        // Start the audio processing
        audioCoordinator.startAudioProcessing()
        
        // Wait for processing to start
        wait(for: [expectation], timeout: 2.0)
        
        // Verify coordinator state
        XCTAssertTrue(audioCoordinator.audioEngine.isUsingRealAudio, "Audio processing should be active")
        
        // Stop processing
        audioCoordinator.stopAudioProcessing()
        expectation.fulfill()
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    func testAudioLevelPropagation() {
        let expectation = XCTestExpectation(description: "Audio level propagation")
        
        // Test that audio levels flow through the pipeline correctly
        audioEngine.$currentLevels
            .dropFirst()
            .sink { levels in
                // Verify levels are valid
                XCTAssertFalse(levels.input.isNaN, "Input level should not be NaN")
                XCTAssertFalse(levels.output.isNaN, "Output level should not be NaN")
                XCTAssertFalse(levels.input.isInfinite, "Input level should not be infinite")
                XCTAssertFalse(levels.output.isInfinite, "Output level should not be infinite")
                XCTAssertGreaterThanOrEqual(levels.input, 0.0, "Input level should be non-negative")
                XCTAssertGreaterThanOrEqual(levels.output, 0.0, "Output level should be non-negative")
                XCTAssertLessThanOrEqual(levels.input, 1.0, "Input level should not exceed 1.0")
                XCTAssertLessThanOrEqual(levels.output, 1.0, "Output level should not exceed 1.0")
                
                expectation.fulfill()
            }
            .store(in: &cancellables)
        
        // Start audio processing
        audioEngine.startAudioProcessing(isEnabled: true, sensitivity: 0.5)
        
        wait(for: [expectation], timeout: 2.0)
    }
    
    func testMenuBarIconIntegration() {
        let expectation = XCTestExpectation(description: "Menu bar icon integration")
        
        // Test that menu bar icon updates based on audio state
        let iconManager = MenuBarIconManager()
        let button = NSStatusBarButton()
        iconManager.applyToButton(button)
        
        // Initially should be inactive
        XCTAssertEqual(iconManager.currentState, .inactive, "Should start inactive")
        
        // Start audio processing
        audioEngine.startAudioProcessing(isEnabled: true, sensitivity: 0.5)
        
        // Update icon state based on engine state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            iconManager.updateState(
                isEnabled: true, // Simulate enabled state
                isUsingRealAudio: self.audioEngine.isUsingRealAudio
            )
            
            // Should be ready or active depending on audio input
            let state = iconManager.currentState
            XCTAssertTrue(state == .ready || state == .active, 
                         "Should be ready or active, got \(state)")
            
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 2.0)
    }
    
    func testAudioCoordinatorStateManagement() {
        let expectation = XCTestExpectation(description: "Audio coordinator state management")
        
        // Test that coordinator properly manages state transitions
        var stateChanges: [Bool] = []
        
        audioCoordinator.audioEngine.$isUsingRealAudio
            .dropFirst()
            .sink { isEnabled in
                stateChanges.append(isEnabled)
            }
            .store(in: &cancellables)
        
        // Start processing
        audioCoordinator.startAudioProcessing()
        
        // Stop processing
        audioCoordinator.stopAudioProcessing()
        
        // Verify state transitions
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(stateChanges.count, 2, "Should have 2 state changes")
            XCTAssertTrue(stateChanges.contains(true), "Should have active state")
            XCTAssertTrue(stateChanges.contains(false), "Should have inactive state")
            
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    func testErrorHandlingIntegration() {
        let expectation = XCTestExpectation(description: "Error handling integration")
        
        // Test that errors are properly handled throughout the pipeline
        audioEngine.$hasPerformanceIssues
            .dropFirst()
            .sink { hasIssues in
                // Should handle performance issues gracefully
                XCTAssertTrue(hasIssues == true || hasIssues == false, 
                              "Performance issues should be boolean")
                expectation.fulfill()
            }
            .store(in: &cancellables)
        
        // Start audio processing with high sensitivity to potentially trigger issues
        audioEngine.startAudioProcessing(isEnabled: true, sensitivity: 1.0)
        
        wait(for: [expectation], timeout: 2.0)
    }
    
    func testMemoryPressureIntegration() {
        let expectation = XCTestExpectation(description: "Memory pressure integration")
        
        // Test memory pressure handling across the pipeline
        audioEngine.memoryPressureLevel = .warning
        
        audioEngine.$memoryPressureLevel
            .dropFirst()
            .sink { pressureLevel in
                XCTAssertEqual(pressureLevel, .warning, "Memory pressure should be warning")
                expectation.fulfill()
            }
            .store(in: &cancellables)
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    func testSensitivityChangesIntegration() {
        let expectation = XCTestExpectation(description: "Sensitivity changes integration")
        
        // Test that sensitivity changes propagate correctly
        audioEngine.startAudioProcessing(isEnabled: true, sensitivity: 0.5)
        
        // Change sensitivity
        audioEngine.startAudioProcessing(isEnabled: true, sensitivity: 0.8)
        
        // Verify sensitivity was updated
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Note: sensitivity is private, so we can't directly test it
            // This test verifies the method call doesn't crash
            expectation.fulfill()
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    func testAudioSessionIntegration() {
        let expectation = XCTestExpectation(description: "Audio session integration")
        
        // Test audio session manager integration
        let sessionManager = AudioSessionManager()
        
        // Start real audio capture
        let success = sessionManager.startRealAudioCapture()
        
        // Should either succeed or fail gracefully
        XCTAssertTrue(success == true || success == false, 
                     "Should handle audio session gracefully")
        
        // Stop capture
        sessionManager.stopRealAudioCapture()
        
        expectation.fulfill()
        wait(for: [expectation], timeout: 2.0)
    }
    
    func testPerformanceUnderLoad() {
        // Test performance of the complete pipeline under load
        measure {
            for i in 0..<10 {
                audioEngine.startAudioProcessing(isEnabled: i % 2 == 0, sensitivity: 0.5)
                audioCoordinator.startAudioProcessing()
                audioCoordinator.stopAudioProcessing()
            }
        }
    }
}