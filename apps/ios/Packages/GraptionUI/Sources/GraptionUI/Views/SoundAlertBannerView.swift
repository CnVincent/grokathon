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
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.graptionAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(alert.message)
                    .font(.footnote)
                    .foregroundStyle(Color.graptionSecondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
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
    }
}

#Preview {
    SoundAlertBannerView(alert: SoundAlert(message: "Loud noise detected. Haptics enabled."))
        .background(Color.graptionBackground)
}
