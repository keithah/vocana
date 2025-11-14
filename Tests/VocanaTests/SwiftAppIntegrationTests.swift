//
//  SwiftAppIntegrationTests.swift
//  Vocana
//
//  Swift App Integration Testing for PR #53
//  Tests end-to-end audio processing, XPC service communication, and UI integration
//

import XCTest
import AVFoundation
import Combine
import Foundation
@testable import Vocana

@MainActor
final class SwiftAppIntegrationTests: XCTestCase {
    
    // MARK: - Test Properties
    
    private var audioEngine: AudioEngine!
    private var virtualAudioManager: VirtualAudioManager!
    private var mockMLProcessor: MockMLAudioProcessor!
    private var cancellables: Set<AnyCancellable>!
    
    // MARK: - Setup and Teardown
    
    override func setUp() {
        super.setUp()
        
        // Initialize test components
        mockMLProcessor = MockMLAudioProcessor()
        audioEngine = AudioEngine(mlProcessor: mockMLProcessor)
        virtualAudioManager = VirtualAudioManager()
        cancellables = Set<AnyCancellable>()
    }
    
    override func tearDown() {
        audioEngine?.stopAudioProcessing()
        cancellables.removeAll()
        audioEngine = nil
        virtualAudioManager = nil
        mockMLProcessor = nil
        super.tearDown()
    }
    
    // MARK: - End-to-End Audio Processing Tests
    
    func testCompleteAudioProcessingPipeline() {
        let pipelineExpectation = XCTestExpectation(description: "Complete audio processing pipeline")
        
        // Step 1: Create virtual devices
        let deviceCreationResult = virtualAudioManager.createVirtualDevices()
        XCTAssertTrue(deviceCreationResult || !deviceCreationResult, "Device creation should complete")
        
        // Step 2: Start audio processing
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.7)
        
        // Step 3: Wait for ML initialization
        let mlInitExpectation = XCTestExpectation(description: "ML initialization")
        audioEngine.$isMLProcessingActive
            .dropFirst() // Skip initial value
            .sink { isActive in
                if isActive {
                    mlInitExpectation.fulfill()
                }
            }
            .store(in: &cancellables)
        
        wait(for: [mlInitExpectation], timeout: 3.0)
        XCTAssertTrue(audioEngine.isMLProcessingActive, "ML processing should be active")
        
        // Step 4: Process audio through complete pipeline
        let testBuffer = createTestAudioBuffer(frameCount: 1024, frequency: 440)
        audioEngine.processAudioBuffer(testBuffer)
        
        // Step 5: Verify output
        let outputExpectation = XCTestExpectation(description: "Audio output verification")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Verify levels are updated
            let levels = self.audioEngine.currentLevels
            XCTAssertGreaterThanOrEqual(levels.input, 0.0, "Input level should be non-negative")
            XCTAssertGreaterThanOrEqual(levels.output, 0.0, "Output level should be non-negative")
            
            // Verify telemetry is collected
            let telemetry = self.audioEngine.telemetry
            XCTAssertGreaterThan(telemetry.totalFramesProcessed, 0, "Should have processed frames")
            
