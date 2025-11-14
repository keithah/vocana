import SwiftUI

struct ContentView: View {
    @StateObject private var settings = AppSettings()
    @StateObject private var audioEngine = AudioEngine()
    @State private var showingAudioRouting = false

    private func openSettingsWindow() {
        #if os(macOS)
        let settingsWindow = SettingsWindow(audioEngine: audioEngine, settings: settings)
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        #endif
    }
    
    var body: some View {
        VStack(spacing: 20) {
            HeaderView()
            
            Divider()
            
            PowerToggleView(isEnabled: $settings.isEnabled)
            
            AudioLevelsView(levels: audioEngine.currentLevels)
            
            SensitivityControlView(sensitivity: $settings.sensitivity)
            
            Divider()
            
            // Audio Routing Button
            VStack(spacing: 8) {
                Button(action: {
                    showingAudioRouting = true
                }) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Audio Routing")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
                
                Text("Configure virtual audio routing")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            SettingsButtonView {
                openSettingsWindow()
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
                 
                 // Buffer health indicator (shows when audio engine is under stress)
                 // Fix: Add buffer overflow telemetry for UI visibility
                 if audioEngine.hasPerformanceIssues {
                     HStack(spacing: 4) {
                         Image(systemName: "exclamationmark.triangle.fill")
                             .font(.caption2)
                             .foregroundColor(.orange)
                         
                         Text(audioEngine.bufferHealthMessage)
                             .font(.caption2)
                             .foregroundColor(.secondary)
                     }
                 }
             }
             .padding(.top, 4)
        }
        .padding()
        .frame(width: AppConstants.popoverWidth, height: AppConstants.popoverHeight)
        .sheet(isPresented: $showingAudioRouting) {
            AudioRoutingView()
                .frame(width: 500, height: 600)
        }
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