#!/usr/bin/env swift

import Foundation
import CoreAudio

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
    print("Failed to get audio devices data size: \(result)")
    exit(1)
}

let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
deviceIDs = Array(repeating: AudioObjectID(), count: deviceCount)

result = AudioObjectGetPropertyData(
    AudioObjectID(kAudioObjectSystemObject),
    &propertyAddress,
    0,
    nil,
    &dataSize,
    &deviceIDs
)

guard result == noErr else {
    print("Failed to get audio devices: \(result)")
    exit(1)
}

print("=== Audio Devices ===")
for deviceID in deviceIDs {
    var deviceName: CFString?
    var nameSize = UInt32(MemoryLayout<CFString>.size)
    var nameProperty = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    result = AudioObjectGetPropertyData(
        deviceID,
        &nameProperty,
        0,
        nil,
        &nameSize,
        &deviceName
    )

    if result == noErr, let deviceName = deviceName as String? {
        var deviceUID: CFString?
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uidProperty = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectGetPropertyData(
            deviceID,
            &uidProperty,
            0,
            nil,
            &uidSize,
            &deviceUID
        )

        let uidString = deviceUID as String? ?? "Unknown UID"
        
        if deviceName.contains("Vocana") || deviceName.contains("BlackHole") || deviceName.contains("Built-in") {
            print("Device: \(deviceName) (ID: \(deviceID), UID: \(uidString))")
        }
    }
}

print("\n=== Looking for Vocana devices ===")
let vocanaDevices = deviceIDs.filter { deviceID in
    var deviceName: CFString?
    var nameSize = UInt32(MemoryLayout<CFString>.size)
    var nameProperty = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    let result = AudioObjectGetPropertyData(
        deviceID,
        &nameProperty,
        0,
        nil,
        &nameSize,
        &deviceName
    )

    if result == noErr, let deviceName = deviceName as String? {
        return deviceName.contains("Vocana")
    }
    return false
}

if vocanaDevices.isEmpty {
    print("No Vocana devices found!")
} else {
    print("Found \(vocanaDevices.count) Vocana device(s)")
}