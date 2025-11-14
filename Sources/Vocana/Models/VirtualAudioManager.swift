//
//  VirtualAudioManager.swift
//  Vocana Virtual Audio Manager
//
//  Created by Vocana Team.
//  Copyright © 2025 Vocana. All rights reserved.
//

import Foundation
import Combine
import AppKit
import CoreAudio
import OSLog

// Stub VocanaAudioDevice for UI development until HAL plugin is implemented
class VocanaAudioDevice: NSObject, ObservableObject {
    let deviceID: UInt32
    let isInputDevice: Bool
    var noiseCancellationState: VocanaNoiseCancellationState = .off
    var currentApplication: String?
    var registeredApplicationsSet: Set<String> = []

    init(deviceID: UInt32, isInputDevice: Bool, originalDeviceID: UInt32) {
        self.deviceID = deviceID
        self.isInputDevice = isInputDevice
        super.init()
    }

    var deviceName: String {
        return isInputDevice ? "Vocana Microphone" : "Vocana Speaker"
    }

    var deviceUID: String {
        return isInputDevice ? "com.vocana.audio.input" : "com.vocana.audio.output"
    }

    var sampleRate: Float64 { return 48000.0 }
    var channelCount: UInt32 { return 2 }

    func processAudioBuffer(_ audioBuffer: Any, frameCount: UInt32, format: Any) {
        // TODO: Implement audio processing when ML model is integrated
    }

    func enableNoiseCancellation(_ enabled: Bool) {
        noiseCancellationState = enabled ? .on : .off
    }

    func setNoiseCancellationState(_ state: VocanaNoiseCancellationState) {
        noiseCancellationState = state
    }

    func registerApplication(_ bundleIdentifier: String) {
        registeredApplicationsSet.insert(bundleIdentifier)
    }

    func unregisterApplication(_ bundleIdentifier: String) {
        registeredApplicationsSet.remove(bundleIdentifier)
    }

    func isApplicationRegistered(_ bundleIdentifier: String) -> Bool {
        return registeredApplicationsSet.contains(bundleIdentifier)
    }
}

enum VocanaNoiseCancellationState: UInt32 {
    case off = 0
    case on = 1
    case processing = 2
}

@objc class VirtualAudioManager: NSObject, ObservableObject {
    static let shared = VirtualAudioManager()

    @Published var inputDevice: VocanaAudioDevice?
    @Published var outputDevice: VocanaAudioDevice?
    @Published var isInputNoiseCancellationEnabled = false
    @Published var isOutputNoiseCancellationEnabled = false

    private let logger = Logger(subsystem: "com.vocana", category: "VirtualAudioManager")

