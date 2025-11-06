import SwiftUI
import Combine
import AVFoundation
import AppKit

@MainActor
struct ContentView: View {
    @State private var isEnabled = false
    @State private var sensitivity: Double = 0.5
    @State private var inputLevel: Float = 0.0
    @State private var outputLevel: Float = 0.0
    @State private var audioEngine: AVAudioEngine?
    @State private var inputNode: AVAudioInputNode?
    @State private var timer: Timer?
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            headerView
            
            Divider()
            
            // Power Toggle
            powerToggleView
            
            // Audio Levels
            audioLevelsView
            
            // Sensitivity Control
            sensitivityControlView
            
            Divider()
            
            // Settings Button
            settingsButtonView
            
            Spacer()
        }
        .padding()
        .frame(width: 300, height: 400)
        .onAppear {
            setupAudioEngine()
            startAudioLevelSimulation()
        }
        .onDisappear {
            stopAudioLevelSimulation()
            cleanupAudioEngine()
        }
    }
    
    private var headerView: some View {
        HStack {
            Image(systemName: "waveform.and.mic")
                .font(.title2)
                .foregroundColor(.accentColor)
            Text("Vocana")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
        }
    }
    
    private var powerToggleView: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Noise Cancellation")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: $isEnabled)
                    .toggleStyle(SwitchToggleStyle())
            }
            
            HStack {
                if isEnabled {
                    Text("Active")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Text("Inactive")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
    }
    
    private var audioLevelsView: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Input")
                    .font(.subheadline)
                    .frame(width: 60, alignment: .leading)
                ProgressBar(value: inputLevel, color: .blue)
            }
            
            HStack {
                Text("Output")
                    .font(.subheadline)
                    .frame(width: 60, alignment: .leading)
                ProgressBar(value: outputLevel, color: .green)
            }
        }
    }
    
    private var sensitivityControlView: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Sensitivity")
                    .font(.subheadline)
                Spacer()
                Text("\(Int(sensitivity * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Slider(value: $sensitivity, in: 0...1)
                .accentColor(.accentColor)
        }
    }
    
    private var settingsButtonView: some View {
        Button(action: {
            openSettings()
        }) {
            HStack {
                Image(systemName: "gear")
                Text("Settings")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.vertical, 4)
    }
    
    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else { return }
        inputNode = audioEngine.inputNode
        
        // Check microphone permission
        checkMicrophonePermission()
        
        do {
            try audioEngine.start()
        } catch {
            print("Error starting audio engine: \(error.localizedDescription)")
        }
    }
    
    private func cleanupAudioEngine() {
        audioEngine?.stop()
        audioEngine = nil
        inputNode = nil
    }
    
    private func checkMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        
        switch status {
        case .denied, .restricted:
            let alert = NSAlert()
            alert.messageText = "Microphone Access Required"
            alert.informativeText = "Vocana needs microphone access. Please enable it in System Settings > Privacy & Security > Microphone."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .authorized:
            break
        @unknown default:
            break
        }
    }
    
    private func startAudioLevelSimulation() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                if self.isEnabled {
                    // Simulate audio levels with random values
                    self.inputLevel = Float.random(in: 0.2...0.8)
                    self.outputLevel = Float.random(in: 0.1...0.4) * Float(self.sensitivity)
                } else {
                    // Gradually decrease to zero when disabled
                    self.inputLevel *= 0.9
                    self.outputLevel *= 0.9
                    if self.inputLevel < 0.01 { self.inputLevel = 0 }
                    if self.outputLevel < 0.01 { self.outputLevel = 0 }
                }
            }
        }
    }
    
    private func stopAudioLevelSimulation() {
        timer?.invalidate()
        timer = nil
    }
    
    private func openSettings() {
        let alert = NSAlert()
        alert.messageText = "Settings"
        alert.informativeText = "Settings functionality will be implemented in a future version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

@MainActor
struct ProgressBar: View {
    let value: Float
    let color: Color
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 4)
                    .cornerRadius(2)
                
                Rectangle()
                    .fill(color)
                    .frame(width: geometry.size.width * CGFloat(value), height: 4)
                    .cornerRadius(2)
            }
        }
        .frame(height: 4)
    }
}

#Preview {
    ContentView()
}