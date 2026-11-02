import SwiftUI
import GraptionCore

struct CaptionBubbleView: View {
    let caption: LiveCaption
    /// Locked see-through. 0 is a solid box, 1 is nearly invisible.
    private let seeThrough = 0.68

    var body: some View {
        let speakerColor = colorForSpeaker(caption.speakerName)

        return VStack(alignment: .leading, spacing: 6) {
            Text(caption.speakerName)
                .font(.subheadline.bold())
                .foregroundStyle(speakerColor)
                .shadow(color: .black.opacity(0.7), radius: 2, y: 1)

            if let tag = caption.toneTag {
                Text(tag)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.16), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.28), lineWidth: 0.5))
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            }

            Text(caption.text)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.75), radius: 2, y: 1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(1 - seeThrough * 0.85)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.black.opacity(0.55 * (1 - seeThrough)))
                }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(speakerColor.opacity(0.5), lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.06 + (1 - seeThrough) * 0.2), radius: 12, y: 6)
        .animation(.easeOut(duration: 0.25), value: caption.toneTag)
    }
    }

#Preview {
    CaptionBubbleView(caption: LiveCaption(speakerName: "Daniel", toneTag: "Question", text: "Say that again?"))
        .padding()
        .background(Color.graptionBackground)
}
