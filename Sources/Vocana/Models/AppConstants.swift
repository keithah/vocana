import SwiftUI

struct AppConstants {
    // UI Dimensions
    static let popoverWidth: CGFloat = 300
    static let popoverHeight: CGFloat = 400
    static let progressBarHeight: CGFloat = 4
    static let cornerRadius: CGFloat = 2
    
    // Audio Simulation
    static let audioUpdateInterval: TimeInterval = 0.1
    static let inputLevelRange: ClosedRange<Double> = 0.2...0.8
    static let outputLevelRange: ClosedRange<Double> = 0.1...0.4
    static let levelDecayRate: Float = 0.9
    static let minimumLevelThreshold: Float = 0.01
    
    // Sensitivity
    static let sensitivityRange: ClosedRange<Double> = 0...1
    
    // Audio Processing
    static let sampleRate: Int = 48000
    static let maxAudioBufferSize: Int = 48000  // 1 second at 48kHz
    static let rmsAmplificationFactor: Float = 10.0
    static let maxSpectralFrames: Int = 100_000  // ~35 minutes at 48kHz with 480 hop
    static let defaultLSNRValue: Float = -10.0
    static let maxProcessingGain: Float = 10.0
    
    // DeepFilterNet Configuration
    static let fftSize: Int = 960
    static let hopSize: Int = 480
    static let erbBands: Int = 32
    static let dfBands: Int = 96
    static let dfOrder: Int = 5  // Deep filtering FIR filter order
    
    // Audio Processing Constants
    static let minFrequency: Float = 50.0  // Minimum frequency (Hz) - human hearing starts ~20Hz but 50Hz is more practical
    static let defaultTensorValue: Float = 0.1  // Default value for tensor initialization
    
    // Accessibility
    static let accessibilityDescription = "Vocana"
    
    // Colors
    struct Colors {
        static let inputLevel = Color.blue
        static let outputLevel = Color.green
        static let backgroundOpacity = 0.3
    }
    
    // Fonts
    struct Fonts {
        static let title = Font.title2
        static let headline = Font.headline
        static let subheadline = Font.subheadline
        static let caption = Font.caption
    }
}