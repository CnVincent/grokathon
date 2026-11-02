import Foundation
import Observation

/// Plays a scripted, looping fake session so the U1 caption screen has
/// something to show before the real sensors (GraptionVision/Audio/Fusion)
/// exist. Swap this out for the real pipeline once those land, behind the
/// same `captions` / `soundAlert` surface.
@MainActor
@Observable
public final class LiveCaptionSessionSimulator {
    public private(set) var captions: [LiveCaption] = []
    public private(set) var soundAlert: SoundAlert?

    private var runningTask: Task<Void, Never>?

    public init() {}

    public func start() {
        guard runningTask == nil else { return }
        runningTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.playScript()
            }
        }
    }

    public func stop() {
        runningTask?.cancel()
        runningTask = nil
    }

    private func playScript() async {
        captions = []
        soundAlert = nil

        let daniel = LiveCaption(speakerName: "Daniel", text: "Say that again?")
        captions.append(daniel)
        await sleep(0.8)
        setTag("Question", forCaptionId: daniel.id)

        await sleep(1.4)
        let helena = LiveCaption(speakerName: "Helena", text: "Let's pause.")
        captions.append(helena)
        await sleep(0.8)
        setTag("Calm", forCaptionId: helena.id)

        await sleep(1.4)
        let someone = LiveCaption(speakerName: "Someone", text: "Next item.")
        captions.append(someone)
        await sleep(0.8)
        setTag("Neutral", forCaptionId: someone.id)

        await sleep(1.5)
        soundAlert = SoundAlert(message: "Loud noise detected. Haptics enabled.")
        await sleep(4.0)
        soundAlert = nil

        await sleep(2.5)
    }

    private func setTag(_ tag: String, forCaptionId id: UUID) {
        guard let index = captions.firstIndex(where: { $0.id == id }) else { return }
        captions[index].toneTag = tag
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
