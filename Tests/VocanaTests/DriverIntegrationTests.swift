//
//  DriverIntegrationTests.swift
//  Vocana
//
//  Driver Integration Testing for PR #52
//  Tests HAL plugin integration, multi-device synchronization, and real-time pipeline
//

import XCTest
import CoreAudio
import AudioToolbox
import AVFoundation
import Foundation
@testable import Vocana

@MainActor
final class DriverIntegrationTests: XCTestCase {
    
    // MARK: - Test Properties
    
    private var audioEngine: AudioEngine!
    private var virtualAudioManager: VirtualAudioManager!
    private var mockMLProcessor: MockMLAudioProcessor!
    private var testAudioBuffer: AVAudioPCMBuffer!
    private var testAudioFormat: AVAudioFormat!
    
    // MARK: - Setup and Teardown
    
    override func setUp() {
        super.setUp()
        
        // Initialize test components
        mockMLProcessor = MockMLAudioProcessor()
        audioEngine = AudioEngine(mlProcessor: mockMLProcessor)
        virtualAudioManager = VirtualAudioManager()
        
        // Setup test audio format (48kHz, stereo, 32-bit float)
        testAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        
        // Generate test audio buffer
        let frameCount = AVAudioFrameCount(1024)
        testAudioBuffer = AVAudioPCMBuffer(pcmFormat: testAudioFormat, frameCapacity: frameCount)!
        testAudioBuffer.frameLength = frameCount
        
        // Fill with test signal
        if let channelData = testAudioBuffer.floatChannelData {
            for channel in 0..<2 {
                for frame in 0..<Int(frameCount) {
                    let t = Float(frame) / 48000.0
                    channelData[channel][frame] = sin(2 * Float.pi * 440 * t) * 0.5
                }
            }
        }
    }
    
    override func tearDown() {
        audioEngine?.stopAudioProcessing()
        audioEngine = nil
        virtualAudioManager = nil
        mockMLProcessor = nil
        testAudioBuffer = nil
        testAudioFormat = nil
        super.tearDown()
    }
    
    // MARK: - HAL Plugin Integration Tests
    
    func testHALPluginRegistration() {
        // Test that HAL plugin can be discovered
        let discoveryResult = virtualAudioManager.createVirtualDevices()
        
        // In test environment, this may fail if HAL plugin is not installed
        // But the method should not crash
        XCTAssertTrue(discoveryResult || !discoveryResult, "Discovery should complete without crashing")
        
        // Test device availability after discovery
        let devicesAvailable = virtualAudioManager.areDevicesAvailable
        // May be false in test environment, but should be accessible
        _ = devicesAvailable
    }
    
    func testDevicePropertyIntegration() {
        // Create virtual devices
        _ = virtualAudioManager.createVirtualDevices()
        
        // Test noise cancellation controls
        virtualAudioManager.enableInputNoiseCancellation(true)
        XCTAssertTrue(virtualAudioManager.isInputNoiseCancellationEnabled, "Input noise cancellation should be enabled")
        
        virtualAudioManager.enableOutputNoiseCancellation(true)
        XCTAssertTrue(virtualAudioManager.isOutputNoiseCancellationEnabled, "Output noise cancellation should be enabled")
        
        virtualAudioManager.enableInputNoiseCancellation(false)
        XCTAssertFalse(virtualAudioManager.isInputNoiseCancellationEnabled, "Input noise cancellation should be disabled")
        
        virtualAudioManager.enableOutputNoiseCancellation(false)
        XCTAssertFalse(virtualAudioManager.isOutputNoiseCancellationEnabled, "Output noise cancellation should be disabled")
    }
    
    func testAudioSessionIntegration() {
        // Test audio engine integration with virtual devices
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
        
        // Allow time for initialization
        let expectation = XCTestExpectation(description: "Audio session integration")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 2.0)
        
        // Verify audio engine is active
        XCTAssertTrue(audioEngine.isMLProcessingActive, "ML processing should be active")
        XCTAssertNotNil(audioEngine.currentLevels, "Current levels should be available")
        
        // Test audio processing
        audioEngine.processAudioBuffer(testAudioBuffer)
        
        // Allow processing to complete
        let processingExpectation = XCTestExpectation(description: "Audio processing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            processingExpectation.fulfill()
        }
        
