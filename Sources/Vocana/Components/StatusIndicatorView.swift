import SwiftUI

/// Compact status indicator for menu bar UI showing audio and ML processing status
struct StatusIndicatorView: View {
    let audioEngine: AudioEngine
    let settings: AppSettings
    
    var body: some View {
        HStack(spacing: 8) {
            // Audio mode indicator
            Image(systemName: audioEngine.isUsingRealAudio ? "mic.fill" : "waveform")
                .font(.caption2)
                .foregroundColor(.secondary)
            
            // ML processing indicator
            if settings.isEnabled {
                Circle()
                    .fill(audioEngine.isMLProcessingActive ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
            }
            
            // Performance indicator
            if audioEngine.hasPerformanceIssues {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundColor(.orange)
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
