import SwiftUI

struct ProgressBar: View {
    let value: Float
    let color: Color
    let accessibilityLabel: String
    let accessibilityValue: String
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.gray.opacity(AppConstants.Colors.backgroundOpacity))
                    .frame(height: AppConstants.progressBarHeight)
                    .cornerRadius(AppConstants.cornerRadius)
                
                Rectangle()
                    .fill(color)
                    .frame(width: geometry.size.width * CGFloat(value), height: AppConstants.progressBarHeight)
                    .cornerRadius(AppConstants.cornerRadius)
            }
        }
        .frame(height: AppConstants.progressBarHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }
}