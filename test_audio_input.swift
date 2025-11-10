#!/usr/bin/env swift

import Foundation
import AVFoundation
import AppKit

// Test audio input levels
print("🧪 Testing audio input levels...")

let audioEngine = AVAudioEngine()
let inputNode = audioEngine.inputNode
let inputFormat = inputNode.outputFormat(forBus: 0)

print("📊 Setting up audio tap...")
var bufferCount = 0

inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
    bufferCount += 1
    
    guard let channelData = buffer.floatChannelData else { return }
    let channelDataValue = channelData.pointee
    let frames = buffer.frameLength
    
    // Calculate RMS level
    var sum: Float = 0
    for i in 0..<Int(frames) {
        sum += channelDataValue[i] * channelDataValue[i]
    }
    let rms = sqrt(sum / Float(frames))
    
    if bufferCount % 50 == 0 { // Print every 50th buffer to avoid spam
        print("🎤 Buffer \(bufferCount): RMS level = \(String(format: "%.4f", rms))")
        
        if rms > 0.01 {
            print("🟢 AUDIO DETECTED - Menu bar should turn GREEN!")
        } else {
            print("⚪ Silence - Menu bar should be white")
        }
    }
}

do {
    print("🎵 Starting audio engine...")
    try audioEngine.start()
    print("✅ Audio engine running")
    
    print("🎤 Make some noise near your microphone...")
    print("⏹️ Press Ctrl+C to stop")
    
    RunLoop.main.run()
    
} catch {
    print("❌ Failed to start audio engine: \(error)")
}