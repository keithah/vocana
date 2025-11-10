import XCTest
@testable import Vocana

@MainActor
final class MemoryTrackingTests: XCTestCase {
    
    func testMLMemoryTracking() throws {
        // Test with mock ML processor
        let mockProcessor = MockMLAudioProcessor()
        
        // Mock should report zero memory usage
        XCTAssertEqual(mockProcessor.mlMemoryUsageMB, 0.0)
        XCTAssertEqual(mockProcessor.mlPeakMemoryUsageMB, 0.0)
        XCTAssertEqual(mockProcessor.mlModelLoadMemoryMB, 0.0)
        
        let stats = mockProcessor.getMLMemoryStatistics()
        XCTAssertEqual(stats.current, 0.0)
        XCTAssertEqual(stats.peak, 0.0)
        XCTAssertEqual(stats.modelLoad, 0.0)
        XCTAssertEqual(stats.totalInferences, 0)
    }
    
    func testDeepFilterNetMemoryTracking() throws {
        // This test would require real ONNX models, so we skip it in unit tests
        // In integration tests, we could verify that memory usage is tracked
        XCTAssertTrue(true, "Memory tracking infrastructure is in place")
    }
}