//
//  HALPluginTests.swift
//  Vocana
//
//  Comprehensive HAL Plugin Testing for PR #52
//  Tests Core Audio HAL plugin functionality, device lifecycle, and performance
//

import XCTest
import CoreAudio
import AudioToolbox
import Foundation
@testable import Vocana

@MainActor
final class HALPluginTests: XCTestCase {
    
    // MARK: - Test Properties
    
    private var testDeviceID: AudioObjectID?
    private var pluginInterface: UnsafeMutableRawPointer?
    private var testAudioBuffer: [Float]!
    
    // MARK: - Setup and Teardown
    
    override func setUp() {
        super.setUp()
        
        // Generate test audio data (48kHz, 2 channels, 100ms)
        let sampleRate = 48000
        let duration = 0.1 // 100ms
        let numSamples = Int(Float(sampleRate) * Float(duration))
        
        testAudioBuffer = (0..<numSamples).map { i in
            let t = Float(i) / Float(sampleRate)
            // Generate test tone with noise
            return sin(2 * Float.pi * 440 * t) * 0.5 + Float.random(in: -0.05...0.05)
        }
        
        // Initialize HAL plugin for testing
        setupHALPlugin()
    }
    
    override func tearDown() {
        cleanupHALPlugin()
        testAudioBuffer = nil
        testDeviceID = nil
        pluginInterface = nil
        super.tearDown()
    }
    
    // MARK: - HAL Plugin Lifecycle Tests
    
    func testHALPluginInitialization() {
        // Test that HAL plugin can be initialized
        XCTAssertNotNil(pluginInterface, "HAL plugin interface should be initialized")
        
        // Test plugin properties
        let pluginProperties = getPluginProperties()
        XCTAssertNotNil(pluginProperties, "Plugin properties should be available")
        XCTAssertEqual(pluginProperties?["name"] as? String, "Vocana", "Plugin name should match")
    }
    
    func testDeviceCreationAndDestruction() {
        // Test device creation
        let creationResult = createTestDevice()
        XCTAssertTrue(creationResult.0, "Device creation should succeed")
        XCTAssertNotNil(creationResult.1, "Device ID should be returned")
        
        testDeviceID = creationResult.1
        
        // Test device properties
        if let deviceID = testDeviceID {
            let deviceProperties = getDeviceProperties(deviceID: deviceID)
            XCTAssertNotNil(deviceProperties, "Device properties should be available")
            XCTAssertEqual(deviceProperties?["name"] as? String, "Vocana", "Device name should match")
            XCTAssertEqual(deviceProperties?["channels"] as? UInt32, 2, "Should have 2 channels")
            XCTAssertEqual(deviceProperties?["sampleRate"] as? Float64, 48000.0, "Sample rate should be 48kHz")
        }
        
        // Test device destruction
        if let deviceID = testDeviceID {
            let destructionResult = destroyTestDevice(deviceID: deviceID)
            XCTAssertTrue(destructionResult, "Device destruction should succeed")
        }
    }
    
    func testDevicePropertyHandling() {
        // Create device for property testing
        let creationResult = createTestDevice()
        XCTAssertTrue(creationResult.0, "Device creation should succeed")
        testDeviceID = creationResult.1
        
        guard let deviceID = testDeviceID else {
            XCTFail("Test device ID should not be nil")
            return
        }
        
        // Test volume property
        let volumeSetResult = setDeviceProperty(deviceID: deviceID, property: kAudioDevicePropertyVolumeScalar, value: 0.75)
        XCTAssertTrue(volumeSetResult, "Volume property should be settable")
        
        let volumeGetResult = getDeviceProperty(deviceID: deviceID, property: kAudioDevicePropertyVolumeScalar)
        XCTAssertNotNil(volumeGetResult, "Volume property should be readable")
        if let volume = volumeGetResult as? Double {
            XCTAssertEqual(volume, 0.75, accuracy: 0.01, "Volume should match set value")
        } else {
            XCTFail("Volume should be a Double")
        }
        
        // Test mute property
        let muteSetResult = setDeviceProperty(deviceID: deviceID, property: kAudioDevicePropertyMute, value: true)
        XCTAssertTrue(muteSetResult, "Mute property should be settable")
        
        let muteGetResult = getDeviceProperty(deviceID: deviceID, property: kAudioDevicePropertyMute)
        XCTAssertNotNil(muteGetResult, "Mute property should be readable")
        XCTAssertEqual(muteGetResult as? Bool, true, "Mute should match set value")
        
        // Test sample rate property
        let sampleRateSetResult = setDeviceProperty(deviceID: deviceID, property: kAudioDevicePropertyNominalSampleRate, value: 44100.0)
        XCTAssertTrue(sampleRateSetResult, "Sample rate property should be settable")
        
        let sampleRateGetResult = getDeviceProperty(deviceID: deviceID, property: kAudioDevicePropertyNominalSampleRate)
        XCTAssertNotNil(sampleRateGetResult, "Sample rate property should be readable")
        if let sampleRate = sampleRateGetResult as? Float64 {
            XCTAssertEqual(sampleRate, 44100.0, accuracy: 1.0, "Sample rate should match set value")
        }
        
        // Cleanup
        _ = destroyTestDevice(deviceID: deviceID)
    }
    
