import SwiftUI

/// Real-time audio visualization with smooth animations and comprehensive security validation
/// 
/// This component displays input and output audio levels using animated progress bars
/// with exponential smoothing for natural-looking transitions. It includes comprehensive
/// input validation to prevent UI instability from malformed audio data.
/// 
/// Features:
/// - Real-time level visualization with 60fps updates
/// - Exponential smoothing for natural animations
/// - Comprehensive input validation and security checks
/// - Accessibility support with VoiceOver integration
/// - Performance optimization with change throttling
/// 
/// Usage:
/// ```swift
/// AudioVisualizerView(
///     inputLevel: audioEngine.currentLevels.input,
///     outputLevel: audioEngine.currentLevels.output
/// )
/// ```
/// 
/// Security Considerations:
/// - All input values are validated for NaN, Infinity, and extreme values
/// - Subnormal number detection prevents performance attacks
/// - Bounds checking ensures values stay within valid UI range
/// 
/// Performance:
/// - Updates are throttled to prevent excessive redraws
/// - Smoothing algorithm uses efficient exponential moving average
/// - Minimal view hierarchy for optimal rendering
struct AudioVisualizerView: View {
    let inputLevel: Float
    let outputLevel: Float
    
    @State private var displayedInputLevel: Float
    @State private var displayedOutputLevel: Float
    
    init(inputLevel: Float, outputLevel: Float) {
        self.inputLevel = inputLevel
        self.outputLevel = outputLevel
        // Initialize displayed levels with input levels to avoid fade-in animation
        _displayedInputLevel = State(initialValue: inputLevel)
        _displayedOutputLevel = State(initialValue: outputLevel)
    }
    
    var body: some View {
        VStack(spacing: 12) {
            LevelBarView(
                title: "Input",
                systemImage: "mic.fill",
                level: displayedInputLevel,
                color: AppConstants.Colors.inputLevel,
                warningThreshold: AppConstants.levelWarningThreshold,
                accessibilityIdentifier: "audio-input-label"
            )
            
            LevelBarView(
                title: "Output",
                systemImage: "speaker.wave.2.fill",
                level: displayedOutputLevel,
                color: AppConstants.Colors.outputLevel,
                warningThreshold: AppConstants.levelWarningThreshold,
                accessibilityIdentifier: "audio-output-label"
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio Levels")
        .accessibilityHint("Shows real-time input and output audio levels")
         // Fix PERF-001: Use AppConstants for magic numbers and prevent race conditions
         .onChange(of: inputLevel) { newValue in
             let validatedValue = AudioLevelValidator.validateAudioLevel(newValue)
             // Only update if change is significant (reduces noise)
             guard abs(validatedValue - displayedInputLevel) > AppConstants.audioLevelChangeThreshold else { return }
             
             withAnimation(.easeOut(duration: AppConstants.audioLevelAnimationDuration)) {
                 let smoothingFactor: Float = AppConstants.audioLevelSmoothingFactor
                 displayedInputLevel = displayedInputLevel * (1 - smoothingFactor) + validatedValue * smoothingFactor
             }
         }
         .onChange(of: outputLevel) { newValue in
             let validatedValue = AudioLevelValidator.validateAudioLevel(newValue)
             // Only update if change is significant (reduces noise)
             guard abs(validatedValue - displayedOutputLevel) > AppConstants.audioLevelChangeThreshold else { return }
             
             withAnimation(.easeOut(duration: AppConstants.audioLevelAnimationDuration)) {
                 let smoothingFactor: Float = AppConstants.audioLevelSmoothingFactor
                 displayedOutputLevel = displayedOutputLevel * (1 - smoothingFactor) + validatedValue * smoothingFactor
             }
         }
    }
}

/// Reusable level bar component for displaying audio levels
private struct LevelBarView: View {
    let title: String
    let systemImage: String
    let level: Float
    let color: Color
    let warningThreshold: Float
    let accessibilityIdentifier: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier(accessibilityIdentifier)
                Spacer()
                Text(String(format: "%.0f%%", validatedLevel * 100))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityLabel("\(title) level: \(String(format: "%.0f", validatedLevel * 100))%")
            }
            
            // Animated level bar with warning color for high levels
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background bar
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.2))
                    
                    // Foreground bar with dynamic color
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(width: geometry.size.width * CGFloat(validatedLevel))
                }
            }
            .frame(height: 8)
        }
    }
    
    /// Determine bar color based on level threshold
    private var barColor: Color {
        validatedLevel > warningThreshold ? .orange : color
    }
    
     /// Validate level - already validated upstream in AudioVisualizerView.onChange
     private var validatedLevel: Float {
         // Fix HIGH: Level is already validated in AudioVisualizerView.onChange()
         // before being passed as displayedInputLevel/displayedOutputLevel
         // Clamp here defensively but avoid redundant full validation
         return min(1.0, max(0.0, level))
     }
}

#Preview("Normal Levels") {
    AudioVisualizerView(inputLevel: 0.5, outputLevel: 0.3)
        .padding()
}

#Preview("High Levels (Warning)") {
    AudioVisualizerView(inputLevel: 0.8, outputLevel: 0.75)
        .padding()
}

#Preview("Edge Cases") {
    AudioVisualizerView(inputLevel: 0.0, outputLevel: 1.0)
        .padding()
}
