import SwiftUI

struct ContentView: View {
    @StateObject private var settings = AppSettings()
    @StateObject private var audioEngine = AudioEngine()
    
    var body: some View {
        VStack(spacing: 16) {
            // Header with status indicator
            HStack {
                HeaderView()
                Spacer()
                StatusIndicatorView(audioEngine: audioEngine, settings: settings)
            }
            
            Divider()
            
            // Main controls
            PowerToggleView(isEnabled: $settings.isEnabled)
            
            // Real-time audio visualization
            AudioVisualizerView(
                inputLevel: audioEngine.currentLevels.input,
                outputLevel: audioEngine.currentLevels.output,
                isActive: settings.isEnabled
            )
            
            // Sensitivity control with visual feedback
            SensitivityControlView(sensitivity: $settings.sensitivity)
            
            Divider()
            
            // Settings button
            SettingsButtonView {
                // TODO: Open settings window
            }
            
            Spacer()
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
        .keyboardShortcut("n", modifiers: [.command, .option])  // ⌥⌘N to toggle
    }
}

#Preview {
    ContentView()
}