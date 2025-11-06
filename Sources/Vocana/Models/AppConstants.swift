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