    // TODO: Replace with actual VocanaAudioManager when HAL plugin is implemented
    // private let objcManager = VocanaAudioManager.shared()
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        setupBindings()
        setupNotifications()
        // Discover HAL devices on startup
        _ = discoverVocanaDevices()
    }

    // MARK: - Setup

    private func setupBindings() {
        // Monitor device state changes
        NotificationCenter.default.publisher(for: NSNotification.Name("VocanaDeviceStateChanged"))
            .sink { [weak self] notification in
                self?.handleDeviceStateChange(notification)
            }
            .store(in: &cancellables)
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    // MARK: - Device Management

    func createVirtualDevices() -> Bool {
        // HAL plugin handles actual device creation - this discovers existing HAL devices
        return discoverVocanaDevices()
    }

    private func discoverVocanaDevices() -> Bool {
        var foundInputDevice = false
        var foundOutputDevice = false

        // Get all audio devices
        var deviceIDs = [AudioObjectID]()
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var result = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        if result == kAudioHardwareNoError {
            let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
            deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)

            result = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                0,
                nil,
                &dataSize,
                &deviceIDs
            )
        }

        if result == kAudioHardwareNoError {
            for deviceID in deviceIDs {
                // Get device UID
                var uidPropertyAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceUID,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )

                var uidSize: UInt32 = 0
                result = AudioObjectGetPropertyDataSize(
                    deviceID,
                    &uidPropertyAddress,
                    0,
                    nil,
                    &uidSize
                )

                if result == kAudioHardwareNoError {
                    let uidBuffer = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
                    defer { uidBuffer.deallocate() }

                    result = AudioObjectGetPropertyData(
                        deviceID,
                        &uidPropertyAddress,
                        0,
                        nil,
                        &uidSize,
                        uidBuffer
                    )

                    if result == kAudioHardwareNoError, let deviceUID = uidBuffer.pointee {
                        let uid = deviceUID as String
                        // Check if this is a Vocana device
                        if uid.contains("VocanaVirtualDevice2ch_UID") {
                            // First device is input, second device (_2_UID) is output
                            if uid.contains("_2_UID") {
                                outputDevice = VocanaAudioDevice(deviceID: deviceID, isInputDevice: false, originalDeviceID: deviceID)
                                foundOutputDevice = true
                                logger.info("Discovered Vocana output device: \(uid)")
                            } else {
                                inputDevice = VocanaAudioDevice(deviceID: deviceID, isInputDevice: true, originalDeviceID: deviceID)
                                foundInputDevice = true
                                logger.info("Discovered Vocana input device: \(uid)")
                            }
                        }
                    }
                }
            }
        }

        let success = foundInputDevice && foundOutputDevice
        if success {
            logger.info("Successfully discovered Vocana HAL devices")
            NotificationCenter.default.post(name: NSNotification.Name("VocanaDeviceStateChanged"), object: nil)
        } else {
            logger.warning("Failed to discover Vocana HAL devices - HAL plugin may not be loaded")
            if !foundInputDevice {
                logger.warning("Vocana input device not found")
            }
            if !foundOutputDevice {
                logger.warning("Vocana output device not found")
            }
        }

        return success
    }

    func destroyVirtualDevices() {
        inputDevice = nil
        outputDevice = nil
        logger.info("Virtual audio devices destroyed")
    }

    var areDevicesAvailable: Bool {
        return inputDevice != nil && outputDevice != nil
    }

    // MARK: - Control Interface

    func enableInputNoiseCancellation(_ enabled: Bool) {
        isInputNoiseCancellationEnabled = enabled
        inputDevice?.setNoiseCancellationState(enabled ? .on : .off)
        logger.info("Input noise cancellation \(enabled ? "enabled" : "disabled")")
    }

    func enableOutputNoiseCancellation(_ enabled: Bool) {
        isOutputNoiseCancellationEnabled = enabled
        outputDevice?.setNoiseCancellationState(enabled ? .on : .off)
        logger.info("Output noise cancellation \(enabled ? "enabled" : "disabled")")
    }

    // MARK: - Application Detection

    func startApplicationMonitoring() {
        // TODO: Implement when HAL plugin entitlements are obtained
        // Monitor for conferencing apps and automatically route audio
    }

    func stopApplicationMonitoring() {
        // TODO: Implement when HAL plugin entitlements are obtained
    }

    var activeConferencingApps: [String] {
        // TODO: Implement when HAL plugin entitlements are obtained
        // Return list of active conferencing applications
        return []
    }

    // MARK: - Private Methods

    private func updateDeviceReferences() {
        // TODO: Implement when HAL plugin entitlements are obtained
        // inputDevice = objcManager.inputDevice
        // outputDevice = objcManager.outputDevice
        // isInputNoiseCancellationEnabled = objcManager.isInputNoiseCancellationEnabled()
        // isOutputNoiseCancellationEnabled = objcManager.isOutputNoiseCancellationEnabled()
    }

    private func handleDeviceStateChange(_ notification: Notification) {
        guard let deviceID = notification.userInfo?["deviceID"] as? UInt32,
              let stateValue = notification.userInfo?["state"] as? UInt32,
              let state = VocanaNoiseCancellationState(rawValue: stateValue) else {
            return
        }

        // Update UI state based on device changes
        DispatchQueue.main.async {
            if deviceID == self.inputDevice?.deviceID {
                self.isInputNoiseCancellationEnabled = (state != .off)
            } else if deviceID == self.outputDevice?.deviceID {
                self.isOutputNoiseCancellationEnabled = (state != .off)
            }
        }
    }

    @objc private func applicationDidBecomeActive() {
        // Refresh device state when app becomes active
        updateDeviceReferences()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        cancellables.removeAll()
    }
}

// MARK: - VocanaAudioDevice Extensions

// Note: registeredApplications is not used in the stub implementation
// When HAL plugin is implemented, this will be replaced with actual functionality