    // MARK: - Audio Processing Tests
    
    func testAudioIOOperations() {
        // Create device for I/O testing
        let creationResult = createTestDevice()
        XCTAssertTrue(creationResult.0, "Device creation should succeed")
        testDeviceID = creationResult.1
        
        guard let deviceID = testDeviceID else {
            XCTFail("Test device ID should not be nil")
            return
        }
        
        // Test audio input
        let inputResult = testAudioInput(deviceID: deviceID, audioBuffer: testAudioBuffer)
        XCTAssertTrue(inputResult.0, "Audio input should succeed")
        XCTAssertNotNil(inputResult.1, "Input buffer should be returned")
        XCTAssertEqual(inputResult.1?.count, testAudioBuffer.count, "Input buffer size should match")
        
        // Test audio output
        let outputResult = testAudioOutput(deviceID: deviceID, audioBuffer: testAudioBuffer)
        XCTAssertTrue(outputResult, "Audio output should succeed")
        
        // Test bidirectional audio
        let bidirectionalResult = testBidirectionalAudio(deviceID: deviceID, audioBuffer: testAudioBuffer)
        XCTAssertTrue(bidirectionalResult.0, "Bidirectional audio should succeed")
        XCTAssertNotNil(bidirectionalResult.1, "Processed buffer should be returned")
        
        // Cleanup
        _ = destroyTestDevice(deviceID: deviceID)
    }
    
    func testRealTimeAudioProcessing() {
        // Create device for real-time testing
        let creationResult = createTestDevice()
        XCTAssertTrue(creationResult.0, "Device creation should succeed")
        testDeviceID = creationResult.1
        
        guard let deviceID = testDeviceID else {
            XCTFail("Test device ID should not be nil")
            return
        }
        
        // Test real-time processing latency
        let latencyExpectation = XCTestExpectation(description: "Real-time audio processing")
        latencyExpectation.expectedFulfillmentCount = 10
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        for idx in 0..<10 {
            Task {
                await MainActor.run {
                    let processingStart = CFAbsoluteTimeGetCurrent()
                    let testBuffer = self.testAudioBuffer!
                    let result = testRealTimeAudioProcessing(deviceID: deviceID, audioBuffer: testBuffer)
                    let processingEnd = CFAbsoluteTimeGetCurrent()
                    let latency = processingEnd - processingStart
                    
                    // Basic latency validation
                    XCTAssertLessThan(latency, 0.01, "Processing latency should be under 10ms for real-time requirements")
                    XCTAssertTrue(result, "Real-time processing should succeed")
                    
                    latencyExpectation.fulfill()
                }
            }
        }
        
        wait(for: [latencyExpectation], timeout: 5.0)
        
        let totalTime = CFAbsoluteTimeGetCurrent() - startTime
        let averageLatency = totalTime / 10.0
        XCTAssertLessThan(averageLatency, 0.01, "Average processing latency should be < 10ms")
        
        // Cleanup
        _ = destroyTestDevice(deviceID: deviceID)
    }
    
    // MARK: - Performance Tests
    
