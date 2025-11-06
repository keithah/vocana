import SwiftUI
import Combine

struct ContentView: View {
    @State private var isEnabled = false
    @State private var sensitivity: Double = 0.5
    @State private var inputLevel: Float = 0.0
    @State private var outputLevel: Float = 0.0
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
            startAudioLevelSimulation()
        }
        .onDisappear {
            stopAudioLevelSimulation()
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
            // TODO: Open settings window
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
    
    private func startAudioLevelSimulation() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if isEnabled {
                // Simulate audio levels with random values
                inputLevel = Float.random(in: 0.2...0.8)
                outputLevel = Float.random(in: 0.1...0.4) * Float(sensitivity)
            } else {
                // Gradually decrease to zero when disabled
                inputLevel *= 0.9
                outputLevel *= 0.9
                if inputLevel < 0.01 { inputLevel = 0 }
                if outputLevel < 0.01 { outputLevel = 0 }
            }
        }
    }
    
    private func stopAudioLevelSimulation() {
        timer?.invalidate()
        timer = nil
    }
}

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