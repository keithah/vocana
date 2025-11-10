import SwiftUI
import AppKit
import Combine
import OSLog

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
    
    enum IconState: CustomStringConvertible {
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
        
        var description: String {
            switch self {
            case .active:
                return "active"
            case .ready:
                return "ready"
            case .inactive:
                return "inactive"
            }
        }
    }
    
    private static let logger = Logger(subsystem: "Vocana", category: "MenuBarIconManager")
    private static let throttleInterval: TimeInterval = 0.1 // 100ms = 10 updates/sec max
    
    @Published private(set) var currentState: IconState = .inactive {
        didSet {
            // Apply to button immediately when state changes
            if let button = targetButton {
                applyToButton(button)
            }
        }
    }
    
    private weak var targetButton: NSStatusBarButton?
    
    // MARK: - Dependencies
    
    private let throttler = Throttler(interval: MenuBarIconManager.throttleInterval)
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Public Interface
    
    /// Clean up resources and subscriptions
    func cleanup() {
        cancellables.removeAll()
        targetButton = nil
    }
    
    /// Updates the icon state based on audio processing status
    /// - Parameters:
    ///   - isEnabled: Whether noise cancellation is enabled
    ///   - isUsingRealAudio: Whether real audio is being processed
    func updateState(isEnabled: Bool, isUsingRealAudio: Bool) {
        throttler.throttle { [weak self] in
            let newState = Self.determineState(isEnabled: isEnabled, isUsingRealAudio: isUsingRealAudio)
            
            if let self = self, self.currentState != newState {
                self.currentState = newState
                Self.logger.debug("Icon state updated to \(newState)")
            }
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
        Self.logger.error("Failed to create primary icon, using fallback")
        
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
        // Store reference for automatic updates
        targetButton = button
        
        let image = createIconImage()
        button.image = image
        
        // Update accessibility
        button.setAccessibilityLabel("Vocana - \(currentState.accessibilityDescription)")
        button.setAccessibilityValue(currentState.accessibilityValue)
        
        Self.logger.debug("Applied icon state \(self.currentState) to menu bar button")
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

