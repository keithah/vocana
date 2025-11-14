#!/usr/bin/env swift

import Foundation
import CoreAudio
import AudioToolbox

// Simple test to discover audio devices and check for VocanaVirtualDevice
func testAudioDeviceDiscovery() {
    print("=== Vocana Virtual Audio Device Test ===")
    
    var deviceListSize: UInt32 = 0
    var propAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var result = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &propAddress,
        0,
        nil,
        &deviceListSize
    )
    
    if result != noErr {
        print("❌ Failed to get device list size: \(result)")
        return
    }
    
    let deviceCount = Int(deviceListSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
    
    result = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propAddress,
        0,
        nil,
        &deviceListSize,
        &deviceIDs
    )
    
    if result != noErr {
        print("❌ Failed to get device list: \(result)")
        return
    }
    
    print("📱 Found \(deviceCount) audio devices:")
    
    var foundVocanaDevice = false
    
    for (index, deviceID) in deviceIDs.enumerated() {
        var deviceName: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var propAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        result = AudioObjectGetPropertyData(
            deviceID,
            &propAddress,
            0,
            nil,
            &nameSize,
            &deviceName
        )
        
        if result == noErr {
            let deviceNameStr = deviceName as String
            print("  \(index + 1). \(deviceNameStr) (ID: \(deviceID))")
            
            if deviceNameStr.contains("Vocana") || deviceNameStr.contains("Virtual") {
                foundVocanaDevice = true
                print("  ✅ Found Vocana device!")
                
                // Get additional info about the Vocana device
                getDeviceInfo(deviceID)
            }
        }
    }
    
    if !foundVocanaDevice {
        print("❌ VocanaVirtualDevice not found in system")
        print("💡 The driver may need to be installed with:")
        print("   sudo cp -r VocanaVirtualDevice.driver /Library/Audio/Plug-Ins/HAL/")
        print("   sudo launchctl kickstart -k system/com.apple.audio.coreaudiod")
    }
}

func getDeviceInfo(_ deviceID: AudioDeviceID) {
    print("    📋 Device Details:")
    
    // Check if it's an input device
    var inputStreams: UInt32 = 0
    var streamSize = UInt32(MemoryLayout<UInt32>.size)
    var propAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    
    let result = AudioObjectGetPropertyData(
        deviceID,
        &propAddress,
        0,
        nil,
        &streamSize,
        &inputStreams
    )
    
    if result == noErr {
        print("      🎤 Input streams: \(inputStreams)")
    }
    
    // Check if it's an output device
    propAddress.mScope = kAudioObjectPropertyScopeOutput
    let outputResult = AudioObjectGetPropertyData(
        deviceID,
        &propAddress,
        0,
        nil,
        &streamSize,
        &inputStreams
    )
    
    if outputResult == noErr {
        print("      🔊 Output streams: \(inputStreams)")
    }
}

// Run the test
testAudioDeviceDiscovery()
print("\n=== Test Complete ===")