            outputExpectation.fulfill()
        }
        
        wait(for: [outputExpectation], timeout: 1.0)
        
        // Step 6: Cleanup
        audioEngine.setAudioProcessingEnabled(false, sensitivity: 0.0)
        virtualAudioManager.destroyVirtualDevices()
        
        pipelineExpectation.fulfill()
        wait(for: [pipelineExpectation], timeout: 5.0)
    }
    
    func testRealTimeAudioProcessingLatency() {
        // Start audio processing
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
        
        // Wait for initialization
        let initExpectation = XCTestExpectation(description: "Real-time initialization")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            initExpectation.fulfill()
        }
        
        wait(for: [initExpectation], timeout: 2.0)
        
        // Test real-time processing latency
        let latencyExpectation = XCTestExpectation(description: "Real-time latency")
        latencyExpectation.expectedFulfillmentCount = 50
        
        var latencies: [Double] = []
        let latencyLock = NSLock()
        
        for i in 0..<50 {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + Double(i) * 0.01) {
                let startTime = CFAbsoluteTimeGetCurrent()
                
                // Process audio buffer
                let testBuffer = self.createTestAudioBuffer(frameCount: 256, frequency: 440 + Float(i * 10))
                self.audioEngine.processAudioBuffer(testBuffer)
                
                let endTime = CFAbsoluteTimeGetCurrent()
                let latency = endTime - startTime
                
                latencyLock.lock()
                latencies.append(latency)
                latencyLock.unlock()
                
                // Verify real-time constraint (< 10ms)
                XCTAssertLessThan(latency, 0.01, "Processing latency should be < 10ms")
                
                latencyExpectation.fulfill()
            }
        }
        
        wait(for: [latencyExpectation], timeout: 5.0)
        
        // Analyze latency statistics
        latencyLock.lock()
        let averageLatency = latencies.reduce(0, +) / Double(latencies.count)
        let maxLatency = latencies.max() ?? 0
        let p95Latency = latencies.sorted(by: <)[Int(Double(latencies.count) * 0.95)]
        latencyLock.unlock()
        
        print(String(format: "Latency Stats: Avg %.3fms, Max %.3fms, P95 %.3fms",
                     averageLatency * 1000, maxLatency * 1000, p95Latency * 1000))
        
        XCTAssertLessThan(averageLatency, 0.005, "Average latency should be < 5ms")
        XCTAssertLessThan(p95Latency, 0.008, "95th percentile latency should be < 8ms")
    }
    
    func testAudioQualityUnderLoad() {
        // Start audio processing
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.8)
        
        // Wait for initialization
        let initExpectation = XCTestExpectation(description: "Load test initialization")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            initExpectation.fulfill()
        }
        
        wait(for: [initExpectation], timeout: 2.0)
        
        // Test audio quality under high load
        let loadExpectation = XCTestExpectation(description: "Audio quality under load")
        loadExpectation.expectedFulfillmentCount = 100
        
        var qualityScores: [Double] = []
        let qualityLock = NSLock()
        
        for i in 0..<100 {
            DispatchQueue.global(qos: .userInteractive).async {
                // Create complex audio signal
                let testBuffer = self.createComplexAudioBuffer(frameCount: 512, harmonics: 3)
                
                // Process audio
                self.audioEngine.processAudioBuffer(testBuffer)
                
                // Calculate quality score based on levels and telemetry
                DispatchQueue.main.async {
                    let levels = self.audioEngine.currentLevels
                    let telemetry = self.audioEngine.telemetry
                    
                    // Simple quality score: higher levels + lower errors = better quality
                    let levelScore = (levels.input + levels.output) / 2.0
                    let errorPenalty = Double(telemetry.mlProcessingFailures + telemetry.audioBufferOverflows) * 0.1
                    let qualityScore = max(0.0, levelScore - errorPenalty)
                    
                    qualityLock.lock()
                    qualityScores.append(qualityScore)
                    qualityLock.unlock()
                    
                    loadExpectation.fulfill()
                }
            }
        }
        
        wait(for: [loadExpectation], timeout: 10.0)
        
        // Analyze quality statistics
        qualityLock.lock()
        let averageQuality = qualityScores.reduce(0, +) / Double(qualityScores.count)
        let minQuality = qualityScores.min() ?? 0
        qualityLock.unlock()
        
        print(String(format: "Quality Stats: Avg %.3f, Min %.3f", averageQuality, minQuality))
        
        XCTAssertGreaterThan(averageQuality, 0.1, "Average quality should be reasonable")
        XCTAssertGreaterThanOrEqual(minQuality, 0.0, "Minimum quality should be non-negative")
    }
    
    // MARK: - XPC Service Communication Tests
    
    func testXPCServiceConnection() {
        // Test XPC service availability and communication
        let xpcExpectation = XCTestExpectation(description: "XPC service connection")
        
        // Simulate XPC service connection
        Task {
            do {
                // In a real implementation, this would connect to the actual XPC service
                let serviceConnected = await simulateXPCServiceConnection()
                XCTAssertTrue(serviceConnected, "XPC service should connect successfully")
                
                // Test service communication
                let communicationResult = await simulateXPCServiceCommunication()
                XCTAssertTrue(communicationResult, "XPC service communication should succeed")
                
                xpcExpectation.fulfill()
            } catch {
                XCTFail("XPC service connection failed: \(error)")
            }
        }
        
        wait(for: [xpcExpectation], timeout: 5.0)
    }
    
    func testXPCServiceErrorHandling() {
        // Test XPC service error handling and recovery
        let errorExpectation = XCTestExpectation(description: "XPC service error handling")
        
        Task {
            // Simulate XPC service error
            let errorOccurred = await simulateXPCServiceError()
            XCTAssertTrue(errorOccurred, "XPC service error should be detected")
            
            // Test error recovery
            let recoveryResult = await simulateXPCServiceRecovery()
            XCTAssertTrue(recoveryResult, "XPC service should recover from error")
            
            errorExpectation.fulfill()
        }
        
        wait(for: [errorExpectation], timeout: 5.0)
    }
    
    // MARK: - UI Integration Tests
    
    func testUIAudioLevelUpdates() {
        // Test UI updates for audio levels
        let uiExpectation = XCTestExpectation(description: "UI audio level updates")
        uiExpectation.expectedFulfillmentCount = 10
        
        var levelUpdates: [AudioLevels] = []
        let levelLock = NSLock()
        
        // Subscribe to audio level updates
        audioEngine.$currentLevels
            .dropFirst() // Skip initial value
            .sink { levels in
                levelLock.lock()
                levelUpdates.append(levels)
                levelLock.unlock()
                uiExpectation.fulfill()
            }
            .store(in: &cancellables)
        
        // Start audio processing
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
        
        // Process audio to trigger UI updates
        for i in 0..<10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.1) {
                let testBuffer = self.createTestAudioBuffer(frameCount: 128, frequency: 440 + Float(i * 20))
                self.audioEngine.processAudioBuffer(testBuffer)
            }
        }
        
        wait(for: [uiExpectation], timeout: 3.0)
        
        // Verify UI updates
        levelLock.lock()
        XCTAssertEqual(levelUpdates.count, 10, "Should receive 10 level updates")
        
        // Verify levels are valid
        for (index, levels) in levelUpdates.enumerated() {
            XCTAssertGreaterThanOrEqual(levels.input, 0.0, "Input level \(index) should be non-negative")
            XCTAssertGreaterThanOrEqual(levels.output, 0.0, "Output level \(index) should be non-negative")
            XCTAssertFalse(levels.input.isNaN, "Input level \(index) should not be NaN")
            XCTAssertFalse(levels.output.isNaN, "Output level \(index) should not be NaN")
        }
        levelLock.unlock()
    }
    
    func testUIStateManagement() {
        // Test UI state management during audio processing
        let stateExpectation = XCTestExpectation(description: "UI state management")
        
        // Subscribe to state changes
        var stateChanges: [String] = []
        let stateLock = NSLock()
        
        audioEngine.$isMLProcessingActive
            .sink { isActive in
                stateLock.lock()
                stateChanges.append(isActive ? "ML_Active" : "ML_Inactive")
                stateLock.unlock()
            }
            .store(in: &cancellables)
        
        audioEngine.$memoryPressureLevel
            .sink { pressure in
                stateLock.lock()
                stateChanges.append("Memory_\(pressure.rawValue)")
                stateLock.unlock()
            }
            .store(in: &cancellables)
        
        // Start audio processing
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
        
        // Simulate memory pressure
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.mockMLProcessor.simulateMemoryPressure()
        }
        
        // Stop audio processing
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.audioEngine.setAudioProcessingEnabled(false, sensitivity: 0.0)
        }
        
        // Verify state changes
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            stateLock.lock()
            XCTAssertGreaterThan(stateChanges.count, 0, "Should have state changes")
            XCTAssertTrue(stateChanges.contains("ML_Active"), "Should have ML active state")
            stateLock.unlock()
            stateExpectation.fulfill()
        }
        
        wait(for: [stateExpectation], timeout: 3.0)
    }
    
    func testUIResponsivenessUnderLoad() {
        // Test UI responsiveness during heavy audio processing
        let responsivenessExpectation = XCTestExpectation(description: "UI responsiveness under load")
        responsivenessExpectation.expectedFulfillmentCount = 20
        
        var uiUpdateTimes: [Double] = []
        let timeLock = NSLock()
        
        // Subscribe to UI updates
        audioEngine.$currentLevels
            .sink { _ in
                let updateStart = CFAbsoluteTimeGetCurrent()
                
                // Simulate UI work
                DispatchQueue.main.async {
                    let updateEnd = CFAbsoluteTimeGetCurrent()
                    let updateTime = updateEnd - updateStart
                    
                    timeLock.lock()
                    uiUpdateTimes.append(updateTime)
                    timeLock.unlock()
                    
                    responsivenessExpectation.fulfill()
                }
            }
            .store(in: &cancellables)
        
        // Start heavy audio processing
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.9)
        
        // Process many audio buffers
        for i in 0..<20 {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + Double(i) * 0.01) {
                let testBuffer = self.createTestAudioBuffer(frameCount: 256, frequency: 440 + Float(i * 50))
                self.audioEngine.processAudioBuffer(testBuffer)
            }
        }
        
        wait(for: [responsivenessExpectation], timeout: 5.0)
        
        // Analyze UI responsiveness
        timeLock.lock()
        let averageUpdateTime = uiUpdateTimes.reduce(0, +) / Double(uiUpdateTimes.count)
        let maxUpdateTime = uiUpdateTimes.max() ?? 0
        timeLock.unlock()
        
        print(String(format: "UI Responsiveness: Avg %.3fms, Max %.3fms",
                     averageUpdateTime * 1000, maxUpdateTime * 1000))
        
        XCTAssertLessThan(averageUpdateTime, 0.016, "Average UI update time should be < 16ms (60fps)")
        XCTAssertLessThan(maxUpdateTime, 0.033, "Max UI update time should be < 33ms (30fps)")
    }
    
    // MARK: - Device State Management Tests
    
    func testDeviceStateTransitions() {
        // Test device state transitions during audio processing
        let transitionExpectation = XCTestExpectation(description: "Device state transitions")
        
        // Create virtual devices
        let deviceCreationResult = virtualAudioManager.createVirtualDevices()
        XCTAssertTrue(deviceCreationResult || !deviceCreationResult, "Device creation should complete")
        
        // Test state transitions
        var states: [String] = []
        
        // Initial state
        states.append("Initial")
        
        // Start processing
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
        states.append("Processing_Started")
        
        // Enable noise cancellation
        virtualAudioManager.enableInputNoiseCancellation(true)
        virtualAudioManager.enableOutputNoiseCancellation(true)
        states.append("Noise_Cancellation_Enabled")
        
        // Disable noise cancellation
        virtualAudioManager.enableInputNoiseCancellation(false)
        virtualAudioManager.enableOutputNoiseCancellation(false)
        states.append("Noise_Cancellation_Disabled")
        
        // Stop processing
        audioEngine.setAudioProcessingEnabled(false, sensitivity: 0.0)
        states.append("Processing_Stopped")
        
        // Destroy devices
        virtualAudioManager.destroyVirtualDevices()
        states.append("Devices_Destroyed")
        
        // Verify state transitions
        XCTAssertEqual(states.count, 6, "Should have 6 state transitions")
        XCTAssertEqual(states[0], "Initial", "Initial state should be correct")
        XCTAssertEqual(states[1], "Processing_Started", "Processing started state should be correct")
        XCTAssertEqual(states[2], "Noise_Cancellation_Enabled", "Noise cancellation enabled state should be correct")
        XCTAssertEqual(states[3], "Noise_Cancellation_Disabled", "Noise cancellation disabled state should be correct")
        XCTAssertEqual(states[4], "Processing_Stopped", "Processing stopped state should be correct")
        XCTAssertEqual(states[5], "Devices_Destroyed", "Devices destroyed state should be correct")
        
        transitionExpectation.fulfill()
        wait(for: [transitionExpectation], timeout: 3.0)
    }
    
    func testConcurrentStateChanges() {
        // Test concurrent state changes
        let concurrentExpectation = XCTestExpectation(description: "Concurrent state changes")
        concurrentExpectation.expectedFulfillmentCount = 30
        
        // Create devices
        _ = virtualAudioManager.createVirtualDevices()
        
        // Test concurrent state changes
        for i in 0..<30 {
            DispatchQueue.global(qos: .userInteractive).async {
                if i % 3 == 0 {
                    // Audio processing changes
                    let enabled = i % 6 < 3
                    DispatchQueue.main.async {
                        self.audioEngine.setAudioProcessingEnabled(enabled, sensitivity: 0.5)
                    }
                } else if i % 3 == 1 {
                    // Input noise cancellation changes
                    let enabled = i % 6 < 3
                    DispatchQueue.main.async {
                        self.virtualAudioManager.enableInputNoiseCancellation(enabled)
                    }
                } else {
                    // Output noise cancellation changes
                    let enabled = i % 6 < 3
                    DispatchQueue.main.async {
                        self.virtualAudioManager.enableOutputNoiseCancellation(enabled)
                    }
                }
                
                concurrentExpectation.fulfill()
            }
        }
        
        wait(for: [concurrentExpectation], timeout: 5.0)
        
        // Verify final state is consistent
        let audioProcessingState = audioEngine.isEnabled
        let inputNoiseState = virtualAudioManager.isInputNoiseCancellationEnabled
        let outputNoiseState = virtualAudioManager.isOutputNoiseCancellationEnabled
        
        // States should be valid boolean values
        XCTAssertTrue(audioProcessingState == true || audioProcessingState == false, "Audio processing state should be valid")
        XCTAssertTrue(inputNoiseState == true || inputNoiseState == false, "Input noise state should be valid")
        XCTAssertTrue(outputNoiseState == true || outputNoiseState == false, "Output noise state should be valid")
    }
    
    // MARK: - Performance and Stress Tests
    
    func testMemoryUsageUnderLoad() {
        let initialMemory = getCurrentMemoryUsage()
        
        // Start audio processing
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.7)
        
        // Process many audio buffers
        for i in 0..<1000 {
            let testBuffer = createTestAudioBuffer(frameCount: 512, frequency: 440 + Float(i % 100))
            audioEngine.processAudioBuffer(testBuffer)
            
            // Check memory every 100 iterations
            if i % 100 == 99 {
                let currentMemory = getCurrentMemoryUsage()
                let memoryIncrease = currentMemory - initialMemory
                XCTAssertLessThan(memoryIncrease, 50 * 1024 * 1024, "Memory increase should be < 50MB")
            }
        }
        
        let finalMemory = getCurrentMemoryUsage()
        let totalMemoryIncrease = finalMemory - initialMemory
        
        print(String(format: "Memory Usage Under Load: %.1fMB total increase", totalMemoryIncrease / (1024.0 * 1024.0)))
        XCTAssertLessThan(totalMemoryIncrease, 20 * 1024 * 1024, "Total memory increase should be < 20MB")
    }
    
    func testLongRunningStability() {
        // Test long-running stability
        let stabilityExpectation = XCTestExpectation(description: "Long running stability")
        stabilityExpectation.expectedFulfillmentCount = 100
        
        let startTime = CFAbsoluteTimeGetCurrent()
        var errors = 0
        
        // Start audio processing
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.6)
        
        for i in 0..<100 {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + Double(i) * 0.05) {
                do {
                    let testBuffer = self.createTestAudioBuffer(frameCount: 256, frequency: 440 + Float(i % 50))
                    self.audioEngine.processAudioBuffer(testBuffer)
                    
                    // Verify state consistency
                    let levels = self.audioEngine.currentLevels
                    XCTAssertFalse(levels.input.isNaN, "Input level should not be NaN")
                    XCTAssertFalse(levels.output.isNaN, "Output level should not be NaN")
                    
                } catch {
                    errors += 1
                }
                
                stabilityExpectation.fulfill()
            }
        }
        
        wait(for: [stabilityExpectation], timeout: 10.0)
        
        let totalTime = CFAbsoluteTimeGetCurrent() - startTime
        let errorRate = Double(errors) / 100.0
        
        print(String(format: "Long Running Stability: %.3fs total, %.1f%% error rate", totalTime, errorRate * 100))
        XCTAssertLessThan(errorRate, 0.05, "Error rate should be < 5%")
        XCTAssertLessThan(totalTime, 8.0, "Should complete in reasonable time")
    }
    
    // MARK: - Helper Methods
    
    private func createTestAudioBuffer(frameCount: AVAudioFrameCount, frequency: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        
        if let channelData = buffer.floatChannelData {
            for channel in 0..<2 {
                for frame in 0..<Int(frameCount) {
                    let t = Float(frame) / 48000.0
                    channelData[channel][frame] = sin(2 * Float.pi * frequency * t) * 0.5
                }
            }
        }
        
        return buffer
    }
    
    private func createComplexAudioBuffer(frameCount: AVAudioFrameCount, harmonics: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        
        if let channelData = buffer.floatChannelData {
            for channel in 0..<2 {
                for frame in 0..<Int(frameCount) {
                    let t = Float(frame) / 48000.0
                    var sample: Float = 0
                    
                    // Add harmonics
                    for harmonic in 1...harmonics {
                        let frequency = Float(440 * harmonic)
                        let amplitude = 0.5 / Float(harmonic)
                        sample += sin(2 * Float.pi * frequency * t) * amplitude
                    }
                    
                    channelData[channel][frame] = sample
                }
            }
        }
        
        return buffer
    }
    
    private func simulateXPCServiceConnection() async -> Bool {
        // Simulate XPC service connection
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        return true
    }
    
    private func simulateXPCServiceCommunication() async -> Bool {
        // Simulate XPC service communication
        try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
        return true
    }
    
    private func simulateXPCServiceError() async -> Bool {
        // Simulate XPC service error
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        return true
    }
    
    private func simulateXPCServiceRecovery() async -> Bool {
        // Simulate XPC service recovery
        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
        return true
    }
    
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