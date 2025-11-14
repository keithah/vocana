#!/usr/bin/env swift

import Foundation
import CoreAudio

// Test if HAL plugin is creating devices
func testHALPluginDevices() {
    print("=== Testing HAL Plugin Devices ===")
    
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

    print("Scanning for Vocana HAL plugin devices...")
    var foundVocanaDevices = 0
    
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
            if deviceName.contains("Vocana") {
                print("✅ Found Vocana device: \(deviceName) (ID: \(deviceID))")
                foundVocanaDevices += 1
                
                // Test if we can get basic properties
                testDeviceProperties(deviceID: deviceID, deviceName: deviceName)
            }
        }
    }

    if foundVocanaDevices > 0 {
        print("🎉 SUCCESS: Found \(foundVocanaDevices) Vocana device(s) from HAL plugin!")
    } else {
        print("❌ FAILED: No Vocana HAL plugin devices found.")
        print("🔧 Plugin may not be loaded or has issues.")
    }
}

func testDeviceProperties(deviceID: AudioObjectID, deviceName: String) {
    print("  Testing properties for \(deviceName):")
    
    // Test device alive property
    var isAlive: UInt32 = 0
    var aliveSize = UInt32(MemoryLayout<UInt32>.size)
    var aliveProperty = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    
    let result = AudioObjectGetPropertyData(
        deviceID,
        &aliveProperty,
        0,
        nil,
        &aliveSize,
        &isAlive
    )
    
    if result == noErr {
        print("    ✅ Device is alive: \(isAlive > 0)")
    } else {
        print("    ❌ Cannot check if device is alive: \(result)")
    }
    
    // Test streams property
    var streamIDs = [AudioObjectID]()
    var streamsSize = UInt32(0)
    var streamsProperty = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    
    var streamsResult = AudioObjectGetPropertyDataSize(
        deviceID,
        &streamsProperty,
        0,
        nil,
        &streamsSize
    )
    
    if streamsResult == noErr {
        let streamCount = Int(streamsSize) / MemoryLayout<AudioObjectID>.size
        streamIDs = Array(repeating: AudioObjectID(), count: streamCount)
        
        streamsResult = AudioObjectGetPropertyData(
            deviceID,
            &streamsProperty,
            0,
            nil,
            &streamsSize,
            &streamIDs
        )
        
        if streamsResult == noErr {
            print("    ✅ Has \(streamCount) audio stream(s)")
        } else {
            print("    ❌ Cannot get streams: \(streamsResult)")
        }
    } else {
        print("    ❌ Cannot get streams size: \(streamsResult)")
    }
}

testHALPluginDevices()