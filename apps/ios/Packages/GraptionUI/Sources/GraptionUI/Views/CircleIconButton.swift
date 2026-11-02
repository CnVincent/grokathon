import SwiftUI

struct CircleIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.graptionAccent)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.08), in: Circle())
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

#Preview {
    CircleIconButton(systemName: "chevron.left", accessibilityLabel: "Back") {}
        .padding()
        .background(Color.graptionBackground)
}
