import SwiftUI

/// Power toggle control for enabling/disabling noise cancellation
/// 
/// This component provides the primary user interface for controlling the
/// noise cancellation feature. It displays a toggle switch with accompanying
/// status text and comprehensive accessibility support.
/// 
/// Features:
/// - Large, accessible toggle switch following macOS design patterns
/// - Dynamic status text reflecting current state
/// - Keyboard shortcut support (⌥⌘N) for power users
/// - Comprehensive accessibility with VoiceOver support
/// - Visual feedback for state changes
/// 
/// Usage:
/// ```swift
/// PowerToggleView(isEnabled: $settings.isEnabled)
/// ```
/// 
/// Accessibility:
/// - VoiceOver labels and hints for toggle state
/// - Keyboard navigation support
/// - High contrast mode compatibility
/// - Reduced motion support respects user preferences
/// 
/// Keyboard Shortcuts:
/// - ⌥⌘N: Toggle noise cancellation on/off
/// - Note: Shortcut is handled at parent level for global access
/// 
/// Design:
/// - Follows macOS Human Interface Guidelines
/// - Consistent with system toggle controls
/// - Proper spacing and typography hierarchy
struct PowerToggleView: View {
    @Binding var isEnabled: Bool
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Noise Cancellation")
                    .font(AppConstants.Fonts.headline)
                    .accessibilityLabel("Noise Cancellation Toggle")
                
                Spacer()
                
                Toggle("", isOn: $isEnabled)
                    .toggleStyle(SwitchToggleStyle())
                    .accessibilityLabel(isEnabled ? "Noise Cancellation Enabled" : "Noise Cancellation Disabled")
                    .accessibilityHint("Toggle to enable or disable noise cancellation. Keyboard shortcut: ⌥⌘N")
            }
            
            HStack {
                Text(isEnabled ? "Active" : "Inactive")
                    .font(AppConstants.Fonts.caption)
                    .foregroundColor(isEnabled ? .green : .secondary)
                    .accessibilityHidden(true)
                
                Spacer()
            }
        }
        .accessibilityElement(children: .contain)
    }
}
