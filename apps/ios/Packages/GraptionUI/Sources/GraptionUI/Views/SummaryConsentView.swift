import SwiftUI

/// Opt-in before any caption text is sent to `POST /summary`.
public struct SummaryConsentView: View {
    public var onAccept: () -> Void
    public var onDecline: () -> Void

    public init(onAccept: @escaping () -> Void, onDecline: @escaping () -> Void) {
        self.onAccept = onAccept
        self.onDecline = onDecline
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text(
                    "This sends the words from the last two minutes, not microphone audio, to the Graption server so it can summarize them. The server does not store audio. Captions keep working if you decline."
                )
                .font(.body)
                .foregroundStyle(.white)

                Button(action: onAccept) {
                    Text("Summarize the last two minutes")
                        .font(.body.bold())
                        .foregroundStyle(Color.graptionBackground)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.graptionAccent, in: RoundedRectangle(cornerRadius: 14))
                }
                .accessibilityLabel("Summarize the last two minutes")

                Button("Not now", action: onDecline)
                    .font(.body.bold())
                    .foregroundStyle(Color.graptionAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .accessibilityLabel("Not now")

                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.graptionBackground.ignoresSafeArea())
            .navigationTitle("What did I miss?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.graptionBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    SummaryConsentView(onAccept: {}, onDecline: {})
}
