import SwiftUI

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.graptionBubble)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.graptionAccent, lineWidth: 1)
        )
    }
}

#Preview {
    SettingsCard {
        Text("Mac Server")
            .font(.title3.bold())
            .foregroundStyle(Color.graptionAccent)
    }
    .padding()
    .background(Color.graptionBackground)
}
