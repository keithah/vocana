import SwiftUI

/// Compact status indicator for menu bar UI showing comprehensive audio and ML processing status
/// 
/// This component provides at-a-glance status information about the audio processing pipeline
/// through a series of reactive indicators. It's designed for minimal visual footprint while
/// providing maximum information density.
/// 
/// Status Indicators:
/// - Audio Source: Microphone (real audio) vs Waveform (simulated audio)
/// - ML Processing: Green circle (active) vs Orange circle (unavailable)
/// - Performance: Warning triangle for performance issues
/// 
/// Features:
/// - Reactive updates based on AudioEngine and AppSettings state
/// - Comprehensive accessibility support with contextual labels
/// - Minimal visual footprint suitable for menu bar interface
/// - Efficient state management with @ObservedObject pattern
/// 
/// Usage:
/// ```swift
/// StatusIndicatorView(audioEngine: audioEngine, settings: settings)
/// ```
/// 
/// Accessibility:
/// - VoiceOver support with contextual descriptions
/// - Proper semantic grouping of related indicators
/// - Dynamic labels that reflect current state
/// 
/// Performance:
/// - Minimal view updates through efficient state observation
/// - No animation overhead for static indicators
/// - Optimized for frequent state changes
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio Processing Status")
        .accessibilityHint("Shows current audio input source, ML processing state, and any performance warnings. Swipe through to hear individual status details.")
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
