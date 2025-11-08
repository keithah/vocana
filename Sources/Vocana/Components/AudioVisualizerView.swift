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
        // Fix PERF-001: Implement more aggressive UI throttling with debouncing
        .onChange(of: inputLevel) { newValue in
            // More aggressive throttling - only update if change is significant
            guard abs(newValue - displayedInputLevel) > 0.02 else { return }
            
            // Debounce rapid updates to prevent excessive redraws
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { // ~60fps limit
                updateInputLevel(newValue)
            }
        }
        .onChange(of: outputLevel) { newValue in
            // More aggressive throttling - only update if change is significant
            guard abs(newValue - displayedOutputLevel) > 0.02 else { return }
            
            // Debounce rapid updates to prevent excessive redraws
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { // ~60fps limit
                updateOutputLevel(newValue)
            }
        }
    }
    
    /// Update only the input level with validation
    private func updateInputLevel(_ newValue: Float) {
        updateLevel(newValue, displayedLevel: $displayedInputLevel)
    }
    
    /// Update only the output level with validation
    private func updateOutputLevel(_ newValue: Float) {
        updateLevel(newValue, displayedLevel: $displayedOutputLevel)
    }
    
    /// Generic level update with validation and smoothing
    private func updateLevel(_ newValue: Float, displayedLevel: Binding<Float>) {
        let validatedValue = validateLevel(newValue)
        withAnimation(.easeOut(duration: 0.05)) {
            let smoothingFactor: Float = AppConstants.audioLevelSmoothingFactor
            displayedLevel.wrappedValue = displayedLevel.wrappedValue * (1 - smoothingFactor) + validatedValue * smoothingFactor
        }
    }
    
    /// Validate and clamp audio level values with comprehensive security checks
    /// - Parameter value: The level value to validate
    /// - Returns: A value between 0.0 and 1.0, or 0.0 if invalid
    private func validateLevel(_ value: Float) -> Float {
        // Security: Check for NaN, Infinity, and other invalid floating point states
        guard value.isFinite && !value.isNaN && !value.isInfinite else { 
            return 0.0 
        }
        
        // Security: Reject extreme values that could indicate malicious input
        // Audio levels should never exceed reasonable bounds even with amplification
        guard value >= -10.0 && value <= 10.0 else { 
            return 0.0 
        }
        
        // Security: Check for subnormal numbers that could cause performance issues
        guard value.isNormal || value == 0.0 else { 
            return 0.0 
        }
        
        // Clamp to valid UI range (0.0 to 1.0)
        return max(0.0, min(1.0, value))
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
    
    /// Validate and clamp level to ensure proper bounds with comprehensive security checks
    private var validatedLevel: Float {
        // Security: Check for NaN, Infinity, and other invalid floating point states
        guard level.isFinite && !level.isNaN && !level.isInfinite else { 
            return 0.0 
        }
        
        // Security: Reject extreme values that could indicate malicious input
        guard level >= -10.0 && level <= 10.0 else { 
            return 0.0 
        }
        
        // Security: Check for subnormal numbers that could cause performance issues
        guard level.isNormal || level == 0.0 else { 
            return 0.0 
        }
        
        // Clamp to valid UI range (0.0 to 1.0)
        return max(0.0, min(1.0, level))
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
