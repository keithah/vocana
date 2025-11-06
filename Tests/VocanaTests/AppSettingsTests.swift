import XCTest
@testable import Vocana

final class AppSettingsTests: XCTestCase {
    var settings: AppSettings!
    
    override func setUp() {
        super.setUp()
        settings = AppSettings()
    }
    
    override func tearDown() {
        settings = nil
        super.tearDown()
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
}