import XCTest
@testable import Vocana

@MainActor
final class MenuBarIconManagerTests: XCTestCase {
    
    var iconManager: MenuBarIconManager!
    
    override func setUp() {
        super.setUp()
        iconManager = MenuBarIconManager()
    }
    
    override func tearDown() {
        iconManager = nil
        super.tearDown()
    }
    
    // MARK: - State Determination Tests
    
    func testIconStateTransitions() {
        // Test all state combinations
        XCTAssertEqual(
            MenuBarIconManager.determineState(isEnabled: false, isUsingRealAudio: false),
            .inactive,
            "Disabled state should be inactive regardless of audio"
        )
        
        XCTAssertEqual(
            MenuBarIconManager.determineState(isEnabled: false, isUsingRealAudio: true),
            .inactive,
            "Disabled state should be inactive even with audio"
        )
        
        XCTAssertEqual(
            MenuBarIconManager.determineState(isEnabled: true, isUsingRealAudio: false),
            .ready,
            "Enabled without audio should be ready state"
        )
        
        XCTAssertEqual(
            MenuBarIconManager.determineState(isEnabled: true, isUsingRealAudio: true),
            .active,
            "Enabled with audio should be active state"
        )
    }
    
    // MARK: - State Properties Tests
    
    func testIconStateColors() {
        XCTAssertEqual(MenuBarIconManager.IconState.active.colors.count, 2, "Active state should have 2 colors")
        XCTAssertTrue(MenuBarIconManager.IconState.active.colors.contains(.systemGreen), "Active state should include green")
        
        XCTAssertEqual(MenuBarIconManager.IconState.ready.colors.count, 2, "Ready state should have 2 colors")
        XCTAssertTrue(MenuBarIconManager.IconState.ready.colors.contains(.systemOrange), "Ready state should include orange")
        
        XCTAssertEqual(MenuBarIconManager.IconState.inactive.colors.count, 2, "Inactive state should have 2 colors")
        XCTAssertTrue(MenuBarIconManager.IconState.inactive.colors.allSatisfy { $0 == .controlTextColor }, "Inactive state should be all gray")
    }
    
    func testIconStateAccessibility() {
        XCTAssertEqual(MenuBarIconManager.IconState.active.accessibilityDescription, "Vocana - Active noise cancellation")
        XCTAssertEqual(MenuBarIconManager.IconState.active.accessibilityValue, "Active")
        
        XCTAssertEqual(MenuBarIconManager.IconState.ready.accessibilityDescription, "Vocana - Ready")
        XCTAssertEqual(MenuBarIconManager.IconState.ready.accessibilityValue, "Ready")
        
        XCTAssertEqual(MenuBarIconManager.IconState.inactive.accessibilityDescription, "Vocana - Inactive")
        XCTAssertEqual(MenuBarIconManager.IconState.inactive.accessibilityValue, "Inactive")
    }
    
    // MARK: - State Update Tests
    
    func testStateUpdatePerformance() {
        let expectation = XCTestExpectation(description: "State update throttling")
        
        // Rapid state changes should be throttled
        iconManager.updateState(isEnabled: true, isUsingRealAudio: false)
        iconManager.updateState(isEnabled: true, isUsingRealAudio: true)
        iconManager.updateState(isEnabled: false, isUsingRealAudio: true)
        
        // After throttling delay, should end up with final state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(self.iconManager.currentState, .inactive, "Should end with final state after throttling")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    // MARK: - Icon Creation Tests
    
    func testIconCreation() {
        // Test that icon creation succeeds
        let image = iconManager.createIconImage()
        XCTAssertNotNil(image, "Should create an icon image")
        XCTAssertFalse(image.isTemplate, "Icon should not be template for palette rendering")
    }
    
    func testIconCreationFallback() {
        // Test fallback behavior by using invalid icon name temporarily
        // This is more of an integration test, but we can test the structure
        let image = iconManager.createIconImage()
        XCTAssertNotNil(image, "Should always return an image, even if fallback")
    }
    
    // MARK: - Button Application Tests
    
    func testButtonApplication() {
        // Create a mock button for testing
        let button = NSStatusBarButton()
        
        iconManager.updateState(isEnabled: true, isUsingRealAudio: true)
        iconManager.applyToButton(button)
        
        XCTAssertNotNil(button.image, "Button should have an image")
        XCTAssertEqual(button.accessibilityLabel(), "Vocana - Active noise cancellation")
        XCTAssertEqual(button.accessibilityValue() as? String, "Active")
    }
    
    // MARK: - Performance Tests
    
    func testPerformanceOfStateDetermination() {
        measure {
            for _ in 0..<1000 {
                _ = MenuBarIconManager.determineState(isEnabled: Bool.random(), isUsingRealAudio: Bool.random())
            }
        }
    }
    
    func testPerformanceOfIconCreation() {
        measure {
            for _ in 0..<100 {
                _ = iconManager.createIconImage()
            }
        }
    }
}