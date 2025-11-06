import SwiftUI

struct SettingsButtonView: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "gear")
                    .accessibilityHidden(true)
                
                Text("Settings")
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(AppConstants.Fonts.caption)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.vertical, 4)
        .accessibilityLabel("Settings")
        .accessibilityHint("Open application settings")
    }
}