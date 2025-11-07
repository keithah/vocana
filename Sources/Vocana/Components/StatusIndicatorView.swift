import SwiftUI

/// Compact status indicator for menu bar UI showing audio and ML processing status
/// Displays reactive indicators for audio source, ML processing state, and performance warnings
struct StatusIndicatorView: View {
    @ObservedObject var audioEngine: AudioEngine
    @ObservedObject var settings: AppSettings
    
    var body: some View {
        HStack(spacing: 8) {
            // Audio mode indicator
            Image(systemName: audioEngine.isUsingRealAudio ? "mic.fill" : "waveform")
                .font(.caption2)
                .foregroundColor(.secondary)
                .accessibilityLabel(audioEngine.isUsingRealAudio ? "Real audio input" : "Simulated audio")
            
            // ML processing indicator
            if settings.isEnabled {
                Circle()
                    .fill(audioEngine.isMLProcessingActive ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(audioEngine.isMLProcessingActive ? "ML processing active" : "ML processing unavailable")
            }
            
            // Performance indicator
            if audioEngine.hasPerformanceIssues {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .accessibilityLabel("Performance issues detected")
            }
        }
        .font(.caption2)
        .foregroundColor(.secondary)
    }
}

#Preview {
    HStack {
        StatusIndicatorView(
            audioEngine: AudioEngine(),
            settings: AppSettings()
        )
    }
    .padding()
}
