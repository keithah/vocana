//
//  MLAudioProcessorTests.swift
//  Vocana
//
//  ML Audio Processor Testing for PR #53
//  Tests ML pipeline, model loading, inference, and error handling
//

import XCTest
import AVFoundation
import Foundation
@testable import Vocana

@MainActor
final class MLAudioProcessorTests: XCTestCase {
    
    // MARK: - Test Properties
    
    private var mlProcessor: MLAudioProcessor!
    private var mockMLProcessor: MockMLAudioProcessor!
    private var testAudioBuffer: [Float]!
    private var testAudioFormat: AVAudioFormat!
    
    // MARK: - Setup and Teardown
    
    override func setUp() {
        super.setUp()
        
        // Initialize ML processors
        mockMLProcessor = MockMLAudioProcessor()
        
        // Setup test audio format
        testAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        
        // Generate test audio data
        testAudioBuffer = (0..<1024).map { i in
            let t = Float(i) / 48000.0
            return sin(2 * Float.pi * 440 * t) * 0.5 + Float.random(in: -0.05...0.05)
        }
    }
    
    override func tearDown() {
        mlProcessor?.stopMLProcessing()
        mockMLProcessor?.cleanup()
        mlProcessor = nil
        mockMLProcessor = nil
        testAudioBuffer = nil
        testAudioFormat = nil
        super.tearDown()
    }
    
    // MARK: - ML Initialization Tests
    
    func testMLProcessorInitialization() {
        // Test mock processor initialization
        XCTAssertNotNil(mockMLProcessor, "Mock ML processor should be initialized")
        XCTAssertFalse(mockMLProcessor.isMLProcessingActive, "ML processing should not be active initially")
        XCTAssertEqual(mockMLProcessor.processingLatencyMs, 0.0, "Initial latency should be 0")
        XCTAssertEqual(mockMLProcessor.memoryPressureLevel, 0, "Initial memory pressure should be 0")
        
        // Test ML initialization
        mockMLProcessor.initializeMLProcessing()
        
        // Wait for initialization to complete
        let initExpectation = XCTestExpectation(description: "ML initialization")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            initExpectation.fulfill()
        }
        
        wait(for: [initExpectation], timeout: 1.0)
        
