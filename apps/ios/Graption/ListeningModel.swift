import GraptionAudio
import Observation
import SwiftUI

/// Alert presentation only. ContentView owns the shared microphone and session.
@MainActor
@Observable
final class SoundAlertModel {
    private(set) var currentAlert: SoundAlert?
    private var dismissalTask: Task<Void, Never>?

    func show(_ alert: SoundAlert) {
        dismissalTask?.cancel()
        currentAlert = alert
        print(String(
            format: "Sound %@ at %.2f s (%.2f) model=%@",
            alert.label, alert.t, alert.confidence, AppleSoundDetector.modelVersion
        ))
        AccessibilityNotification.Announcement(
            SoundAlertBanner.title(for: alert.label)
        ).post()

        dismissalTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            // An old timer must never dismiss a newer alert.
            guard let self, self.currentAlert?.id == alert.id else { return }
            self.currentAlert = nil
        }
    }

    func clear() {
        dismissalTask?.cancel()
        dismissalTask = nil
        currentAlert = nil
    }
}
