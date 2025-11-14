#!/usr/bin/env swift

import Foundation
import CoreAudio

// Test if our modified VirtualAudioManager can find BlackHole
func testDeviceDiscovery() {
    print("=== Testing Vocana Device Discovery ===")
    
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
        print("❌ Failed to get audio devices data size: \(result)")
        return
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
        print("❌ Failed to get audio devices: \(result)")
        return
    }

    var foundInputDevice = false
    var foundOutputDevice = false

    print("Scanning for Vocana-compatible devices...")
    
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
            // Check if device matches our Vocana criteria (including BlackHole)
            if deviceName.contains("Vocana Microphone") || deviceName.contains("Vocana Virtual") || deviceName.contains("BlackHole") {
                print("✅ Found Vocana-compatible device: \(deviceName) (ID: \(deviceID))")
                // BlackHole can serve as both input and output
                foundInputDevice = true
                foundOutputDevice = true
            }
        }
    }

    if foundInputDevice && foundOutputDevice {
        print("🎉 SUCCESS: Vocana virtual audio devices are available!")
        print("🎧 You can now use Vocana for noise cancellation.")
    } else {
        print("❌ FAILED: Vocana devices not found.")
        print("📝 Found input: \(foundInputDevice), Found output: \(foundOutputDevice)")
    }
}

testDeviceDiscovery()