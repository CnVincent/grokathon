//
//  AudioSegment.swift
//  Graption
//
//  Created by Derek Kwong on 10/5/26.
//

import Foundation

public struct AudioSegment: Sendable {
    public let captionID: UUID
    public let samples: [Float]
    public let tStart: TimeInterval
    public let tEnd: TimeInterval

    public init(
        samples: [Float],
        tStart: TimeInterval,
        tEnd: TimeInterval
    ) {
        self.captionID = UUID()
        self.samples = samples
        self.tStart = tStart
        self.tEnd = tEnd
    }
}
