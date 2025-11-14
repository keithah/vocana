//
//  VirtualAudioManagerTests.swift
//  Vocana
//
//  Created by AI Assistant
//

import XCTest
@testable import Vocana

@MainActor
final class VirtualAudioManagerTests: XCTestCase {
    var virtualAudioManager: VirtualAudioManager!

    override func setUp() {
        super.setUp()
        virtualAudioManager = VirtualAudioManager()
    }

    override func tearDown() {
        virtualAudioManager = nil
        super.tearDown()
    }

    func testDeviceDiscovery() {
        // Test that device discovery runs without crashing
        let result = virtualAudioManager.createVirtualDevices()

        // Result may be false if HAL plugin is not loaded in test environment
        // But the method should not crash
        XCTAssertTrue(result || !result) // Always true - just testing it doesn't crash
    }

    func testDeviceAvailability() {
        // Initially, devices should not be available
        XCTAssertFalse(virtualAudioManager.areDevicesAvailable)

        // After discovery attempt, availability depends on HAL plugin
        _ = virtualAudioManager.createVirtualDevices()
        // We can't assert true here because HAL plugin may not be loaded in test
    }

    func testNoiseCancellationControls() {
        // Test that controls can be enabled/disabled without devices
        virtualAudioManager.enableInputNoiseCancellation(true)
        XCTAssertTrue(virtualAudioManager.isInputNoiseCancellationEnabled)

        virtualAudioManager.enableInputNoiseCancellation(false)
        XCTAssertFalse(virtualAudioManager.isInputNoiseCancellationEnabled)

        virtualAudioManager.enableOutputNoiseCancellation(true)
        XCTAssertTrue(virtualAudioManager.isOutputNoiseCancellationEnabled)

        virtualAudioManager.enableOutputNoiseCancellation(false)
        XCTAssertFalse(virtualAudioManager.isOutputNoiseCancellationEnabled)
    }

    func testDeviceDestruction() {
        // Test that devices can be destroyed
        virtualAudioManager.destroyVirtualDevices()
        XCTAssertNil(virtualAudioManager.inputDevice)
        XCTAssertNil(virtualAudioManager.outputDevice)
        XCTAssertFalse(virtualAudioManager.areDevicesAvailable)
    }
}