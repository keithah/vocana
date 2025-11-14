#!/usr/bin/env swift

import Foundation
import CoreAudio

print("🎯 Setting up Vocana with BlackHole...")
print("")

// Check if BlackHole is available
func findBlackHoleDevice() -> AudioObjectID? {
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
    
    guard result == noErr else { return nil }
    
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
    
    guard result == noErr else { return nil }
    
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
            if deviceName.contains("BlackHole") {
                return deviceID
            }
        }
    }
    
    return nil
}

if let blackHoleID = findBlackHoleDevice() {
    print("✅ Found BlackHole device: \(blackHoleID)")
    print("")
    print("🎧 Setup Instructions:")
    print("1. Open System Settings → Sound")
    print("2. Set 'BlackHole 2ch' as Output device")
    print("3. Set your microphone as Input device")
    print("4. Start Vocana app - it will process BlackHole audio")
    print("5. In conferencing apps, select 'BlackHole 2ch' as microphone")
    print("")
    print("🔊 Audio Flow:")
    print("Microphone → System Output → BlackHole → Vocana Processing → Conferencing App")
    print("")
    print("💡 This setup uses BlackHole as a virtual audio cable to route")
    print("   audio through Vocana's AI noise cancellation.")
    
    // Test if we can get BlackHole properties
    var isAlive: UInt32 = 0
    var aliveSize = UInt32(MemoryLayout<UInt32>.size)
    var aliveProperty = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    
    let result = AudioObjectGetPropertyData(
        blackHoleID,
        &aliveProperty,
        0,
        nil,
        &aliveSize,
        &isAlive
    )
    
    if result == noErr {
        print("✅ BlackHole device is alive and ready!")
    } else {
        print("⚠️  BlackHole device may have issues: \(result)")
    }
    
} else {
    print("❌ BlackHole not found. Please install BlackHole first:")
    print("   brew install blackhole-2ch")
    print("   Or download from: https://github.com/ExistentialAudio/BlackHole")
}

print("")
print("🚀 Once configured, start Vocana app and test in any conferencing app!")