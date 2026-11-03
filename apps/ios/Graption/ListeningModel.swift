import GraptionAudio
import GraptionNetwork
import Observation
import SwiftUI

/// Alert presentation only. ContentView owns the shared microphone and session.
/// Siren and alarm banners show immediately. Official context, when it arrives, updates the same banner.
@MainActor
@Observable
final class SoundAlertModel {
    private(set) var currentAlert: SoundAlert?
    /// Confident explanation, already formatted for the banner. Nil keeps the plain label.
    private(set) var contextLine: String?
    private var dismissalTask: Task<Void, Never>?
    private var contextTask: Task<Void, Never>?
    private let contextClient: (any SirenContextClient)?

    private static let plainHold: Duration = .seconds(4)
    /// Longer than the client's 10s timeout, so a late answer can still land.
    private static let contextHold: Duration = .seconds(12)
    private static let contextReadHold: Duration = .seconds(8)

    init(contextClient: (any SirenContextClient)? = nil) {
        self.contextClient = contextClient
    }

    func show(_ alert: SoundAlert) {
        dismissalTask?.cancel()
        contextTask?.cancel()
        currentAlert = alert
        contextLine = nil
        let plainTitle = SoundAlertBanner.title(for: alert.label)
        print(String(
            format: "Sound %@ at %.2f s (%.2f) model=%@",
            alert.label, alert.t, alert.confidence, AppleSoundDetector.modelVersion
        ))
        AccessibilityNotification.Announcement(plainTitle).post()

        let looksUp = SirenContextCopy.needsContext(alert.label) && contextClient != nil
        scheduleDismissal(of: alert, after: looksUp ? Self.contextHold : Self.plainHold)
        guard looksUp, let contextClient else { return }
        print("Siren context lookup model=\(contextClient.modelVersion) label=\(alert.label)")
        contextTask = Task { [weak self] in
            let reason = await contextClient.explain(label: alert.label)
            guard !Task.isCancelled, let self else { return }
            guard let line = SirenContextCopy.applying(
                alertID: alert.id,
                currentID: self.currentAlert?.id,
                label: alert.label,
                reason: reason
            ) else {
                if self.currentAlert?.id == alert.id {
                    print("Siren context miss model=\(contextClient.modelVersion) label=\(alert.label)")
                }
                return
            }
            self.contextLine = line
            print("Siren context model=\(contextClient.modelVersion) \(line)")
            AccessibilityNotification.Announcement(line).post()
            self.scheduleDismissal(of: alert, after: Self.contextReadHold)
        }
    }

    func clear() {
        dismissalTask?.cancel()
        dismissalTask = nil
        contextTask?.cancel()
        contextTask = nil
        currentAlert = nil
        contextLine = nil
    }

    private func scheduleDismissal(of alert: SoundAlert, after duration: Duration) {
        dismissalTask?.cancel()
        dismissalTask = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            // An old timer must never dismiss a newer alert.
            guard let self, self.currentAlert?.id == alert.id else { return }
            self.currentAlert = nil
            self.contextLine = nil
        }
    }
}