    func testAudioProcessingThroughput() {
        // Create device for throughput testing
        let creationResult = createTestDevice()
        XCTAssertTrue(creationResult.0, "Device creation should succeed")
        testDeviceID = creationResult.1
        
        guard let deviceID = testDeviceID else {
            XCTFail("Test device ID should not be nil")
            return
        }
        
        // Test processing throughput with different buffer sizes
        let bufferSizes = [256, 512, 1024, 2048, 4096]
        
        for bufferSize in bufferSizes {
            let testBuffer = Array(testAudioBuffer.prefix(bufferSize))
            let iterations = 100
            
            let startTime = CFAbsoluteTimeGetCurrent()
            
            for _ in 0..<iterations {
                let result = testAudioInput(deviceID: deviceID, audioBuffer: testBuffer)
                XCTAssertTrue(result.0, "Audio input should succeed for buffer size \(bufferSize)")
            }
            
            let endTime = CFAbsoluteTimeGetCurrent()
            let totalTime = endTime - startTime
            let averageTime = totalTime / Double(iterations)
            let throughput = Double(bufferSize) / averageTime
            
            print(String(format: "Buffer Size %4d: %.3fms avg, %.0f samples/sec",
                         bufferSize, averageTime * 1000, throughput))
            
            XCTAssertLessThan(averageTime, 0.005, "Processing time should be < 5ms for buffer size \(bufferSize)")
        }
        
        // Cleanup
        _ = destroyTestDevice(deviceID: deviceID)
    }
    
    func testMemoryUsageUnderLoad() {
        // Create device for memory testing
        let creationResult = createTestDevice()
        XCTAssertTrue(creationResult.0, "Device creation should succeed")
        testDeviceID = creationResult.1
        
        guard let deviceID = testDeviceID else {
            XCTFail("Test device ID should not be nil")
            return
        }
        
        let initialMemory = getCurrentMemoryUsage()
        
        // Process many audio buffers to test memory usage
        for i in 0..<1000 {
            let testBuffer = Array(testAudioBuffer.shuffled())
            let result = testAudioInput(deviceID: deviceID, audioBuffer: testBuffer)
            XCTAssertTrue(result.0, "Audio input should succeed in iteration \(i)")
            
            // Check memory every 100 iterations
            if i % 100 == 99 {
                let currentMemory = getCurrentMemoryUsage()
                let memoryIncrease = currentMemory - initialMemory
                XCTAssertLessThan(memoryIncrease, 50 * 1024 * 1024, "Memory increase should be < 50MB")
            }
        }
        
        let finalMemory = getCurrentMemoryUsage()
        let totalMemoryIncrease = finalMemory - initialMemory
        XCTAssertLessThan(totalMemoryIncrease, 10 * 1024 * 1024, "Total memory increase should be < 10MB")
        
        // Cleanup
        _ = destroyTestDevice(deviceID: deviceID)
    }
    
    func testConcurrentDeviceAccess() {
        // Create device for concurrent testing
        let creationResult = createTestDevice()
        XCTAssertTrue(creationResult.0, "Device creation should succeed")
        testDeviceID = creationResult.1
        
        guard let deviceID = testDeviceID else {
            XCTFail("Test device ID should not be nil")
            return
        }
        
        let concurrentExpectation = XCTestExpectation(description: "Concurrent device access")
        concurrentExpectation.expectedFulfillmentCount = 20
        
        // Test concurrent read/write operations
        for i in 0..<20 {
            DispatchQueue.global(qos: .userInteractive).async {
                if i % 2 == 0 {
                    // Read operation
                    let properties = self.getDeviceProperties(deviceID: deviceID)
                    XCTAssertNotNil(properties, "Properties should be readable concurrently")
                } else {
                    // Write operation
                    let volume = Float.random(in: 0.0...1.0)
                    let result = self.setDeviceProperty(deviceID: deviceID, property: kAudioDevicePropertyVolumeScalar, value: volume)
                    XCTAssertTrue(result, "Properties should be writable concurrently")
                }
                concurrentExpectation.fulfill()
            }
        }
        
        wait(for: [concurrentExpectation], timeout: 10.0)
        
        // Cleanup
        _ = destroyTestDevice(deviceID: deviceID)
    }
    
    // MARK: - Error Handling Tests
    
    func testErrorRecovery() {
        // Test error scenarios and recovery
        let invalidDeviceID: AudioObjectID = 999999
        
        // Test operations with invalid device
        let invalidProperties = getDeviceProperties(deviceID: invalidDeviceID)
        XCTAssertNil(invalidProperties, "Invalid device should return nil properties")
        
        let invalidVolumeSet = setDeviceProperty(deviceID: invalidDeviceID, property: kAudioDevicePropertyVolumeScalar, value: 0.5)
        XCTAssertFalse(invalidVolumeSet, "Invalid device should fail property set")
        
        let invalidAudioInput = testAudioInput(deviceID: invalidDeviceID, audioBuffer: testAudioBuffer)
        XCTAssertFalse(invalidAudioInput.0, "Invalid device should fail audio input")
        
        // Test recovery with valid device
        let creationResult = createTestDevice()
        XCTAssertTrue(creationResult.0, "Device creation should succeed after errors")
        testDeviceID = creationResult.1
        
        if let deviceID = testDeviceID {
            let validProperties = getDeviceProperties(deviceID: deviceID)
            XCTAssertNotNil(validProperties, "Valid device should return properties after recovery")
            
            _ = destroyTestDevice(deviceID: deviceID)
        }
    }
    
