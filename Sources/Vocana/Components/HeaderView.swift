import SwiftUI

struct HeaderView: View {
    var body: some View {
        HStack {
            Image(systemName: "waveform.and.mic")
                .font(AppConstants.Fonts.title)
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)
            
            Text("Vocana")
                .font(AppConstants.Fonts.title)
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
            
            Spacer()
        }
    }
}