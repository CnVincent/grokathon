import SwiftUI

/// Opt-in screen before the phone streams microphone audio to the Graption STT proxy.
public struct OnlineCaptionConsentView: View {
    public var onAccept: () -> Void
    public var onDecline: () -> Void

    public init(onAccept: @escaping () -> Void, onDecline: @escaping () -> Void) {
        self.onAccept = onAccept
        self.onDecline = onDecline
    }

    public var body: some View {
        VStack(spacing: 0) {
            Text("Online captions")
                .font(.headline.bold())
                .foregroundStyle(Color.graptionAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.graptionAccent).frame(height: 1)
                }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Turning on online captions sends continuous microphone audio to the Graption server, which forwards it to xAI for live multilingual captions. Graption does not store that audio. The xAI key stays on the server.")
                        .font(.body)
                        .foregroundStyle(Color.graptionSecondaryText)

                    Text("Captions, speaker highlighting, and sound alerts keep working offline with on-device Whisper if you leave this off.")
                        .font(.body)
                        .foregroundStyle(Color.graptionSecondaryText)

                    Button(action: onAccept) {
                        Text("Use online captions")
                            .font(.body.bold())
                            .foregroundStyle(Color.graptionBackground)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.graptionAccent, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .accessibilityLabel("Use online captions")

                    Button(action: onDecline) {
                        Text("Keep offline only")
                            .font(.body.bold())
                            .foregroundStyle(Color.graptionAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.graptionAccent, lineWidth: 1)
                            )
                    }
                    .accessibilityLabel("Keep offline only")
                }
                .padding(16)
            }
        }
        .background(Color.graptionBackground.ignoresSafeArea())
    }
}

#Preview {
    OnlineCaptionConsentView(onAccept: {}, onDecline: {})
}
