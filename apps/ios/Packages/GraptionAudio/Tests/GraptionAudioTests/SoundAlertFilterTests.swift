//
//  SoundAlertFilterTests.swift
//  Graption
//
//  Created by Arjun on 10/6/26.
//

import XCTest
@testable import GraptionAudio

final class SoundAlertFilterTests: XCTestCase {
    func testAllowlistUsesRealAppleLabels() throws {
        let known = Set(try AppleSoundDetector.knownClassifications())
        let missing = Set(SoundAlertFilter.labels.keys)
            .subtracting(known)

        XCTAssertEqual(missing, [])
    }

    func testAllowlistCoversEveryAlertType() {
        XCTAssertEqual(
            Set(SoundAlertFilter.labels.values),
            [
                "doorbell", "knock", "alarm", "siren",
                "dog_bark", "baby_cry", "laughter", "phone_ring"
            ]
        )
    }

    func testConfidentAllowlistedSoundAlerts() throws {
        var filter = SoundAlertFilter()

        let alerts = filter.alerts(
            for: [(identifier: "door_bell", confidence: 0.9)],
            at: 4.5
        )

        let alert = try XCTUnwrap(alerts.first)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alert.label, "doorbell")
        XCTAssertEqual(alert.t, 4.5)
        XCTAssertEqual(alert.confidence, 0.9)
    }

    func testLowConfidenceIsIgnored() {
        var filter = SoundAlertFilter()

        let alerts = filter.alerts(
            for: [(identifier: "door_bell", confidence: 0.69)],
            at: 0
        )

        XCTAssertTrue(alerts.isEmpty)
    }

    func testSoundsOutsideAllowlistAreIgnored() {
        var filter = SoundAlertFilter()

        let alerts = filter.alerts(
            for: [
                (identifier: "speech", confidence: 0.99),
                (identifier: "music", confidence: 0.95)
            ],
            at: 0
        )

        XCTAssertTrue(alerts.isEmpty)
    }

    func testSharedLabelKeepsHighestConfidence() {
        var filter = SoundAlertFilter()

        let alerts = filter.alerts(
            for: [
                (identifier: "police_siren", confidence: 0.75),
                (identifier: "siren", confidence: 0.92)
            ],
            at: 0
        )

        XCTAssertEqual(alerts.map(\.label), ["siren"])
        XCTAssertEqual(alerts.first?.confidence, 0.92)
    }

    func testCooldownIsPerLabel() {
        var filter = SoundAlertFilter()
        let doorbell = [(identifier: "door_bell", confidence: 0.9)]
        let knock = [(identifier: "knock", confidence: 0.9)]

        XCTAssertEqual(filter.alerts(for: doorbell, at: 0).count, 1)

        // Same label inside 3 s is suppressed; others are not.
        XCTAssertTrue(filter.alerts(for: doorbell, at: 2.9).isEmpty)
        XCTAssertEqual(filter.alerts(for: knock, at: 2.9).count, 1)

        XCTAssertEqual(filter.alerts(for: doorbell, at: 3.0).count, 1)
    }

    func testResetClearsCooldown() {
        var filter = SoundAlertFilter()
        let doorbell = [(identifier: "door_bell", confidence: 0.9)]

        XCTAssertEqual(filter.alerts(for: doorbell, at: 0).count, 1)
        filter.reset()
        XCTAssertEqual(filter.alerts(for: doorbell, at: 1).count, 1)
    }
}
