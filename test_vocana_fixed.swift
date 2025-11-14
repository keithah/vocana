#!/usr/bin/env swift

import Foundation
import CoreAudio

print("🎤 Testing Vocana Audio Devices After Fix...")
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
        if deviceName.contains("Vocana") || deviceName.contains("Virtual") {
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
            
            // Check if device is alive
            var isAlive: UInt32 = 0
            var aliveSize = UInt32(MemoryLayout<UInt32>.size)
            var aliveProperty = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            if AudioObjectGetPropertyData(deviceID, &aliveProperty, 0, nil, &aliveSize, &isAlive) == noErr {
                print("   💓 Device alive: \(isAlive == 1 ? "Yes" : "No")")
            }
            
            // Check if device is running
            var isRunning: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningProperty = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunning,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            if AudioObjectGetPropertyData(deviceID, &runningProperty, 0, nil, &runningSize, &isRunning) == noErr {
                print("   🏃 Device running: \(isRunning == 1 ? "Yes" : "No")")
            }
        } else {
            print("   \(deviceName)")
        }
    }
}

print("")
if vocanaDevicesFound > 0 {
    print("🎉 SUCCESS: Vocana HAL plugin is working!")
    print("💡 You should now see Vocana devices in:")
    print("   - System Settings → Sound")
    print("   - Audio MIDI Setup") 
    print("   - Any conferencing app (Zoom, Teams, etc.)")
    print("")
    print("🧪 To test with a real app:")
    print("   1. Open System Settings → Sound")
    print("   2. Select 'Vocana Virtual Audio' as input/output")
    print("   3. Open QuickTime Player → New Audio Recording")
    print("   4. Select 'Vocana Virtual Audio' as microphone")
    print("   5. Record and test!")
} else {
    print("❌ ISSUE: No Vocana devices found")
    print("💡 Try these troubleshooting steps:")
    print("   1. Restart Core Audio:")
    print("      sudo launchctl kickstart -k system/com.apple.audio.coreaudiod")
    print("   2. Check plugin installation:")
    print("      ls -la /Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver")
    print("   3. Check system logs for plugin errors:")
    print("      log show --predicate 'subsystem == \"com.apple.audio\"' --last 5m")
}