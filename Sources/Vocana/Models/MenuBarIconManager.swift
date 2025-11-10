import SwiftUI
import AppKit
import Combine

/// Manages menu bar icon appearance and state transitions
/// 
/// This class handles the visual representation of the app's menu bar icon,
/// including color states, accessibility, and performance optimization.
/// 
/// Features:
/// - Semantic state management with clear transitions
/// - Performance throttling to prevent excessive updates
/// - Comprehensive error handling with fallback icons
/// - Full accessibility support
/// - Palette-based icon coloring for hierarchical effects
@MainActor
class MenuBarIconManager: ObservableObject {
    
    // MARK: - State Management
    
    enum IconState {
        case active    // Enabled + processing audio (green waveform)
        case ready     // Enabled + waiting for audio (orange waveform)
        case inactive  // Disabled (gray waveform)
        
        var colors: [NSColor] {
            switch self {
            case .active:
                [.systemGreen, .controlTextColor]    // Green waveform, gray mic
            case .ready:
                [.systemOrange, .controlTextColor]   // Orange waveform, gray mic
            case .inactive:
                [.controlTextColor, .controlTextColor] // Both gray
            }
        }
        
        var iconName: String { "waveform.and.mic" }
        
        var accessibilityDescription: String {
            switch self {
            case .active:
                return "Vocana - Active noise cancellation"
            case .ready:
                return "Vocana - Ready"
            case .inactive:
                return "Vocana - Inactive"
            }
        }
        
        var accessibilityValue: String {
            switch self {
            case .active:
                return "Active"
            case .ready:
                return "Ready"
            case .inactive:
                return "Inactive"
            }
        }
    }
    
    @Published private(set) var currentState: IconState = .inactive
    
    // MARK: - Dependencies
    
    private let throttler = Throttler(interval: 0.1) // 100ms = 10 updates/sec max
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Public Interface
    
    /// Updates the icon state based on audio processing status
    /// - Parameters:
    ///   - isEnabled: Whether noise cancellation is enabled
    ///   - isUsingRealAudio: Whether real audio is being processed
    func updateState(isEnabled: Bool, isUsingRealAudio: Bool) {
        throttler.throttle { [weak self] in
            let newState = Self.determineState(isEnabled: isEnabled, isUsingRealAudio: isUsingRealAudio)
            
        #if DEBUG
        VocanaLogger.app.debug("Applied icon state \(self?.currentState ?? .inactive) to menu bar button")
        #endif
            
            self?.currentState = newState
        }
    }
    
    /// Creates an icon image for the current state with proper error handling
    /// - Returns: Configured NSImage or fallback if creation fails
    func createIconImage() -> NSImage {
        let config = NSImage.SymbolConfiguration(paletteColors: currentState.colors)
        
        // Try to create the primary icon
        if let image = NSImage(
            systemSymbolName: currentState.iconName,
            accessibilityDescription: currentState.accessibilityDescription
        )?.withSymbolConfiguration(config) {
            image.isTemplate = false
            return image
        }
        
        // Fallback to gear icon if primary fails
        #if DEBUG
        VocanaLogger.app.error("Failed to create primary icon, using fallback")
        #endif
        
        let fallbackConfig = NSImage.SymbolConfiguration(paletteColors: [.controlTextColor])
        let fallbackImage = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: "Vocana Settings"
        )?.withSymbolConfiguration(fallbackConfig) ?? NSImage()
        
        fallbackImage.isTemplate = false
        return fallbackImage
    }
    
    /// Applies the current icon state to a menu bar button
    /// - Parameter button: The status bar button to update
    func applyToButton(_ button: NSStatusBarButton) {
        let image = createIconImage()
        
        button.image = image
        button.contentTintColor = nil
        
        // Update accessibility
        button.setAccessibilityLabel(currentState.accessibilityDescription)
        button.setAccessibilityValue(currentState.accessibilityValue)
        
            #if DEBUG
            VocanaLogger.app.debug("Setting up consolidated menu bar icon updates...")
            #endif
    }
    
    // MARK: - Private Methods
    
    /// Determines the appropriate icon state based on current conditions
    /// - Parameters:
    ///   - isEnabled: Whether noise cancellation is enabled
    ///   - isUsingRealAudio: Whether real audio is being processed
    /// - Returns: The appropriate IconState
    static func determineState(isEnabled: Bool, isUsingRealAudio: Bool) -> IconState {
        switch (isEnabled, isUsingRealAudio) {
        case (true, true):
            return .active
        case (true, false):
            return .ready
        case (false, _):
            return .inactive
        }
    }
}

// MARK: - Logging Support

#if DEBUG
enum VocanaLogger {
    enum app {
        static func debug(_ message: String) {
            print("🔘 [DEBUG] \(message)")
        }
        
        static func error(_ message: String) {
            print("🚨 [ERROR] \(message)")
        }
        
        static func info(_ message: String) {
            print("ℹ️ [INFO] \(message)")
        }
    }
}
#endif