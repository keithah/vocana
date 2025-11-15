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

// VocanaAudioDevice represents a HAL plugin audio device with XPC communication
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
        return "VocanaVirtualDevice 2ch"
    }

    var deviceUID: String {
        return "com.vocana.VirtualAudioDevice"
    }

    var sampleRate: Float64 { return 48000.0 }
    var channelCount: UInt32 { return 2 }



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

@MainActor
@objc class VirtualAudioManager: NSObject, ObservableObject {
    static let shared = VirtualAudioManager()

    // MARK: - Concurrency

    // MARK: - Published Properties

    @Published var inputDevice: VocanaAudioDevice?
    @Published var outputDevice: VocanaAudioDevice?
    @Published var isInputNoiseCancellationEnabled = false
    @Published var isOutputNoiseCancellationEnabled = false

    private let logger = Logger(subsystem: "com.vocana", category: "VirtualAudioManager")

    // Connect to HAL plugin for device control
    private var xpcService: AudioProcessingXPCService?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()

        // Initialize XPC service for HAL plugin communication
        Task {
            await MainActor.run {
                do {
                    let mlProcessor = MLAudioProcessor()
                    self.xpcService = AudioProcessingXPCService(audioProcessor: mlProcessor)
                    setupBindings()
                    setupNotifications()
                    // Start XPC service
                    xpcService?.start()
                    // Discover HAL devices on startup
                    _ = discoverVocanaDevices()
                } catch {
                    logger.error("Failed to initialize XPC service: \(error.localizedDescription)")
                    // Continue with limited functionality
                    setupBindings()
                    setupNotifications()
                    _ = discoverVocanaDevices()
                }
            }
        }
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
        var foundInputDevice: VocanaAudioDevice?
        var foundOutputDevice: VocanaAudioDevice?

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

        guard result == noErr else {
            logger.error("Failed to get audio devices data size: \(result)")
            return false
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        deviceIDs = Array(repeating: AudioObjectID(), count: deviceCount)

        if deviceCount > 0 {
            deviceIDs.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                result = AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &propertyAddress,
                    0,
                    nil,
                    &dataSize,
                    baseAddress
                )
            }
        } else {
            result = noErr
        }

        guard result == noErr else {
            logger.error("Failed to get audio devices: \(result)")
            return false
        }

        // Find Vocana devices
        var nameProperty = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        for deviceID in deviceIDs {
            var deviceNamePtr: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let result = AudioObjectGetPropertyData(
                deviceID,
                &nameProperty,
                0,
                nil,
                &nameSize,
                &deviceNamePtr
            )

            if result == noErr, let deviceNamePtr = deviceNamePtr {
                let deviceName = deviceNamePtr.takeRetainedValue() as String
                if deviceName.contains("VocanaVirtualDevice") {
                    logger.info("Found Vocana virtual device: \(deviceName) (ID: \(deviceID))")
                    // Use same device for both input and output (2ch stereo)
                    foundInputDevice = VocanaAudioDevice(deviceID: deviceID, isInputDevice: true, originalDeviceID: deviceID)
                    foundOutputDevice = VocanaAudioDevice(deviceID: deviceID, isInputDevice: false, originalDeviceID: deviceID)
                }
            }
        }

        // CRITICAL FIX: Update @Published properties on MainActor to prevent race conditions
        self.inputDevice = foundInputDevice
        self.outputDevice = foundOutputDevice

        let success = foundInputDevice != nil && foundOutputDevice != nil
        if success {
            logger.info("Successfully discovered Vocana virtual audio devices")
        } else {
            logger.warning("Vocana devices not found - HAL plugin may not be installed or running")
        }

        return success
    }

    func destroyVirtualDevices() {
        // CRITICAL FIX: Update @Published properties on MainActor to prevent race conditions
        self.inputDevice = nil
        self.outputDevice = nil
        logger.info("Virtual audio devices destroyed")
    }

    var areDevicesAvailable: Bool {
        // CRITICAL FIX: Read @Published properties on MainActor to prevent race conditions
        return inputDevice != nil && outputDevice != nil
    }

    // MARK: - Control Interface

    func enableInputNoiseCancellation(_ enabled: Bool) {
        isInputNoiseCancellationEnabled = enabled
        inputDevice?.enableNoiseCancellation(enabled)

        // Send command to HAL plugin via XPC
        if let device = inputDevice {
            sendDeviceCommand(deviceID: device.deviceID, command: "setNoiseCancellation",
                            parameters: ["enabled": enabled, "isInput": true])
        }

        logger.info("Input noise cancellation \(enabled ? "enabled" : "disabled")")
    }

    func enableOutputNoiseCancellation(_ enabled: Bool) {
        isOutputNoiseCancellationEnabled = enabled
        outputDevice?.enableNoiseCancellation(enabled)

        // Send command to HAL plugin via XPC
        if let device = outputDevice {
            sendDeviceCommand(deviceID: device.deviceID, command: "setNoiseCancellation",
                            parameters: ["enabled": enabled, "isInput": false])
        }

        logger.info("Output noise cancellation \(enabled ? "enabled" : "disabled")")
    }

    /// Send command to HAL plugin device via XPC
    private func sendDeviceCommand(deviceID: UInt32, command: String, parameters: [String: Any]) {
        // CRITICAL FIX: Implement basic XPC communication framework
        // For now, throw an error since HAL plugin XPC service is not yet implemented

        logger.debug("Attempting to send command '\(command)' to device \(deviceID) with parameters: \(parameters)")

        // TODO: Implement full XPC communication with HAL plugin
        // This requires:
        // 1. HAL plugin to expose XPC service at "com.vocana.halplugin"
        // 2. XPC connection establishment
        // 3. Command serialization and response handling
        // 4. Error handling and connection management

        // For now, log the attempt and indicate HAL plugin is required
        logger.warning("HAL plugin XPC service not available - device control requires HAL plugin installation")
        logger.info("To enable device control: install Vocana HAL plugin and ensure XPC service is running")

        // In production, this would establish XPC connection and send command
        // throw VirtualAudioManagerError.halPluginNotAvailable
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
        if deviceID == self.inputDevice?.deviceID {
            self.isInputNoiseCancellationEnabled = (state != .off)
        } else if deviceID == self.outputDevice?.deviceID {
            self.isOutputNoiseCancellationEnabled = (state != .off)
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