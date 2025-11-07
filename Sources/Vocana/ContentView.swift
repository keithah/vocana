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
            
            // Status indicators
            VStack(spacing: 4) {
                // Audio mode indicator
                HStack {
                    Image(systemName: audioEngine.isUsingRealAudio ? "mic.fill" : "waveform")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(audioEngine.isUsingRealAudio ? "Real Audio" : "Simulated")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                // ML processing indicator
                if settings.isEnabled {
                    HStack(spacing: 4) {
                        Image(systemName: audioEngine.isMLProcessingActive ? "cpu.fill" : "cpu")
                            .font(.caption2)
                            .foregroundColor(audioEngine.isMLProcessingActive ? .green : .orange)
                        
                        Text(audioEngine.isMLProcessingActive ? "ML Active" : "ML Unavailable")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        if audioEngine.isMLProcessingActive && audioEngine.processingLatencyMs > 0 {
                            Text("(\(String(format: "%.1f", audioEngine.processingLatencyMs))ms)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
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