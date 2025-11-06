import SwiftUI

struct ProgressBar: View {
    let value: Float
    let color: Color
    let accessibilityLabel: String
    let accessibilityValue: String
    
    /// Clamped value between 0.0 and 1.0 to prevent rendering issues
    private var clampedValue: Float {
        max(0.0, min(1.0, value))
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.gray.opacity(AppConstants.Colors.backgroundOpacity))
                    .frame(height: AppConstants.progressBarHeight)
                    .cornerRadius(AppConstants.cornerRadius)
                
                Rectangle()
                    .fill(color)
                    .frame(width: geometry.size.width * CGFloat(clampedValue), height: AppConstants.progressBarHeight)
                    .cornerRadius(AppConstants.cornerRadius)
            }
        }
        .frame(height: AppConstants.progressBarHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }
}