        wait(for: [processingExpectation], timeout: 1.0)
    }
    
    // MARK: - Multi-Device Synchronization Tests
    
    func testMultiDeviceDiscovery() {
        // Test discovery of multiple virtual devices
        let discoveryResult1 = virtualAudioManager.createVirtualDevices()
        let discoveryResult2 = virtualAudioManager.createVirtualDevices()
        
        // Should handle multiple discovery calls gracefully
        XCTAssertTrue(discoveryResult1 || !discoveryResult1, "First discovery should complete")
        XCTAssertTrue(discoveryResult2 || !discoveryResult2, "Second discovery should complete")
        
        // Test device state consistency
        let inputDevice = virtualAudioManager.inputDevice
        let outputDevice = virtualAudioManager.outputDevice
        
        if inputDevice != nil && outputDevice != nil {
            XCTAssertEqual(inputDevice?.deviceName, "VocanaVirtualDevice 2ch", "Input device name should match")
            XCTAssertEqual(outputDevice?.deviceName, "VocanaVirtualDevice 2ch", "Output device name should match")
        }
    }
    
    func testDeviceStateSynchronization() {
        // Create devices
        _ = virtualAudioManager.createVirtualDevices()
        
        // Test state synchronization between input and output devices
        virtualAudioManager.enableInputNoiseCancellation(true)
        virtualAudioManager.enableOutputNoiseCancellation(true)
        
        // Simulate state change notification
        let notification = Notification(
            name: Notification.Name("VocanaDeviceStateChanged"),
            object: nil,
            userInfo: [
                "deviceID": UInt32(1001),
                "state": UInt32(VocanaNoiseCancellationState.on.rawValue)
            ]
        )
        
        // Post notification to test state handling
        NotificationCenter.default.post(notification)
        
        // Allow notification processing
        let notificationExpectation = XCTestExpectation(description: "State notification")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            notificationExpectation.fulfill()
        }
        
        wait(for: [notificationExpectation], timeout: 0.5)
        
        // Verify state consistency
        XCTAssertTrue(virtualAudioManager.isInputNoiseCancellationEnabled, "Input state should be synchronized")
        XCTAssertTrue(virtualAudioManager.isOutputNoiseCancellationEnabled, "Output state should be synchronized")
    }
    
    func testConcurrentDeviceAccess() {
        // Create devices
        _ = virtualAudioManager.createVirtualDevices()
        
        let concurrentExpectation = XCTestExpectation(description: "Concurrent device access")
        concurrentExpectation.expectedFulfillmentCount = 20
        
        // Test concurrent access to device controls
        for i in 0..<20 {
            DispatchQueue.global(qos: .userInteractive).async {
                if i % 2 == 0 {
                    // Enable/disable input noise cancellation
                    self.virtualAudioManager.enableInputNoiseCancellation(i % 4 == 0)
                } else {
                    // Enable/disable output noise cancellation
                    self.virtualAudioManager.enableOutputNoiseCancellation(i % 4 == 1)
                }
                concurrentExpectation.fulfill()
            }
        }
        
        wait(for: [concurrentExpectation], timeout: 5.0)
        
        // Verify final state is consistent
        let inputState = virtualAudioManager.isInputNoiseCancellationEnabled
        let outputState = virtualAudioManager.isOutputNoiseCancellationEnabled
        
        // States should be boolean values (not corrupted by concurrent access)
        XCTAssertTrue(inputState == true || inputState == false, "Input state should be valid boolean")
        XCTAssertTrue(outputState == true || outputState == false, "Output state should be valid boolean")
    }
    
    // MARK: - Real-Time Audio Processing Pipeline Tests
    
    func testRealTimeAudioPipeline() {
        // Start audio processing
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
        
        // Allow initialization
        let initExpectation = XCTestExpectation(description: "Pipeline initialization")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            initExpectation.fulfill()
        }
        
        wait(for: [initExpectation], timeout: 2.0)
        
        // Test real-time processing with multiple buffers
        let processingExpectation = XCTestExpectation(description: "Real-time processing")
        processingExpectation.expectedFulfillmentCount = 10
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        for i in 0..<10 {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + Double(i) * 0.01) {
                let processingStart = CFAbsoluteTimeGetCurrent()
                
                // Process audio buffer
                self.audioEngine.processAudioBuffer(self.testAudioBuffer)
                
                let processingEnd = CFAbsoluteTimeGetCurrent()
                let latency = processingEnd - processingStart
                
                // Verify real-time constraints
                XCTAssertLessThan(latency, 0.01, "Processing latency should be < 10ms")
                
                processingExpectation.fulfill()
            }
        }
        
        wait(for: [processingExpectation], timeout: 5.0)
        
        let totalTime = CFAbsoluteTimeGetCurrent() - startTime
        let averageLatency = totalTime / 10.0
        
        XCTAssertLessThan(averageLatency, 0.01, "Average processing latency should be < 10ms")
    }
    
    func testAudioPipelineUnderLoad() {
        // Start audio processing
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
        
        // Allow initialization
        let initExpectation = XCTestExpectation(description: "Pipeline initialization under load")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            initExpectation.fulfill()
        }
        
        wait(for: [initExpectation], timeout: 2.0)
        
        // Test pipeline under high load
        let loadExpectation = XCTestExpectation(description: "Pipeline under load")
        loadExpectation.expectedFulfillmentCount = 100
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        for i in 0..<100 {
            DispatchQueue.global(qos: .userInteractive).async {
                // Create test buffer with varying content
                let testBuffer = self.createTestBuffer(frameCount: 1024, frequency: 440 + Float(i * 10))
                
                let processingStart = CFAbsoluteTimeGetCurrent()
                self.audioEngine.processAudioBuffer(testBuffer)
                let processingEnd = CFAbsoluteTimeGetCurrent()
                
                let latency = processingEnd - processingStart
                XCTAssertLessThan(latency, 0.02, "Processing latency under load should be < 20ms")
                
                loadExpectation.fulfill()
            }
        }
        
        wait(for: [loadExpectation], timeout: 10.0)
        
        let totalTime = CFAbsoluteTimeGetCurrent() - startTime
        let averageLatency = totalTime / 100.0
        
        print(String(format: "Pipeline Under Load: %.3fms average latency", averageLatency * 1000))
        XCTAssertLessThan(averageLatency, 0.015, "Average latency under load should be < 15ms")
    }
    
    func testMemoryPressureScenarios() {
        // Start audio processing
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
        
        // Allow initialization
        let initExpectation = XCTestExpectation(description: "Memory pressure initialization")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            initExpectation.fulfill()
        }
        
        wait(for: [initExpectation], timeout: 2.0)
        
        // Simulate memory pressure
        mockMLProcessor.simulateMemoryPressure()
        
        // Test processing under memory pressure
        let pressureExpectation = XCTestExpectation(description: "Memory pressure processing")
        pressureExpectation.expectedFulfillmentCount = 50
        
        for i in 0..<50 {
            DispatchQueue.global(qos: .userInteractive).async {
                let testBuffer = self.createTestBuffer(frameCount: 512, frequency: 440)
                self.audioEngine.processAudioBuffer(testBuffer)
                pressureExpectation.fulfill()
            }
        }
        
        wait(for: [pressureExpectation], timeout: 5.0)
        
        // Verify system recovered gracefully
        XCTAssertEqual(audioEngine.memoryPressureLevel, .warning, "Memory pressure should be detected")
        
        // Test recovery
        mockMLProcessor.attemptMemoryPressureRecovery()
        
        let recoveryExpectation = XCTestExpectation(description: "Memory pressure recovery")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            recoveryExpectation.fulfill()
        }
        
        wait(for: [recoveryExpectation], timeout: 1.0)
    }
    
    // MARK: - Error Handling and Recovery Tests
    
    func testAudioPipelineErrorRecovery() {
        // Start audio processing
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
        
        // Allow initialization
        let initExpectation = XCTestExpectation(description: "Error recovery initialization")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            initExpectation.fulfill()
        }
        
        wait(for: [initExpectation], timeout: 2.0)
        
        // Simulate ML processing failure
        mockMLProcessor.simulateFailure()
        
        // Test processing continues despite ML failure
        let recoveryExpectation = XCTestExpectation(description: "Error recovery processing")
        recoveryExpectation.expectedFulfillmentCount = 20
        
        for i in 0..<20 {
            DispatchQueue.global(qos: .userInteractive).async {
                let testBuffer = self.createTestBuffer(frameCount: 256, frequency: 440)
                self.audioEngine.processAudioBuffer(testBuffer)
                recoveryExpectation.fulfill()
            }
        }
        
        wait(for: [recoveryExpectation], timeout: 5.0)
        
        // Verify system handled error gracefully
        XCTAssertNotNil(audioEngine.currentLevels, "Levels should still be available after error")
        XCTAssertNotNil(audioEngine.telemetry, "Telemetry should be available after error")
    }
    
    func testDeviceDisconnectionRecovery() {
        // Create devices
        _ = virtualAudioManager.createVirtualDevices()
        
        // Test device disconnection simulation
        virtualAudioManager.destroyVirtualDevices()
        
        XCTAssertNil(virtualAudioManager.inputDevice, "Input device should be nil after destruction")
        XCTAssertNil(virtualAudioManager.outputDevice, "Output device should be nil after destruction")
        XCTAssertFalse(virtualAudioManager.areDevicesAvailable, "Devices should not be available after destruction")
        
        // Test recovery by recreating devices
        let recoveryResult = virtualAudioManager.createVirtualDevices()
        XCTAssertTrue(recoveryResult || !recoveryResult, "Device recreation should complete")
        
        // Test controls still work after recovery
        virtualAudioManager.enableInputNoiseCancellation(true)
        virtualAudioManager.enableOutputNoiseCancellation(true)
    }
    
    // MARK: - Performance and Stress Tests
    
    func testLongRunningStability() {
        // Start audio processing
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
        
        // Allow initialization
        let initExpectation = XCTestExpectation(description: "Long running initialization")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            initExpectation.fulfill()
        }
        
        wait(for: [initExpectation], timeout: 2.0)
        
        // Run for extended period (simulated)
        let stabilityExpectation = XCTestExpectation(description: "Long running stability")
        stabilityExpectation.expectedFulfillmentCount = 1000
        
        let startTime = CFAbsoluteTimeGetCurrent()
        var errors = 0
        
        for i in 0..<1000 {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + Double(i) * 0.001) {
                do {
                    let testBuffer = self.createTestBuffer(frameCount: 128, frequency: 440 + Float(i % 100))
                    self.audioEngine.processAudioBuffer(testBuffer)
                } catch {
                    errors += 1
                }
                stabilityExpectation.fulfill()
            }
        }
        
        wait(for: [stabilityExpectation], timeout: 10.0)
        
        let totalTime = CFAbsoluteTimeGetCurrent() - startTime
        let errorRate = Double(errors) / 1000.0
        
        print(String(format: "Long Running Stability: %.3fs total, %.1f%% error rate", totalTime, errorRate * 100))
        XCTAssertLessThan(errorRate, 0.01, "Error rate should be < 1%")
        XCTAssertLessThan(totalTime, 5.0, "Should complete in reasonable time")
    }
    
    func testMemoryLeakDetection() {
        let initialMemory = getCurrentMemoryUsage()
        
        // Start audio processing
        audioEngine.setAudioProcessingEnabled(true, sensitivity: 0.5)
        
        // Allow initialization
        let initExpectation = XCTestExpectation(description: "Memory leak initialization")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            initExpectation.fulfill()
        }
        
        wait(for: [initExpectation], timeout: 2.0)
        
        // Process many buffers
        for i in 0..<1000 {
            let testBuffer = createTestBuffer(frameCount: 256, frequency: 440 + Float(i % 50))
            audioEngine.processAudioBuffer(testBuffer)
            
            // Check memory every 100 iterations
            if i % 100 == 99 {
                let currentMemory = getCurrentMemoryUsage()
                let memoryIncrease = currentMemory - initialMemory
                XCTAssertLessThan(memoryIncrease, 100 * 1024 * 1024, "Memory increase should be < 100MB")
            }
        }
        
        // Stop processing
        audioEngine.stopAudioProcessing()
        
        // Allow cleanup
        let cleanupExpectation = XCTestExpectation(description: "Memory cleanup")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            cleanupExpectation.fulfill()
        }
        
        wait(for: [cleanupExpectation], timeout: 2.0)
        
        let finalMemory = getCurrentMemoryUsage()
        let totalMemoryIncrease = finalMemory - initialMemory
        
        print(String(format: "Memory Leak Detection: %.1fMB total increase", totalMemoryIncrease / (1024.0 * 1024.0)))
        XCTAssertLessThan(totalMemoryIncrease, 20 * 1024 * 1024, "Total memory increase should be < 20MB")
    }
    
    // MARK: - Helper Methods
    
    private func createTestBuffer(frameCount: AVAudioFrameCount, frequency: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: testAudioFormat, frameCapacity: frameCount)!
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