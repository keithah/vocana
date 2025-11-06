import XCTest
@testable import Vocana

@MainActor
final class AppSettingsTests: XCTestCase {
    var settings: AppSettings!
    
    override func setUp() {
        super.setUp()
        // Clean UserDefaults before each test to ensure isolation
        clearUserDefaults()
        settings = AppSettings()
    }
    
    override func tearDown() {
        // Clean up after each test
        clearUserDefaults()
        settings = nil
        super.tearDown()
    }
    
    private func clearUserDefaults() {
        let keys = ["isEnabled", "sensitivity", "launchAtLogin", "showInMenuBar"]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }
    
    func testDefaultValues() {
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.sensitivity, 0.5)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertTrue(settings.showInMenuBar)
    }
    
    func testIsEnabledPersistence() {
        settings.isEnabled = true
        let newSettings = AppSettings()
        XCTAssertTrue(newSettings.isEnabled)
        
        settings.isEnabled = false
        let anotherSettings = AppSettings()
        XCTAssertFalse(anotherSettings.isEnabled)
    }
    
    func testSensitivityPersistence() {
        settings.sensitivity = 0.8
        let newSettings = AppSettings()
        XCTAssertEqual(newSettings.sensitivity, 0.8)
        
        settings.sensitivity = 0.2
        let anotherSettings = AppSettings()
        XCTAssertEqual(anotherSettings.sensitivity, 0.2)
    }
    
    func testResetToDefaults() {
        settings.isEnabled = true
        settings.sensitivity = 0.9
        settings.launchAtLogin = true
        settings.showInMenuBar = false
        
        settings.resetToDefaults()
        
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.sensitivity, 0.5)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertTrue(settings.showInMenuBar)
    }
    
    func testSensitivityClamping() {
        // Test upper bound clamping
        settings.sensitivity = 1.5
        XCTAssertEqual(settings.sensitivity, 1.0, "Sensitivity should be clamped to 1.0")
        
        // Test lower bound clamping
        settings.sensitivity = -0.5
        XCTAssertEqual(settings.sensitivity, 0.0, "Sensitivity should be clamped to 0.0")
        
        // Test valid value is not clamped
        settings.sensitivity = 0.7
        XCTAssertEqual(settings.sensitivity, 0.7, "Valid sensitivity should not be modified")
    }
    
    func testSensitivityBoundaryValues() {
        // Test exact lower bound
        settings.sensitivity = 0.0
        XCTAssertEqual(settings.sensitivity, 0.0, "Sensitivity should accept 0.0")
        
        // Test exact upper bound
        settings.sensitivity = 1.0
        XCTAssertEqual(settings.sensitivity, 1.0, "Sensitivity should accept 1.0")
    }
    
    func testSensitivitySpecialValues() {
        // Test infinity
        settings.sensitivity = .infinity
        XCTAssertEqual(settings.sensitivity, 1.0, "Infinity should be clamped to 1.0")
        
        settings.sensitivity = -.infinity
        XCTAssertEqual(settings.sensitivity, 0.0, "Negative infinity should be clamped to 0.0")
        
        // Test NaN - Swift's min(1.0, NaN) = 1.0, then max(0.0, 1.0) = 1.0
        settings.sensitivity = .nan
        XCTAssertEqual(settings.sensitivity, 1.0, "NaN gets clamped to 1.0 due to min/max behavior with NaN")
    }
    
    func testClampedValuePersistence() {
        // Set out-of-bounds value
        settings.sensitivity = 1.5
        XCTAssertEqual(settings.sensitivity, 1.0, "Should clamp to 1.0")
        
        // Reload from UserDefaults
        let reloadedSettings = AppSettings()
        XCTAssertEqual(reloadedSettings.sensitivity, 1.0, "Clamped value should persist")
        
        // Test lower bound persistence
        settings.sensitivity = -0.5
        let anotherSettings = AppSettings()
        XCTAssertEqual(anotherSettings.sensitivity, 0.0, "Clamped 0.0 should persist")
    }
    
    func testInitWithCorruptedUserDefaults() {
        // Manually corrupt UserDefaults with out-of-range value
        UserDefaults.standard.set(99.0, forKey: "sensitivity")
        
        let corruptedSettings = AppSettings()
        XCTAssertEqual(corruptedSettings.sensitivity, 1.0, "Should clamp corrupted value to 1.0")
        
        // Verify it was written back
        let reloadedSettings = AppSettings()
        XCTAssertEqual(reloadedSettings.sensitivity, 1.0, "Corrected value should persist")
    }
}