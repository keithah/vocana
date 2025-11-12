#!/usr/bin/env swift

import Foundation
import CoreAudio
import AudioToolbox

print("🔍 Scanning for Vocana audio devices...")

// Get number of audio devices
var deviceCount: UInt32 = 0
var size = UInt32(MemoryLayout<AudioDeviceID>.size * Int(AudioDeviceID(0)))

AudioHardwareGetPropertyInfo(kAudioHardwarePropertyDevices, &size, nil)
deviceCount = UInt32(size) / UInt32(MemoryLayout<AudioDeviceID>.size)

var devices = [AudioDeviceID](repeating: AudioDeviceID(), count: Int(deviceCount))
AudioHardwareGetProperty(kAudioHardwarePropertyDevices, &size, &devices)

print("🎤 Audio devices found: \(deviceCount)")

for deviceID in devices {
    // Get device name
    var nameSize = UInt32(MemoryLayout<CFString>.size)
    var deviceName: CFString = "" as CFString

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    AudioObjectGetPropertyData(deviceID, &address, 0, nil, &nameSize, &deviceName)

    let name = deviceName as String
    print("  - \(name)")

    if name.contains("Vocana") {
        print("    ✅ Found Vocana device!")
    }
}

if deviceCount == 0 {
    print("❌ No audio devices found")
} else if !devices.contains(where: {
    var nameSize = UInt32(MemoryLayout<CFString>.size)
    var deviceName: CFString = "" as CFString
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyData($0, &address, 0, nil, &nameSize, &deviceName)
    return (deviceName as String).contains("Vocana")
}) {
    print("\n❌ Vocana device not found in device list")
}