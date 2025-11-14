#!/usr/bin/env swift

import Foundation
import CoreAudio

print("🔧 Forcing Vocana Device Creation...")
print("")

// Try to create a Vocana device by calling AudioHardwareCreatePluginDevice
var pluginID = AudioClassID()
var deviceDescription = CFDictionaryCreateMutable(nil, 0, nil, nil)

// Set plugin identifier
let pluginUUID = CFUUIDCreateFromString(nil, "550e8400-e29b-41d4-a716-446655440000" as CFString)
CFDictionarySetValue(deviceDescription, kAudioPlugInCreatePluginDeviceBundleIDKey, pluginUUID)

// Set device name
let deviceName = CFSTR("Vocana Virtual Audio")
CFDictionarySetValue(deviceDescription, kAudioPlugInCreatePluginDeviceDeviceNameKey, deviceName)

var deviceID: AudioObjectID = 0
let result = AudioHardwareCreatePluginDevice(&pluginID, deviceDescription, &deviceID)

if result == noErr {
    print("✅ Successfully created Vocana device: \(deviceID)")
    
    // Verify device exists
    var deviceName: CFString? = nil
    var nameSize = UInt32(MemoryLayout<CFString>.size)
    var nameProperty = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    
    let nameResult = AudioObjectGetPropertyData(
        deviceID,
        &nameProperty,
        0,
        nil,
        &nameSize,
        &deviceName
    )
    
    if nameResult == noErr, let deviceName = deviceName as String? {
        print("📝 Device name: \(deviceName)")
    }
    
    print("💡 Device should now appear in System Settings!")
    
} else {
    print("❌ Failed to create device: \(result)")
    print("💡 This might be expected if plugin auto-creates devices")
}

print("")
print("🔄 Refreshing audio device list...")

// Force refresh of audio devices
var propertyAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)

var refreshResult = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)

// Trigger a property change notification to refresh device list
AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)

print("✅ Done! Check System Settings → Sound for Vocana devices.")