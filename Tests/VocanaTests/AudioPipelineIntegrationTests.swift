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
        let mockMLProcessor = MockMLAudioProcessor()
        audioEngine = AudioEngine(mlProcessor: mockMLProcessor)
        audioCoordinator = AudioCoordinator(audioEngine: audioEngine)
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
        XCTAssertTrue(audioCoordinator.isProcessing, "Coordinator should indicate processing is active")

        // Stop processing
        audioCoordinator.stopAudioProcessing()
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
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)

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
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)

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
        // Test that coordinator properly manages state transitions
        XCTAssertFalse(audioCoordinator.isProcessing, "Should start as false")

        // Start processing
        audioCoordinator.startAudioProcessing()
        XCTAssertTrue(audioCoordinator.isProcessing, "Should be true after starting")

        // Stop processing
        audioCoordinator.stopAudioProcessing()
        XCTAssertFalse(audioCoordinator.isProcessing, "Should be false after stopping")
    }
}