import SwiftUI

struct ContentView: View {
    @StateObject private var settings = AppSettings()
    @StateObject private var audioEngine = AudioEngine()
    
    var body: some View {
        VStack(spacing: 20) {
            HeaderView()
            
            Divider()
            
            PowerToggleView(isEnabled: $settings.isEnabled)
            
            AudioLevelsView(levels: audioEngine.currentLevels)
            
            SensitivityControlView(sensitivity: $settings.sensitivity)
            
            Divider()
            
            SettingsButtonView {
                // TODO: Open settings window
            }
            
            Spacer()
            
            // Audio mode indicator
            HStack {
                Image(systemName: audioEngine.isUsingRealAudio ? "mic.fill" : "waveform")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(audioEngine.isUsingRealAudio ? "Real Audio" : "Simulated")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 4)
        }
        .padding()
        .frame(width: AppConstants.popoverWidth, height: AppConstants.popoverHeight)
        .onAppear {
            audioEngine.startSimulation(isEnabled: settings.isEnabled, sensitivity: settings.sensitivity)
        }
        .onDisappear {
            audioEngine.stopSimulation()
        }
        .onChange(of: settings.isEnabled) { newValue in
            audioEngine.startSimulation(isEnabled: newValue, sensitivity: settings.sensitivity)
        }
        .onChange(of: settings.sensitivity) { newValue in
            audioEngine.startSimulation(isEnabled: settings.isEnabled, sensitivity: newValue)
        }
    }
}

#Preview {
    ContentView()
}