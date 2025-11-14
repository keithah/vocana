#!/usr/bin/env swift

import Foundation
import CoreAudio

print("🎤 Testing Vocana Audio Devices...")
print("")

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
    print("❌ Failed to get audio devices data size: \(result)")
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
    print("❌ Failed to get audio devices: \(result)")
    exit(1)
}

print("🔍 Found \(deviceCount) audio devices:")
print("")

var vocanaDevicesFound = 0

for deviceID in deviceIDs {
    var deviceName: CFString? = nil
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
            print("✅ \(deviceName) (ID: \(deviceID))")
            vocanaDevicesFound += 1
            
            // Get device capabilities
            var streamsSize: UInt32 = 0
            var streamsProperty = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            
            if AudioObjectGetPropertyDataSize(deviceID, &streamsProperty, 0, nil, &streamsSize) == noErr {
                let streamCount = Int(streamsSize) / MemoryLayout<AudioStreamID>.size
                print("   📡 Input streams: \(streamCount)")
            }
            
            streamsProperty.mScope = kAudioObjectPropertyScopeOutput
            if AudioObjectGetPropertyDataSize(deviceID, &streamsProperty, 0, nil, &streamsSize) == noErr {
                let streamCount = Int(streamsSize) / MemoryLayout<AudioStreamID>.size
                print("   🔊 Output streams: \(streamCount)")
            }
        } else {
            print("   \(deviceName)")
        }
    }
}

print("")
if vocanaDevicesFound > 0 {
    print("🎉 SUCCESS: Vocana HAL plugin is installed and working!")
    print("💡 You can now select Vocana devices in:")
    print("   - System Settings → Sound")
    print("   - Audio MIDI Setup")
    print("   - Any conferencing app (Zoom, Teams, etc.)")
} else {
    print("❌ ISSUE: No Vocana devices found")
    print("💡 Try restarting Core Audio:")
    print("   sudo launchctl kickstart -k system/com.apple.audio.coreaudiod")
}