import Foundation
import AVFoundation
@testable import Vocana

/// Mock ML Audio Processor for testing
///
/// Simulates ML processing without actually running ONNX inference.
/// Used in test environments to avoid ONNX runtime dependencies and ensure reliable test execution.
@MainActor
final class MockMLAudioProcessor: MLAudioProcessorProtocol {
    
    // MARK: - Published Properties
    
    @Published var isMLProcessingActive = false
    @Published var processingLatencyMs: Double = 0
    @Published var memoryPressureLevel: MemoryPressureLevel = .normal
    
    // MARK: - Callbacks
    
    var recordFailure: () -> Void = {}
    var recordLatency: (Double) -> Void = { _ in }
    var recordSuccess: () -> Void = {}
    var onMLProcessingReady: () -> Void = {}
    
    // MARK: - State
    
    private var isEnabled = false
    private var initializationTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    init() {
        // Simulate ML initialization delay
        initializationTask = Task {
            // Simulate initialization time
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            
            await MainActor.run {
                self.isMLProcessingActive = true
                self.onMLProcessingReady()
            }
        }
    }
    
    // MARK: - MLAudioProcessorProtocol
    
    func initializeML() async {
        // Mock async initialization - activate ML processing
        isMLProcessingActive = true
        onMLProcessingReady()
    }
    
    func initializeMLProcessing() {
        // Mock initialization - activate ML processing
        isMLProcessingActive = true
        onMLProcessingReady()
    }
    
    func stopMLProcessing() {
        isMLProcessingActive = false
    }
    
    func suspendMLProcessing(reason: String) {
        isMLProcessingActive = false
    }
    
    func processAudioWithML(chunk: [Float], sensitivity: Double) -> [Float]? {
        guard isMLProcessingActive else { return nil }

        // Simulate processing latency (very fast for mock)
        let latencyMs = Double.random(in: 0.1...0.3)
        processingLatencyMs = latencyMs
        recordLatency(latencyMs)
        recordSuccess()

        // Return the input buffer unchanged (mock processing)
        return chunk
    }

    func processAudioBuffer(_ buffer: [Float], sampleRate: Float) async throws -> [Float] {
        guard isMLProcessingActive else {
            throw NSError(domain: "MockMLAudioProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "ML processing not active"])
        }

        // Simulate processing latency
        let latencyMs = Double.random(in: 0.1...0.3)
        processingLatencyMs = latencyMs
        recordLatency(latencyMs)
        recordSuccess()

        // Return the input buffer unchanged (mock processing)
        return buffer
    }
    
    func activateML() async -> Bool {
        return true
    }
    
    func deactivateML() async {
        isMLProcessingActive = false
    }
    
    func isMemoryPressureSuspended() -> Bool {
        return false
    }
    
    func cleanup() async {
        initializationTask?.cancel()
        isMLProcessingActive = false
    }
    
    // MARK: - Memory Pressure
    
    func setMemoryPressureLevel(_ level: MemoryPressureLevel) {
        memoryPressureLevel = level
    }

    func attemptMemoryPressureRecovery() {
        // Mock recovery - just set to normal
        memoryPressureLevel = .normal
    }
    
    // MARK: - Test Helpers
    
    /// Simulate ML processing failure for testing error scenarios
    func simulateFailure() {
        recordFailure()
        isMLProcessingActive = false
    }
    
    /// Simulate memory pressure for testing memory management
    func simulateMemoryPressure() {
        memoryPressureLevel = .urgent
    }
    
    // MARK: - Memory Tracking (Mock Implementation)
    
    /// Mock ML model memory usage in MB
    var mlMemoryUsageMB: Double {
        return 0.0 // Mock uses no real memory
    }
    
    /// Mock peak ML model memory usage in MB
    var mlPeakMemoryUsageMB: Double {
        return 0.0 // Mock uses no real memory
    }
    
    /// Mock memory used during model loading in MB
    var mlModelLoadMemoryMB: Double {
        return 0.0 // Mock uses no real memory
    }
    
    /// Get mock ML memory statistics
    func getMLMemoryStatistics() -> (current: Double, peak: Double, modelLoad: Double, totalInferences: UInt64) {
        return (current: 0.0, peak: 0.0, modelLoad: 0.0, totalInferences: 0)
    }
}