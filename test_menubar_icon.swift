#!/usr/bin/env swift

import Foundation
import AppKit

// Test the menu bar icon logic
print("🧪 Testing menu bar icon logic...")

// Test conditions
let isUsingRealAudio = true
let inputLevel: Float = 0.05  // Above 0.01 threshold

let isRecording = isUsingRealAudio && inputLevel > 0.01
let iconName = isRecording ? "waveform.and.mic.fill" : "waveform.and.mic"

print("📊 Menu Bar Icon Test:")
print("   Using real audio: \(isUsingRealAudio)")
print("   Input level: \(inputLevel)")
print("   Recording threshold: 0.01")
print("   Should show recording: \(isRecording)")
print("   Icon name: \(iconName)")

if isRecording {
    print("✅ Menu bar should show GREEN FILLED icon when recording")
} else {
    print("⚪ Menu bar should show WHITE OUTLINE icon when not recording")
}

print("\n🎯 Expected behavior:")
print("- When audio is active AND input level > 0.01: Green filled icon")
print("- Otherwise: White outline icon")
print("- Icon should update in real-time as audio levels change")