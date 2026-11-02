import XCTest
@testable import GraptionCore

final class CaptionSpeakerTests: XCTestCase {
    func testClearWinnerUsesWindowAverage() {
        let samples: [(time: Double, faceID: String, score: Double)] = [
            (0, "f2", 1.0),
            (1, "f1", 0.9),
            (2, "f1", 0.7),
            (1, "f2", 0.6),
            (2, "f2", 0.4),
        ]

        XCTAssertEqual(captionSpeaker(from: samples, during: 1...2), "f1")
        XCTAssertEqual(captionSpeaker(from: samples, during: 0...0), "f2")
    }

    func testTie() {
        XCTAssertEqual(captionSpeaker(from: [
            (1, "f1", 0.8),
            (1, "f2", 0.8),
        ], during: 1...2), "unknown")
    }

    func testNoFaces() {
        XCTAssertEqual(
            captionSpeaker(from: [], during: 1...2), "unknown"
        )
    }

    func testBelowMinimum() {
        XCTAssertEqual(captionSpeaker(from: [
            (1, "f1", 0.49),
        ], during: 1...2), "unknown")
    }

    func testInsufficientLead() {
        XCTAssertEqual(captionSpeaker(from: [
            (1, "f1", 0.8),
            (1, "f2", 0.7),
        ], during: 1...2), "unknown")
    }
}
