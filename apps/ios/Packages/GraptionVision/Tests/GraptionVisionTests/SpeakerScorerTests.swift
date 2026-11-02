// v3 (#10). checks the largest face guess and the speaker pick used for the live highlight.

import CoreGraphics
import XCTest
@testable import GraptionVision

final class SpeakerScorerTests: XCTestCase {
    private func track(_ id: String, size: CGFloat) -> FaceTrack {
        FaceTrack(id: id, box: CGRect(x: 0, y: 0, width: size, height: size))
    }

    func testLargestFaceScoresOneOthersZero() {
        let scores = LargestFaceScorer().scores(for: [track("f1", size: 0.1), track("f2", size: 0.3), track("f3", size: 0.2)], at: 0)
        XCTAssertEqual(scores, ["f1": 0, "f2": 1, "f3": 0])
        XCTAssertEqual(scores.likelySpeaker(), "f2")
    }

    func testTieGoesToOlderTrack() {
        let scores = LargestFaceScorer().scores(for: [track("f1", size: 0.2), track("f2", size: 0.2)], at: 0)
        XCTAssertEqual(scores.likelySpeaker(), "f1")
    }

    func testNoFacesNoSpeaker() {
        let scores = LargestFaceScorer().scores(for: [], at: 0)
        XCTAssertTrue(scores.isEmpty)
        XCTAssertNil(scores.likelySpeaker())
    }

    func testLikelySpeakerRespectsThreshold() {
        XCTAssertNil(["f1": 0.4, "f2": 0.3].likelySpeaker())
        XCTAssertEqual(["f1": 0.4, "f2": 0.7].likelySpeaker(), "f2")
    }
}
