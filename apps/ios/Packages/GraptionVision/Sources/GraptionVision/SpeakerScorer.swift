//
//  SpeakerScorer.swift
//  GraptionVision
//
//  v3 (#10). the speaker model interface plus a stand in guess.
//  the core ml model (GRAPTION_CONTEXT.md §6 SpeakerModel) will replace
//  `LargestFaceScorer` behind this protocol without touching callers.
//

import CoreGraphics

public protocol SpeakerScorer {
    /// p(speaking) from 0 to 1 for each face keyed by face id. called once per frame in order.
    /// `mutating` so real models can keep per face history.
    mutating func scores(for faces: [FaceTrack], at timestamp: Double) -> [String: Double]
}

/// placeholder until the speaker model ships. the largest face gets 1 and the rest get 0.
/// ties go to the older track (first in `faces`).
public struct LargestFaceScorer: SpeakerScorer, Sendable {
    public init() {}

    public func scores(for faces: [FaceTrack], at timestamp: Double) -> [String: Double] {
        // strict > keeps the first face on a tie.
        var largest: FaceTrack?
        for face in faces where largest.map({ area(face.box) > area($0.box) }) ?? true {
            largest = face
        }
        return Dictionary(uniqueKeysWithValues: faces.map { ($0.id, $0.id == largest?.id ? 1.0 : 0.0) })
    }

    private func area(_ box: CGRect) -> CGFloat { box.width * box.height }
}

extension Dictionary where Key == String, Value == Double {
    /// the face most likely speaking or nil if none reaches `threshold`.
    /// for the live camera highlight only. caption to speaker matching is fusion's job (p7 #28).
    public func likelySpeaker(threshold: Double = 0.5) -> String? {
        guard let best = self.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }),
              best.value >= threshold else { return nil }
        return best.key
    }
}
