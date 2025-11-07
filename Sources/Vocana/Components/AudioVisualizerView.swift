import SwiftUI

/// Real-time audio visualization with smooth animations
struct AudioVisualizerView: View {
    let inputLevel: Float
    let outputLevel: Float
    let isActive: Bool
    
    @State private var displayedInputLevel: Float = 0.0
    @State private var displayedOutputLevel: Float = 0.0
    @State private var timer: Timer?
    
    var body: some View {
        VStack(spacing: 12) {
            // Input level visualization
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Input", systemImage: "mic.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.0f%%", Float(displayedInputLevel) * 100))
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                                        .blue,
                                        displayedInputLevel > 0.7 ? .orange : .blue
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
                    Spacer()
                    Text(String(format: "%.0f%%", Float(displayedOutputLevel) * 100))
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                                        .green,
                                        displayedOutputLevel > 0.7 ? .orange : .green
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
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                updateLevels()
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
    
    private func updateLevels() {
        withAnimation(.easeOut(duration: 0.05)) {
            // Smooth interpolation towards target levels
            let smoothingFactor: Float = 0.3
            displayedInputLevel = displayedInputLevel * (1 - smoothingFactor) + inputLevel * smoothingFactor
            displayedOutputLevel = displayedOutputLevel * (1 - smoothingFactor) + outputLevel * smoothingFactor
        }
    }
}

#Preview {
    AudioVisualizerView(inputLevel: 0.6, outputLevel: 0.3, isActive: true)
        .padding()
}
