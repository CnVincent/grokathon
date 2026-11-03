import SwiftUI

struct SoundAlertBannerView: View {
    let alert: SoundAlert

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.graptionAccent)
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(0.08), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Sound alert")
                    .font(.caption.bold())
                    .foregroundStyle(Color.graptionSecondaryText)
                    .lineLimit(1)
                Text(alert.message)
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.graptionAccent)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 8)

            Text(alert.isOn ? "ON" : "OFF")
                .font(.caption.bold())
                .foregroundStyle(Color.graptionAccent)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.graptionAccent).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(alert.message)
    }
}

#Preview {
    SoundAlertBannerView(alert: SoundAlert(message: "Siren"))
        .background(Color.graptionBackground)
}

#Preview("Siren context") {
    SoundAlertBannerView(
        alert: SoundAlert(message: "🚨 Siren: tornado warning for Fulton County, shelter now.")
    )
    .background(Color.graptionBackground)
}
