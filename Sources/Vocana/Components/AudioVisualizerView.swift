import SwiftUI

/// Real-time audio visualization with smooth animations
/// Displays input/output audio levels with animated progress bars and smooth interpolation
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
        .onChange(of: inputLevel) { newValue in
            updateInputLevel(newValue)
        }
        .onChange(of: outputLevel) { newValue in
            updateOutputLevel(newValue)
        }
    }
    
    /// Update only the input level with validation
    private func updateInputLevel(_ newValue: Float) {
        let validatedValue = validateLevel(newValue)
        withAnimation(.easeOut(duration: 0.05)) {
            let smoothingFactor: Float = AppConstants.audioLevelSmoothingFactor
            displayedInputLevel = displayedInputLevel * (1 - smoothingFactor) + validatedValue * smoothingFactor
        }
    }
    
    /// Update only the output level with validation
    private func updateOutputLevel(_ newValue: Float) {
        let validatedValue = validateLevel(newValue)
        withAnimation(.easeOut(duration: 0.05)) {
            let smoothingFactor: Float = AppConstants.audioLevelSmoothingFactor
            displayedOutputLevel = displayedOutputLevel * (1 - smoothingFactor) + validatedValue * smoothingFactor
        }
    }
    
    /// Validate and clamp audio level values
    /// - Parameter value: The level value to validate
    /// - Returns: A value between 0.0 and 1.0, or 0.0 if invalid
    private func validateLevel(_ value: Float) -> Float {
        guard value.isFinite else { return 0.0 }
        return max(0, min(1, value))
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
                Text(String(format: "%.0f%%", level * 100))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityLabel("\(title) level: \(String(format: "%.0f", level * 100))%")
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
                        .frame(width: geometry.size.width * CGFloat(level))
                }
            }
            .frame(height: 8)
        }
    }
    
    /// Determine bar color based on level threshold
    private var barColor: Color {
        level > warningThreshold ? .orange : color
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
