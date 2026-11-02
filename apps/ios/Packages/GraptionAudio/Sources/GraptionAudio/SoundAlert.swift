//
//  SoundAlert.swift
//  Graption
//
//  Created by Arjun on 10/6/26.
//

import Foundation

// In-package form of the schema's `sound_event`. The app adds
// session_id and schema_version when it builds the event.
public struct SoundAlert: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let label: String
    public let t: TimeInterval
    public let confidence: Double

    public init(
        label: String,
        t: TimeInterval,
        confidence: Double
    ) {
        self.id = UUID()
        self.label = label
        self.t = t
        self.confidence = confidence
    }
}
