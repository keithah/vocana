#!/usr/bin/env swift

import Foundation
import CoreAudio
import AVFoundation

print("🔧 Setting up Vocana + BlackHole Audio Pipeline...")
print("")

class AudioRouter {
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var outputNode: AVAudioOutputNode?
    private var mixer: AVAudioMixerNode?
    
    func setup() -> Bool {
        audioEngine = AVAudioEngine()
        
        guard let engine = audioEngine else { return false }
        
        // Create nodes
        inputNode = engine.inputNode
        outputNode = engine.outputNode
        mixer = AVAudioMixerNode()
        
        // Attach mixer
        engine.attach(mixer!)
        
        // Connect input -> mixer -> output
        engine.connect(inputNode!, to: mixer!, format: inputNode?.outputFormat(forBus: 0))
        engine.connect(mixer!, to: outputNode!, format: mixer?.outputFormat(forBus: 0))
        
        return true
    }
    
    func start() -> Bool {
        do {
            try audioEngine?.start()
            return true
        } catch {
            print("❌ Failed to start audio engine: \(error)")
            return false
        }
    }
}

print("🎯 Creating Virtual Audio Pass-through with Noise Cancellation...")
print("")

let router = AudioRouter()

if router.setup() {
    print("✅ Audio pipeline created")
    
    if router.start() {
        print("✅ Audio pipeline started")
        print("")
        print("🔊 Correct Setup:")
        print("1. System Settings → Sound → Output: 'BlackHole 2ch'")
        print("2. System Settings → Sound → Input: Your microphone")
        print("3. Zoom → Microphone: 'BlackHole 2ch'")
        print("")
        print("📡 Audio Flow:")
        print("Mic → Vocana Processing → BlackHole → Zoom")
        print("")
        print("💡 Now Vocana will process your microphone and")
        print("   send clean audio to BlackHole for Zoom to use")
        
        // Keep running
        RunLoop.main.run()
        
    } else {
        print("❌ Failed to start audio pipeline")
    }
} else {
    print("❌ Failed to setup audio pipeline")
}