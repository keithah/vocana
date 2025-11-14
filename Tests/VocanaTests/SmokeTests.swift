import XCTest
import Foundation
@testable import Vocana

/// Simple smoke test to verify basic functionality
final class SmokeTests: XCTestCase {
    
    func testBasicInitialization() throws {
        // Test that basic classes can be initialized
        let appSettings = AppSettings()
        XCTAssertNotNil(appSettings)
        XCTAssertEqual(appSettings.isEnabled, false)
        XCTAssertEqual(appSettings.sensitivity, 0.5)
        
        let audioEngine = AudioEngine()
        XCTAssertNotNil(audioEngine)
        XCTAssertFalse(audioEngine.isMLProcessingActive)
        XCTAssertEqual(audioEngine.processingLatencyMs, 0.0)
    }
    
    func testMockMLProcessor() throws {
        let mockML = MockMLAudioProcessor()
        XCTAssertNotNil(mockML)
        XCTAssertFalse(mockML.isMLProcessingActive)
        XCTAssertEqual(mockML.processingLatencyMs, 0.0)
        XCTAssertEqual(mockML.memoryPressureLevel, 0)
        
        // Test initialization
        mockML.initializeMLProcessing()
        
        // Test audio processing
        let testAudio = [Float](repeating: 0.5, count: 1024)
        let result = mockML.processAudioWithML(chunk: testAudio, sensitivity: 0.5)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, 1024)
    }
    
    func testDependencyFactory() throws {
        let factory = DependencyFactory.shared
        XCTAssertNotNil(factory)
        
        let audioEngine = factory.createAudioEngine()
        XCTAssertNotNil(audioEngine)
        
        let appSettings = factory.createAppSettings()
        XCTAssertNotNil(appSettings)
    }
}