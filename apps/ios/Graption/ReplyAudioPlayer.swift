import AVFoundation

enum ReplyPlaybackError: LocalizedError {
    case unplayable

    var errorDescription: String? { "Graption could not play that reply." }
}

/// Plays a Grok audio clip, or speaks text with the on-device voice.
@MainActor
final class ReplyAudioPlayer: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func play(data: Data) async throws {
        try activatePlayback()
        guard let player = AVAudioPlayer(data: data) else { throw ReplyPlaybackError.unplayable }
        self.player = player
        player.delegate = self
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            guard player.play() else {
                self.continuation = nil
                continuation.resume(throwing: ReplyPlaybackError.unplayable)
                return
            }
        }
    }

    func speak(text: String, language: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try activatePlayback()
        let utterance = AVSpeechUtterance(string: trimmed)
        let prefix = String(language.prefix(2))
        utterance.voice = AVSpeechSynthesisVoice(language: language) ?? AVSpeechSynthesisVoice(language: prefix)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            synthesizer.speak(utterance)
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(success: flag)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finish(success: false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish(success: true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish(success: false)
    }

    private func activatePlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
    }

    private func finish(success: Bool) {
        let continuation = continuation
        self.continuation = nil
        if success {
            continuation?.resume()
        } else {
            continuation?.resume(throwing: ReplyPlaybackError.unplayable)
        }
    }
}
