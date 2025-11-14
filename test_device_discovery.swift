#!/usr/bin/env swift

import Foundation
import AudioToolbox
import CoreAudio

// Test device discovery for Vocana HAL plugin
func testVocanaDeviceDiscovery() {
    print("Testing Vocana HAL Plugin Device Discovery...")
    
    var deviceID: AudioObjectID = 0
    var propertySize = UInt32(MemoryLayout<AudioObjectID>.size)
    var result: OSStatus = noErr
    
    // Get default input device
    result = AudioHardwareGetProperty(kAudioHardwarePropertyDefaultInputDevice,
                                     &propertySize,
                                     &deviceID)
    
    if result == noErr && deviceID != kAudioDeviceUnknown {
        print("Default input device ID: \(deviceID)")
        
        // Get device name
        var deviceName: CFString?
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        result = AudioObjectGetPropertyData(deviceID,
                                          kAudioObjectPropertyName,
                                          0,
                                          nil,
                                          &nameSize,
                                          &deviceName)
        
        if result == noErr, let name = deviceName as String? {
            print("Default input device name: \(name)")
            if name.contains("Vocana") {
                print("✅ Found Vocana input device!")
            }
        }
    }
    
    // Get default output device
    result = AudioHardwareGetProperty(kAudioHardwarePropertyDefaultOutputDevice,
                                     &propertySize,
                                     &deviceID)
    
    if result == noErr && deviceID != kAudioDeviceUnknown {
        print("Default output device ID: \(deviceID)")
        
        // Get device name
        var deviceName: CFString?
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        result = AudioObjectGetPropertyData(deviceID,
                                          kAudioObjectPropertyName,
                                          0,
                                          nil,
                                          &nameSize,
                                          &deviceName)
        
        if result == noErr, let name = deviceName as String? {
            print("Default output device name: \(name)")
            if name.contains("Vocana") {
                print("✅ Found Vocana output device!")
            }
        }
    }
    
    // List all devices
    print("\nAll audio devices:")
    var devices: [AudioObjectID] = []
    propertySize = 0
    
    // Get size
    result = AudioHardwareGetProperty(kAudioHardwarePropertyDevices,
                                     &propertySize,
                                     nil)
    
    if result == noErr {
        let deviceCount = Int(propertySize) / MemoryLayout<AudioObjectID>.size
        devices = Array(repeating: 0, count: deviceCount)
        
        result = AudioHardwareGetProperty(kAudioHardwarePropertyDevices,
                                         &propertySize,
                                         &devices)
        
        if result == noErr {
            for (index, device) in devices.enumerated() {
                var deviceName: CFString?
                var nameSize = UInt32(MemoryLayout<CFString?>.size)
                
                let nameResult = AudioObjectGetPropertyData(device,
                                                           kAudioObjectPropertyName,
                                                           0,
                                                           nil,
                                                           &nameSize,
                                                           &deviceName)
                
                if nameResult == noErr, let name = deviceName as String? {
                    print("  Device \(index): \(name) (ID: \(device))")
                    if name.contains("Vocana") {
                        print("    🎯 VOCANA DEVICE FOUND!")
                    }
                }
            }
        }
    }
}

testVocanaDeviceDiscovery()