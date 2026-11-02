import SwiftUI

struct CaptionHeaderView: View {
    var subtitle = "Graption • Live camera"
    var onBack: () -> Void = {}
    var onSettings: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            CircleIconButton(systemName: "chevron.left", accessibilityLabel: "Back", action: onBack)

            VStack(alignment: .leading, spacing: 2) {
                Text("Live captions")
                    .font(.headline.bold())
                    .foregroundStyle(Color.graptionAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Color.graptionSecondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }

            Spacer(minLength: 8)

            CircleIconButton(systemName: "gearshape.fill", accessibilityLabel: "Settings", action: onSettings)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.graptionBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.graptionAccent).frame(height: 1)
        }
    }
}

#Preview {
    CaptionHeaderView()
}
