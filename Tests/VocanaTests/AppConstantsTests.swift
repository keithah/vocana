import XCTest
@testable import Vocana

final class AppConstantsTests: XCTestCase {
    
    func testConstantsValues() {
        XCTAssertEqual(AppConstants.popoverWidth, 300.0)
        XCTAssertEqual(AppConstants.popoverHeight, 400.0)
        XCTAssertEqual(AppConstants.progressBarHeight, 4.0)
        XCTAssertEqual(AppConstants.cornerRadius, 2.0)
        XCTAssertEqual(AppConstants.audioUpdateInterval, 0.1)
        XCTAssertEqual(AppConstants.sensitivityRange.lowerBound, 0.0)
        XCTAssertEqual(AppConstants.sensitivityRange.upperBound, 1.0)
    }
    
    func testColors() {
        XCTAssertNotNil(AppConstants.Colors.inputLevel)
        XCTAssertNotNil(AppConstants.Colors.outputLevel)
        XCTAssertEqual(AppConstants.Colors.backgroundOpacity, 0.3)
    }
    
    func testFonts() {
        XCTAssertNotNil(AppConstants.Fonts.title)
        XCTAssertNotNil(AppConstants.Fonts.headline)
        XCTAssertNotNil(AppConstants.Fonts.subheadline)
        XCTAssertNotNil(AppConstants.Fonts.caption)
    }
}