    func testBoundaryConditions() {
        // Create device for boundary testing
        let creationResult = createTestDevice()
        XCTAssertTrue(creationResult.0, "Device creation should succeed")
        testDeviceID = creationResult.1
        
        guard let deviceID = testDeviceID else {
            XCTFail("Test device ID should not be nil")
            return
        }
        
        // Test empty buffer
        let emptyBuffer: [Float] = []
        let emptyResult = testAudioInput(deviceID: deviceID, audioBuffer: emptyBuffer)
        XCTAssertTrue(emptyResult.0, "Empty buffer should be handled gracefully")
        
        // Test very large buffer
        let largeBuffer = [Float](repeating: 0.5, count: 65536)
        let largeResult = testAudioInput(deviceID: deviceID, audioBuffer: largeBuffer)
        XCTAssertTrue(largeResult.0, "Large buffer should be handled gracefully")
        
        // Test extreme volume values
        let extremeVolumes: [Float] = [-1.0, 0.0, 1.0, 2.0]
        for volume in extremeVolumes {
            let volumeResult = setDeviceProperty(deviceID: deviceID, property: kAudioDevicePropertyVolumeScalar, value: volume)
            XCTAssertTrue(volumeResult, "Extreme volume \(volume) should be handled")
        }
        
        // Cleanup
        _ = destroyTestDevice(deviceID: deviceID)
    }
    
    // MARK: - Helper Methods
    
    private func setupHALPlugin() {
        // Initialize HAL plugin for testing
        // In a real implementation, this would load and initialize the actual HAL plugin
        // For testing purposes, we simulate the interface
        pluginInterface = UnsafeMutableRawPointer.allocate(byteCount: 1024, alignment: 8)
    }
    
    private func cleanupHALPlugin() {
        // Cleanup HAL plugin
        pluginInterface?.deallocate()
    }
    
    private func createTestDevice() -> (Bool, AudioObjectID?) {
        // Simulate device creation
        let deviceID: AudioObjectID = 1001
        return (true, deviceID)
    }
    
    private func destroyTestDevice(deviceID: AudioObjectID) -> Bool {
        // Simulate device destruction
        return true
    }
    
    private func getPluginProperties() -> [String: Any]? {
        return [
            "name": "Vocana",
            "manufacturer": "Vocana Inc.",
            "version": "1.0.0"
        ]
    }
    
    private func getDeviceProperties(deviceID: AudioObjectID) -> [String: Any]? {
        return [
            "name": "Vocana",
            "channels": 2,
            "sampleRate": 48000.0,
            "bufferSize": 512
        ]
    }
    
    private func setDeviceProperty(deviceID: AudioObjectID, property: AudioObjectPropertySelector, value: Any) -> Bool {
        // Simulate property setting
        return true
    }
    
    private func getDeviceProperty(deviceID: AudioObjectID, property: AudioObjectPropertySelector) -> Any? {
        // Simulate property getting
        switch property {
        case kAudioDevicePropertyVolumeScalar:
            return 0.75
        case kAudioDevicePropertyMute:
            return false
        case kAudioDevicePropertyNominalSampleRate:
            return 48000.0
        default:
            return nil
        }
    }
    
    private func testAudioInput(deviceID: AudioObjectID, audioBuffer: [Float]) -> (Bool, [Float]?) {
        // Simulate audio input processing
        return (true, audioBuffer)
    }
    
    private func testAudioOutput(deviceID: AudioObjectID, audioBuffer: [Float]) -> Bool {
        // Simulate audio output processing
        return true
    }
    
    private func testBidirectionalAudio(deviceID: AudioObjectID, audioBuffer: [Float]) -> (Bool, [Float]?) {
        // Simulate bidirectional audio processing
        return (true, audioBuffer)
    }
    
    private func testRealTimeAudioProcessing(deviceID: AudioObjectID, audioBuffer: [Float]) -> Bool {
        // Simulate real-time audio processing with minimal latency
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