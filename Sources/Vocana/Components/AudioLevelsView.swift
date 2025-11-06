import SwiftUI

struct AudioLevelsView: View {
    let levels: AudioLevels
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Input")
                    .font(AppConstants.Fonts.subheadline)
                    .frame(width: 60, alignment: .leading)
                
                ProgressBar(
                    value: levels.input,
                    color: AppConstants.Colors.inputLevel,
                    accessibilityLabel: "Input Level",
                    accessibilityValue: "\(Int(levels.input * 100))%"
                )
            }
            
            HStack {
                Text("Output")
                    .font(AppConstants.Fonts.subheadline)
                    .frame(width: 60, alignment: .leading)
                
                ProgressBar(
                    value: levels.output,
                    color: AppConstants.Colors.outputLevel,
                    accessibilityLabel: "Output Level",
                    accessibilityValue: "\(Int(levels.output * 100))%"
                )
            }
        }
        .accessibilityElement(children: .contain)
    }
}