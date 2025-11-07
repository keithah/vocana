import SwiftUI

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
                    .keyboardShortcut("n", modifiers: [.command, .option])  // ⌥⌘N to toggle
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