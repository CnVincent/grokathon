import Foundation

/// Internal ASR output, before speaker fusion; not a generated schema event.
public struct TranscriptionResult: Sendable {
    public struct Word: Sendable {
        public let text: String
        public let tStart: TimeInterval
        public let tEnd: TimeInterval
    }

    public let captionID: UUID
    public let text: String
    public let tStart: TimeInterval
    public let tEnd: TimeInterval
    public let words: [Word]
    public let asrModelVersion: String

    public init(captionID: UUID, text: String, tStart: TimeInterval,
                tEnd: TimeInterval, words: [Word] = [], asrModelVersion: String) {
        self.captionID = captionID
        self.text = text
        self.tStart = tStart
        self.tEnd = tEnd
        self.words = words
        self.asrModelVersion = asrModelVersion
    }
}
