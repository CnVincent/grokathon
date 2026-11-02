import SwiftUI

struct LiveVideoFeedView: View {
    let captions: [LiveCaption]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ZStack(alignment: .bottom) {
            Image("LiveVideoPlaceholder", bundle: .module)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            if !captions.isEmpty {
                captionStack
                    .padding(12)
            }
        }
        .clipped()
    }

    // Accessibility text sizes need the full width to wrap in, so stack
    // captions vertically instead of squeezing three side by side. Stacked
    // bubbles can still exceed the video area's height at the largest sizes,
    // so make the stack scroll instead of overflowing into the header/controls.
    @ViewBuilder
    private var captionStack: some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(captions) { caption in
                        CaptionBubbleView(caption: caption)
                    }
                }
            }
            .scrollIndicators(.hidden)
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(captions) { caption in
                    CaptionBubbleView(caption: caption)
                }
            }
        }
    }
}

#Preview {
    LiveVideoFeedView(captions: [
        LiveCaption(speakerName: "Daniel", toneTag: "Question", text: "Say that again?"),
        LiveCaption(speakerName: "Helena", toneTag: "Calm", text: "Let's pause."),
        LiveCaption(speakerName: "Someone", text: "Next item.")
    ])
}
