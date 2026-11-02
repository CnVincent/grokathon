import Foundation

/// Session owner calls append as captions render, then end when capture stops.
/// Ending never waits for a tone response. Failed saves retain the transcript for retry.
@MainActor
public final class SessionRecorder {
    public private(set) var session: SavedSession
    public private(set) var hasEnded = false
    private let clock = SessionClock()
    private let store: any SessionStore

    public init(store: any SessionStore) {
        self.store = store
        session = SavedSession(duration: 0, captions: [])
    }

    public func append(_ caption: SavedCaption) {
        guard !hasEnded, !session.captions.contains(where: { $0.id == caption.id }) else { return }
        session.captions.append(caption)
    }

    public func end() async throws {
        if !hasEnded {
            session.duration = max(clock.secondsElapsed, session.captions.map(\.tEnd).max() ?? 0)
            hasEnded = true
        }
        try await store.save(session)
    }

    /// Route results by caption ID. A late tag updates the saved session without delaying end().
    public func applyTone(captionID: UUID, tag: String?, modelVersion: String) async throws {
        guard let index = session.captions.firstIndex(where: { $0.id == captionID }) else { return }
        session.captions[index].toneTag = tag
        session.captions[index].modelVersions["tone"] = modelVersion
        if hasEnded { try await store.save(session) }
    }
}
