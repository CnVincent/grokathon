//
//  AppleSoundDetectorTests.swift
//  Graption
//
//  Created by Arjun on 10/6/26.
//

import XCTest
@testable import GraptionAudio

final class AppleSoundDetectorTests: XCTestCase {
    func testSilenceRaisesNoAlerts() throws {
        let detector = try AppleSoundDetector()
        let received = expectation(description: "no alerts")
        received.isInverted = true

        detector.start { _ in received.fulfill() }

        // 3 s of silence in 20 ms buffers.
        let silence = Array(repeating: Float(0), count: 320)
        for index in 0..<150 {
            detector.process(
                samples: silence,
                tStart: Double(index) * 0.02
            )
        }
        detector.finish()

        wait(for: [received], timeout: 1)
    }
}
