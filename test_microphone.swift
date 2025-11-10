#!/usr/bin/env swift

import Foundation
import AVFoundation
import AppKit

// Test microphone access and audio setup
print("🧪 Testing microphone access...")

// Check current permission status
let permissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
print("📋 Current permission status: \(permissionStatus.rawValue)")

switch permissionStatus {
case .authorized:
    print("✅ Microphone access already granted")
case .denied:
    print("❌ Microphone access denied")
case .restricted:
    print("⚠️ Microphone access restricted")
case .notDetermined:
    print("❓ Permission not determined - will request")
@unknown default:
    print("❓ Unknown permission status")
}

// Request permission if needed
if permissionStatus == .notDetermined {
    print("🔐 Requesting microphone permission...")
    let semaphore = DispatchSemaphore(value: 0)
    
    AVCaptureDevice.requestAccess(for: .audio) { granted in
        if granted {
            print("✅ Permission granted!")
        } else {
            print("❌ Permission denied")
        }
        semaphore.signal()
    }
    
    semaphore.wait()
}

// Test AVAudioEngine creation
print("🎵 Testing AVAudioEngine...")
let audioEngine = AVAudioEngine()
print("✅ AVAudioEngine created: \(audioEngine)")

let inputNode = audioEngine.inputNode
print("✅ Input node available: \(inputNode)")

let inputFormat = inputNode.outputFormat(forBus: 0)
print("📊 Input format: \(inputFormat)")
print("   Sample rate: \(inputFormat.sampleRate)")
print("   Channels: \(inputFormat.channelCount)")

print("🎯 Microphone test complete!")