import SwiftUI

/// Real-time audio visualization with smooth animations
/// Displays input/output audio levels with animated progress bars and smooth interpolation
struct AudioVisualizerView: View {
    let inputLevel: Float
    let outputLevel: Float
    
    @State private var displayedInputLevel: Float = 0.0
    @State private var displayedOutputLevel: Float = 0.0
    
    var body: some View {
        VStack(spacing: 12) {
            // Input level visualization
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Input", systemImage: "mic.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("audio-input-label")
                    Spacer()
                    Text(String(format: "%.0f%%", displayedInputLevel * 100))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .accessibilityLabel("Input level: \(String(format: "%.0f", displayedInputLevel * 100))%")
                }
                
                // Animated level bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.gray.opacity(0.2))
                        
                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        AppConstants.Colors.inputLevel,
                                        displayedInputLevel > AppConstants.levelWarningThreshold ? .orange : AppConstants.Colors.inputLevel
                                    ]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geometry.size.width * CGFloat(displayedInputLevel))
                    }
                }
                .frame(height: 8)
            }
            
            // Output level visualization
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Output", systemImage: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("audio-output-label")
                    Spacer()
                    Text(String(format: "%.0f%%", displayedOutputLevel * 100))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .accessibilityLabel("Output level: \(String(format: "%.0f", displayedOutputLevel * 100))%")
                }
                
                // Animated level bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.gray.opacity(0.2))
                        
                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        AppConstants.Colors.outputLevel,
                                        displayedOutputLevel > AppConstants.levelWarningThreshold ? .orange : AppConstants.Colors.outputLevel
                                    ]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geometry.size.width * CGFloat(displayedOutputLevel))
                    }
                }
                .frame(height: 8)
            }
        }
        .onChange(of: inputLevel) { newValue in
            updateLevels(newInput: newValue, newOutput: outputLevel)
        }
        .onChange(of: outputLevel) { newValue in
            updateLevels(newInput: inputLevel, newOutput: newValue)
        }
    }
    
    private func updateLevels(newInput: Float, newOutput: Float) {
        withAnimation(.easeOut(duration: 0.05)) {
            // Smooth interpolation towards target levels using exponential moving average
            let smoothingFactor: Float = AppConstants.audioLevelSmoothingFactor
            displayedInputLevel = displayedInputLevel * (1 - smoothingFactor) + newInput * smoothingFactor
            displayedOutputLevel = displayedOutputLevel * (1 - smoothingFactor) + newOutput * smoothingFactor
        }
    }
}

#Preview {
    AudioVisualizerView(inputLevel: 0.6, outputLevel: 0.3)
        .padding()
}
