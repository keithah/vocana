import SwiftUI

struct SensitivityControlView: View {
    @Binding var sensitivity: Double
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Sensitivity")
                    .font(AppConstants.Fonts.subheadline)
                    .accessibilityLabel("Sensitivity Control")
                
                Spacer()
                
                Text("\(Int(sensitivity * 100))%")
                    .font(AppConstants.Fonts.caption)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            }
            
            Slider(value: $sensitivity, in: AppConstants.sensitivityRange)
                .accentColor(.accentColor)
                .accessibilityLabel("Sensitivity Slider")
                .accessibilityValue("\(Int(sensitivity * 100)) percent")
                .accessibilityHint("Adjust the sensitivity of noise cancellation")
        }
        .accessibilityElement(children: .contain)
    }
}