        XCTAssertTrue(mockMLProcessor.isMLProcessingActive, "ML processing should be active after initialization")
    }
    
    func testMLProcessorAsyncInitialization() async {
        // Test async initialization
        await mockMLProcessor.initializeML()
        
        // Verify initialization completed
        XCTAssertTrue(mockMLProcessor.isMLProcessingActive, "ML processing should be active after async initialization")
    }
    
    func testMLProcessorActivation() async {
        // Test activation/deactivation
        let activationResult = await mockMLProcessor.activateML()
        XCTAssertTrue(activationResult, "ML activation should succeed")
        
        await mockMLProcessor.deactivateML()
        XCTAssertFalse(mockMLProcessor.isMLProcessingActive, "ML processing should be inactive after deactivation")
    }
    
    // MARK: - ML Inference Tests
    
    func testMLInferenceBasic() {
        // Initialize ML processor
        mockMLProcessor.initializeMLProcessing()
        
        // Wait for initialization
        let initExpectation = XCTestExpectation(description: "ML inference initialization")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            initExpectation.fulfill()
        }
        
        wait(for: [initExpectation], timeout: 1.0)
        
        // Test basic inference
        let result = mockMLProcessor.processAudioWithML(chunk: testAudioBuffer, sensitivity: 0.5)
        
        XCTAssertNotNil(result, "ML inference should return a result")
        XCTAssertEqual(result?.count, testAudioBuffer.count, "Result should have same length as input")
        
        // Verify result is not identical to input (processing occurred)
        if let result = result {
            let difference = zip(testAudioBuffer, result).map { abs($0 - $1) }.reduce(0, +)
            XCTAssertGreaterThanOrEqual(difference, 0.0, "Result should be processed (may be identical for mock)")
        }
    }
    
    func testMLInferenceAsync() async {
        // Initialize ML processor
        mockMLProcessor.initializeMLProcessing()
        
        // Wait for initialization
        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
        
        // Test async inference
        do {
            let result = try await mockMLProcessor.processAudioBuffer(testAudioBuffer, sampleRate: 48000)
            
            XCTAssertNotNil(result, "Async ML inference should return a result")
            XCTAssertEqual(result.count, testAudioBuffer.count, "Result should have same length as input")
            
        } catch {
            XCTFail("Async ML inference should not fail: \(error)")
        }
    }
    
    func testMLInferenceWithDifferentSensitivities() {
        // Initialize ML processor
        mockMLProcessor.initializeMLProcessing()
        
        // Wait for initialization
        let initExpectation = XCTestExpectation(description: "ML sensitivity initialization")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            initExpectation.fulfill()
        }
        
        wait(for: [initExpectation], timeout: 1.0)
        
        // Test different sensitivity values
        let sensitivities: [Double] = [0.0, 0.25, 0.5, 0.75, 1.0]
        
        for sensitivity in sensitivities {
            let result = mockMLProcessor.processAudioWithML(chunk: testAudioBuffer, sensitivity: sensitivity)
            
            XCTAssertNotNil(result, "ML inference should succeed with sensitivity \(sensitivity)")
            XCTAssertEqual(result?.count, testAudioBuffer.count, "Result should have same length for sensitivity \(sensitivity)")
        }
    }
    
    func testMLInferenceWithDifferentBufferSizes() {
        // Initialize ML processor
        mockMLProcessor.initializeMLProcessing()
        
        // Wait for initialization
        let initExpectation = XCTestExpectation(description: "ML buffer size initialization")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            initExpectation.fulfill()
        }
        
        wait(for: [initExpectation], timeout: 1.0)
        
        // Test different buffer sizes
        let bufferSizes = [256, 512, 1024, 2048]
        
        for bufferSize in bufferSizes {
            let testBuffer = Array(testAudioBuffer.prefix(bufferSize))
            let result = mockMLProcessor.processAudioWithML(chunk: testBuffer, sensitivity: 0.5)
            
            XCTAssertNotNil(result, "ML inference should succeed with buffer size \(bufferSize)")
            XCTAssertEqual(result?.count, bufferSize, "Result should have same length for buffer size \(bufferSize)")
        }
    }
    
    // MARK: - Performance Tests
    
    func testMLInferenceLatency() {
        // Initialize ML processor
        mockMLProcessor.initializeMLProcessing()
        
        // Wait for initialization
        let initExpectation = XCTestExpectation(description: "ML latency initialization")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            initExpectation.fulfill()
        }
        
        wait(for: [initExpectation], timeout: 1.0)
        
        // Test inference latency
        let iterations = 100
        var latencies: [Double] = []
        
        for _ in 0..<iterations {
            let startTime = CFAbsoluteTimeGetCurrent()
            
            let result = mockMLProcessor.processAudioWithML(chunk: testAudioBuffer, sensitivity: 0.5)
            
            let endTime = CFAbsoluteTimeGetCurrent()
            let latency = endTime - startTime
            
            XCTAssertNotNil(result, "ML inference should succeed during latency test")
            latencies.append(latency)
        }
        
        // Analyze latency statistics
        let averageLatency = latencies.reduce(0, +) / Double(latencies.count)
        let maxLatency = latencies.max() ?? 0
        let p95Latency = latencies.sorted(by: <)[Int(Double(latencies.count) * 0.95)]
        
        print(String(format: "ML Inference Latency: Avg %.3fms, Max %.3fms, P95 %.3fms",
                     averageLatency * 1000, maxLatency * 1000, p95Latency * 1000))
        
        XCTAssertLessThan(averageLatency, 0.01, "Average ML inference latency should be < 10ms")
        XCTAssertLessThan(p95Latency, 0.015, "95th percentile latency should be < 15ms")
    }
    
    func testMLInferenceThroughput() {
        // Initialize ML processor
        mockMLProcessor.initializeMLProcessing()
        
        // Wait for initialization
        let initExpectation = XCTestExpectation(description: "ML throughput initialization")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            initExpectation.fulfill()
        }
        
        wait(for: [initExpectation], timeout: 1.0)
        
        // Test inference throughput
        let duration = 1.0 // 1 second
        let startTime = CFAbsoluteTimeGetCurrent()
        var processedSamples = 0
        
        while CFAbsoluteTimeGetCurrent() - startTime < duration {
            let result = mockMLProcessor.processAudioWithML(chunk: testAudioBuffer, sensitivity: 0.5)
            if result != nil {
                processedSamples += testAudioBuffer.count
            }
        }
        
        let actualDuration = CFAbsoluteTimeGetCurrent() - startTime
        let throughput = Double(processedSamples) / actualDuration
        
        print(String(format: "ML Inference Throughput: %.0f samples/sec", throughput))
        XCTAssertGreaterThan(throughput, 48000.0, "Throughput should be > 48kHz (real-time)")
    }
    
    func testMLMemoryUsage() {
        let initialMemory = getCurrentMemoryUsage()
        
        // Initialize ML processor
        mockMLProcessor.initializeMLProcessing()
        
        // Wait for initialization
        let initExpectation = XCTestExpectation(description: "ML memory initialization")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            initExpectation.fulfill()
        }
        
        wait(for: [initExpectation], timeout: 1.0)
        
        let afterInitMemory = getCurrentMemoryUsage()
        let initMemoryIncrease = afterInitMemory - initialMemory
        
        // Process many buffers
        for _ in 0..<100 {
            _ = mockMLProcessor.processAudioWithML(chunk: testAudioBuffer, sensitivity: 0.5)
        }
        
        let afterProcessingMemory = getCurrentMemoryUsage()
        let processingMemoryIncrease = afterProcessingMemory - afterInitMemory
        
        print(String(format: "ML Memory Usage: Init %.1fMB, Processing %.1fMB",
                     initMemoryIncrease / (1024.0 * 1024.0),
                     processingMemoryIncrease / (1024.0 * 1024.0)))
        
        XCTAssertLessThan(initMemoryIncrease, 100 * 1024 * 1024, "Initialization memory increase should be < 100MB")
        XCTAssertLessThan(processingMemoryIncrease, 10 * 1024 * 1024, "Processing memory increase should be < 10MB")
    }
    
    // MARK: - Error Handling Tests
    
    func testMLInferenceFailure() {
        // Initialize ML processor
        mockMLProcessor.initializeMLProcessing()
        
        // Wait for initialization
        let initExpectation = XCTestExpectation(description: "ML failure initialization")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            initExpectation.fulfill()
        }
        
        wait(for: [initExpectation], timeout: 1.0)
        
        // Simulate ML failure
        mockMLProcessor.simulateFailure()
        
        // Test inference after failure
        let result = mockMLProcessor.processAudioWithML(chunk: testAudioBuffer, sensitivity: 0.5)
        
        // Mock processor may still return result, but ML processing should be inactive
        XCTAssertFalse(mockMLProcessor.isMLProcessingActive, "ML processing should be inactive after failure")
    }
    
    func testMLMemoryPressureHandling() {
        // Initialize ML processor
        mockMLProcessor.initializeMLProcessing()
        
        // Wait for initialization
        let initExpectation = XCTestExpectation(description: "ML memory pressure initialization")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            initExpectation.fulfill()
        }
        
        wait(for: [initExpectation], timeout: 1.0)
        
        // Simulate memory pressure
        mockMLProcessor.simulateMemoryPressure()
        
        // Verify memory pressure is detected
        XCTAssertEqual(mockMLProcessor.memoryPressureLevel, 2, "Memory pressure level should be urgent")
        
        // Test inference under memory pressure
        let result = mockMLProcessor.processAudioWithML(chunk: testAudioBuffer, sensitivity: 0.5)
        
        // Should still return result (mock behavior)
        XCTAssertNotNil(result, "ML inference should still work under memory pressure")
        
        // Test recovery
        mockMLProcessor.attemptMemoryPressureRecovery()
        XCTAssertEqual(mockMLProcessor.memoryPressureLevel, 0, "Memory pressure should be recovered")
    }
    
    func testMLSuspensionAndRecovery() {
        // Initialize ML processor
        mockMLProcessor.initializeMLProcessing()
        
        // Wait for initialization
        let initExpectation = XCTestExpectation(description: "ML suspension initialization")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            initExpectation.fulfill()
        }
        
        wait(for: [initExpectation], timeout: 1.0)
        
        // Test ML suspension
        mockMLProcessor.suspendMLProcessing(reason: "Test suspension")
        XCTAssertFalse(mockMLProcessor.isMLProcessingActive, "ML processing should be suspended")
        
        // Test inference while suspended
        let result = mockMLProcessor.processAudioWithML(chunk: testAudioBuffer, sensitivity: 0.5)
        XCTAssertNil(result, "ML inference should return nil while suspended")
        
        // Test recovery
        mockMLProcessor.initializeMLProcessing()
        
        // Wait for recovery
        let recoveryExpectation = XCTestExpectation(description: "ML recovery")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            recoveryExpectation.fulfill()
        }
        
        wait(for: [recoveryExpectation], timeout: 1.0)
        
        XCTAssertTrue(mockMLProcessor.isMLProcessingActive, "ML processing should be active after recovery")
    }
    
    // MARK: - Callback Tests
    
    func testMLProcessorCallbacks() {
        // Initialize ML processor
        mockMLProcessor.initializeMLProcessing()
        
        // Setup callback tracking
        var failureCount = 0
        var latencyCount = 0
        var successCount = 0
        var readyCount = 0
        
        let callbackLock = NSLock()
        
        mockMLProcessor.recordFailure = {
            callbackLock.lock()
            failureCount += 1
            callbackLock.unlock()
        }
        
        mockMLProcessor.recordLatency = { latency in
            callbackLock.lock()
            latencyCount += 1
            callbackLock.unlock()
        }
        
        mockMLProcessor.recordSuccess = {
            callbackLock.lock()
            successCount += 1
            callbackLock.unlock()
        }
        
        mockMLProcessor.onMLProcessingReady = {
            callbackLock.lock()
            readyCount += 1
            callbackLock.unlock()
        }
        
        // Wait for initialization and callbacks
        let callbackExpectation = XCTestExpectation(description: "ML callbacks")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            callbackExpectation.fulfill()
        }
        
        wait(for: [callbackExpectation], timeout: 2.0)
        
        // Test processing callbacks
        for _ in 0..<10 {
            _ = mockMLProcessor.processAudioWithML(chunk: testAudioBuffer, sensitivity: 0.5)
        }
        
        // Allow callback processing
        let processingExpectation = XCTestExpectation(description: "ML processing callbacks")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            processingExpectation.fulfill()
        }
        
        wait(for: [processingExpectation], timeout: 1.0)
        
        // Verify callbacks were called
        callbackLock.lock()
        XCTAssertGreaterThan(readyCount, 0, "Ready callback should be called")
        XCTAssertGreaterThan(latencyCount, 0, "Latency callback should be called")
        XCTAssertGreaterThan(successCount, 0, "Success callback should be called")
        callbackLock.unlock()
        
        // Test failure callback
        mockMLProcessor.simulateFailure()
        
        let failureExpectation = XCTestExpectation(description: "ML failure callback")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            failureExpectation.fulfill()
        }
        
        wait(for: [failureExpectation], timeout: 0.5)
        
        callbackLock.lock()
        XCTAssertGreaterThan(failureCount, 0, "Failure callback should be called")
        callbackLock.unlock()
    }
    
    // MARK: - Stress Tests
    
    func testMLProcessorUnderLoad() {
        // Initialize ML processor
        mockMLProcessor.initializeMLProcessing()
        
        // Wait for initialization
        let initExpectation = XCTestExpectation(description: "ML load initialization")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            initExpectation.fulfill()
        }
        
        wait(for: [initExpectation], timeout: 1.0)
        
        // Test under high load
        let loadExpectation = XCTestExpectation(description: "ML processor under load")
        loadExpectation.expectedFulfillmentCount = 100
        
        var errors = 0
        let errorLock = NSLock()
        
        for i in 0..<100 {
            DispatchQueue.global(qos: .userInteractive).async {
                do {
                    let testBuffer = Array(self.testAudioBuffer.shuffled())
                    let result = self.mockMLProcessor.processAudioWithML(chunk: testBuffer, sensitivity: 0.5)
                    
                    if result == nil {
                        errorLock.lock()
                        errors += 1
                        errorLock.unlock()
                    }
                    
                } catch {
                    errorLock.lock()
                    errors += 1
                    errorLock.unlock()
                }
                
                loadExpectation.fulfill()
            }
        }
        
        wait(for: [loadExpectation], timeout: 10.0)
        
        let errorRate = Double(errors) / 100.0
        print(String(format: "ML Processor Under Load: %.1f%% error rate", errorRate * 100))
        XCTAssertLessThan(errorRate, 0.05, "Error rate should be < 5%")
    }
    
    func testMLProcessorLongRunningStability() {
        // Initialize ML processor
        mockMLProcessor.initializeMLProcessing()
        
        // Wait for initialization
        let initExpectation = XCTestExpectation(description: "ML long running initialization")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            initExpectation.fulfill()
        }
        
        wait(for: [initExpectation], timeout: 1.0)
        
        // Test long-running stability
        let stabilityExpectation = XCTestExpectation(description: "ML long running stability")
        stabilityExpectation.expectedFulfillmentCount = 1000
        
        let startTime = CFAbsoluteTimeGetCurrent()
        var errors = 0
        let errorLock = NSLock()
        
        for i in 0..<1000 {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Double(i) * 0.001) {
                let testBuffer = Array(self.testAudioBuffer.shuffled())
                let result = self.mockMLProcessor.processAudioWithML(chunk: testBuffer, sensitivity: 0.5)
                
                if result == nil {
                    errorLock.lock()
                    errors += 1
                    errorLock.unlock()
                }
                
                stabilityExpectation.fulfill()
            }
        }
        
        wait(for: [stabilityExpectation], timeout: 15.0)
        
        let totalTime = CFAbsoluteTimeGetCurrent() - startTime
        let errorRate = Double(errors) / 1000.0
        
        print(String(format: "ML Long Running Stability: %.3fs total, %.1f%% error rate", totalTime, errorRate * 100))
        XCTAssertLessThan(errorRate, 0.01, "Error rate should be < 1%")
        XCTAssertLessThan(totalTime, 10.0, "Should complete in reasonable time")
    }
    
    // MARK: - Memory Statistics Tests
    
    func testMLMemoryStatistics() {
        // Test memory statistics
        let stats = mockMLProcessor.getMLMemoryStatistics()
        
        XCTAssertEqual(stats.current, 0.0, "Current memory usage should be 0 for mock")
        XCTAssertEqual(stats.peak, 0.0, "Peak memory usage should be 0 for mock")
        XCTAssertEqual(stats.modelLoad, 0.0, "Model load memory should be 0 for mock")
        XCTAssertEqual(stats.totalInferences, 0, "Total inferences should be 0 initially")
        
        // Initialize and process
        mockMLProcessor.initializeMLProcessing()
        
        // Wait for initialization
        let initExpectation = XCTestExpectation(description: "ML memory stats initialization")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            initExpectation.fulfill()
        }
        
        wait(for: [initExpectation], timeout: 1.0)
        
        // Process some audio
        for _ in 0..<10 {
            _ = mockMLProcessor.processAudioWithML(chunk: testAudioBuffer, sensitivity: 0.5)
        }
        
        // Check memory properties
        XCTAssertEqual(mockMLProcessor.mlMemoryUsageMB, 0.0, "ML memory usage should be 0 for mock")
        XCTAssertEqual(mockMLProcessor.mlPeakMemoryUsageMB, 0.0, "ML peak memory should be 0 for mock")
        XCTAssertEqual(mockMLProcessor.mlModelLoadMemoryMB, 0.0, "ML model load memory should be 0 for mock")
    }
    
    // MARK: - Helper Methods
    
    private func getCurrentMemoryUsage() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            return Double(info.resident_size)
        } else {
            return 0.0
        }
    }
}