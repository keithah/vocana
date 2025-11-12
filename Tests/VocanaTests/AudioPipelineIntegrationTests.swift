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

        // Test that settings enable triggers processing
        audioCoordinator.$isProcessing
            .dropFirst()
            .sink { isProcessing in
                if isProcessing {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        // Enable audio processing in settings first
        audioCoordinator.settings.isEnabled = true

        // Wait for processing to start
        wait(for: [expectation], timeout: 2.0)

        // Verify coordinator state
        XCTAssertTrue(audioCoordinator.isProcessing, "Coordinator should indicate processing is active")

        // Stop processing
        audioCoordinator.stopAudioProcessing()
        XCTAssertFalse(audioCoordinator.isProcessing, "Coordinator should indicate processing stopped")
    }

    func testAudioLevelPropagation() {
        // Test that audio levels start valid and remain valid during processing
        let initialLevels = audioEngine.currentLevels
        XCTAssertFalse(initialLevels.input.isNaN, "Initial input level should not be NaN")
        XCTAssertFalse(initialLevels.output.isNaN, "Initial output level should not be NaN")
        XCTAssertGreaterThanOrEqual(initialLevels.input, 0.0, "Initial input level should be non-negative")
        XCTAssertGreaterThanOrEqual(initialLevels.output, 0.0, "Initial output level should be non-negative")

        // Start audio processing
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)

        // Levels should remain valid (may stay 0.0 in test environment)
        let processingLevels = audioEngine.currentLevels
        XCTAssertFalse(processingLevels.input.isNaN, "Processing input level should not be NaN")
        XCTAssertFalse(processingLevels.output.isNaN, "Processing output level should not be NaN")
        XCTAssertGreaterThanOrEqual(processingLevels.input, 0.0, "Processing input level should be non-negative")
        XCTAssertGreaterThanOrEqual(processingLevels.output, 0.0, "Processing output level should be non-negative")
        XCTAssertLessThanOrEqual(processingLevels.input, 1.0, "Processing input level should not exceed 1.0")
        XCTAssertLessThanOrEqual(processingLevels.output, 1.0, "Processing output level should not exceed 1.0")
    }

    func testMenuBarIconIntegration() {
        // Test that menu bar icon updates based on audio state
        let iconManager = MenuBarIconManager()
        let button = NSStatusBarButton()
        iconManager.applyToButton(button)

        // Initially should be inactive
        XCTAssertEqual(iconManager.currentState, .inactive, "Should start inactive")

        // Start audio processing
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)

        // Update icon state based on engine state
        iconManager.updateState(
            isEnabled: true, // Simulate enabled state
            isUsingRealAudio: self.audioEngine.isUsingRealAudio
        )

        // Wait for throttler to execute
        let expectation = XCTestExpectation(description: "Icon state update")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let state = iconManager.currentState
            XCTAssertEqual(state, .ready, "Should be ready when enabled but no real audio, got \(state)")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 0.5)
    }

    func testAudioCoordinatorStateManagement() {
        // Reset settings to ensure clean state
        audioCoordinator.settings.isEnabled = false

        // Test that coordinator properly manages state transitions
        XCTAssertFalse(audioCoordinator.isProcessing, "Should start as false")

        // Enable settings and start processing
        audioCoordinator.settings.isEnabled = true
        audioCoordinator.startAudioProcessing()
        XCTAssertTrue(audioCoordinator.isProcessing, "Should be true after starting")

        // Stop processing
        audioCoordinator.stopAudioProcessing()
        XCTAssertFalse(audioCoordinator.isProcessing, "Should be false after stopping")
    }
}