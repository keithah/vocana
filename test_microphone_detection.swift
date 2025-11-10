#!/usr/bin/env swift

import Foundation
import AVFoundation

print("🎤 Testing microphone detection...")
print("📢 Speak into your microphone now!")
print("⏹️ Testing for 5 seconds...")

let audioEngine = AVAudioEngine()
let inputNode = audioEngine.inputNode
let inputFormat = inputNode.outputFormat(forBus: 0)

var audioDetected = false

inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
    guard let channelData = buffer.floatChannelData else { return }
    let channelDataValue = channelData.pointee
    let frames = buffer.frameLength
    
    // Calculate RMS level
    var sum: Float = 0
    for i in 0..<Int(frames) {
        sum += channelDataValue[i] * channelDataValue[i]
    }
    let rms = sqrt(sum / Float(frames))
    
    if rms > 0.01 && !audioDetected {
        audioDetected = true
        print("🎉 AUDIO DETECTED! Level: \(String(format: "%.3f", rms))")
        print("✅ Your microphone is working!")
    }
}

do {
    try audioEngine.start()
    
    // Run for 5 seconds
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
        semaphore.signal()
    }
    semaphore.wait()
    
    audioEngine.stop()
    
    if !audioDetected {
        print("❌ No audio detected in 5 seconds")
        print("💡 Check:")
        print("   - Microphone permissions in System Settings")
        print("   - Microphone not muted")
        print("   - App has microphone access")
    }
    
} catch {
    print("❌ Error: \(error)")
}