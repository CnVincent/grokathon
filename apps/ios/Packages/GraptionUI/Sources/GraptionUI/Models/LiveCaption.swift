import Foundation

/// A single on-screen caption. Mirrors the shape of the future `caption` /
/// `tone_result` events from `schemas/events.schema.json`; `toneTag` starts
/// `nil` and is filled in after the fact, same as a real tone result arriving
/// late by `caption_id`.
public struct LiveCaption: Identifiable, Equatable {
    public let id: UUID
    public var speakerName: String
    public var toneTag: String?
    public var text: String

    public init(id: UUID = UUID(), speakerName: String, toneTag: String? = nil, text: String) {
        self.id = id
        self.speakerName = speakerName
        self.toneTag = toneTag
        self.text = text
    }
}
