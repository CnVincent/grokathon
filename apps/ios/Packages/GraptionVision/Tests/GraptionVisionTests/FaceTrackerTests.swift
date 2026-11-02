// v3 (#10) done when: ids don't jump around when people move.
// boxes are normalized 0 to 1 and frames are 1/15 s apart like the live camera.
// run: swift test --package-path apps/ios/Packages/GraptionVision

import CoreGraphics
import XCTest
@testable import GraptionVision

final class FaceTrackerTests: XCTestCase {
    private let frame = 1.0 / 15.0

    private func face(_ x: CGFloat, _ y: CGFloat, size: CGFloat = 0.2) -> FaceMeasurement {
        FaceMeasurement(box: CGRect(x: x, y: y, width: size, height: size))
    }

    private func ids(_ tracks: [FaceTrack]) -> [String] { tracks.map(\.id) }

    func testNewFacesGetSequentialIDsStartingAtF1() {
        var tracker = FaceTracker()
        let tracks = tracker.update(with: [face(0.1, 0.1), face(0.6, 0.1), face(0.1, 0.6)], at: 0)
        XCTAssertEqual(ids(tracks), ["f1", "f2", "f3"])
    }

    func testIDsFollowFacesAsTheyMove() {
        var tracker = FaceTracker()
        _ = tracker.update(with: [face(0.1, 0.4), face(0.6, 0.4)], at: 0)

        // Both walk right ~1% of the frame per frame for 3 seconds.
        var tracks: [FaceTrack] = []
        for step in 1...45 {
            let dx = CGFloat(step) * 0.006
            tracks = tracker.update(with: [face(0.1 + dx, 0.4), face(0.6 + dx * 0.5, 0.4)], at: Double(step) * frame)
        }
        XCTAssertEqual(ids(tracks), ["f1", "f2"])
        XCTAssertLessThan(tracks[0].box.minX, tracks[1].box.minX)
    }

    func testDetectionOrderDoesNotSwapIDs() {
        var tracker = FaceTracker()
        _ = tracker.update(with: [face(0.1, 0.4), face(0.6, 0.4)], at: 0)
        let tracks = tracker.update(with: [face(0.61, 0.4), face(0.11, 0.4)], at: frame)
        let left = tracks.first { $0.box.minX < 0.5 }
        let right = tracks.first { $0.box.minX > 0.5 }
        XCTAssertEqual(left?.id, "f1")
        XCTAssertEqual(right?.id, "f2")
    }

    func testFastMoverWithoutOverlapKeepsIDViaCenterDistance() {
        var tracker = FaceTracker()
        _ = tracker.update(with: [face(0.1, 0.4)], at: 0)
        // Jumps a full face width: IoU is 0, but the center is within 1.5 face sizes.
        let tracks = tracker.update(with: [face(0.3, 0.4)], at: frame)
        XCTAssertEqual(ids(tracks), ["f1"])
    }

    func testFaceFarAwayGetsNewID() {
        var tracker = FaceTracker()
        _ = tracker.update(with: [face(0.0, 0.0)], at: 0)
        let tracks = tracker.update(with: [face(0.7, 0.7)], at: frame)
        // f1 still coasts at its old spot; the new face is f2.
        XCTAssertEqual(ids(tracks), ["f1", "f2"])
        XCTAssertEqual(tracks[1].box.minX, 0.7, accuracy: 1e-9)
    }

    func testBriefDropoutKeepsIDButHidesStaleBox() {
        var tracker = FaceTracker()
        _ = tracker.update(with: [face(0.4, 0.4)], at: 0)

        // Missed for 2 frames: still shown (predicted), without landmarks.
        XCTAssertEqual(ids(tracker.update(with: [], at: frame)), ["f1"])
        XCTAssertEqual(ids(tracker.update(with: [], at: 2 * frame)), ["f1"])
        // 3rd missed frame: hidden but not forgotten.
        XCTAssertEqual(ids(tracker.update(with: [], at: 3 * frame)), [])

        // Back after 0.6 s: same id.
        XCTAssertEqual(ids(tracker.update(with: [face(0.41, 0.4)], at: 0.6)), ["f1"])
    }

    func testBoxGoneForTwoSecondsKeepsID() {
        var tracker = FaceTracker()
        _ = tracker.update(with: [face(0.4, 0.4)], at: 0)
        // head turns to profile: box narrows and shifts then detection is lost.
        _ = tracker.update(with: [FaceMeasurement(box: CGRect(x: 0.45, y: 0.4, width: 0.1, height: 0.2))], at: frame)
        var time = 2 * frame
        while time < 2 + frame { _ = tracker.update(with: [], at: time); time += frame }
        // a full 2 s after it was last seen the face turns back.
        XCTAssertEqual(ids(tracker.update(with: [face(0.4, 0.4)], at: 2 + frame)), ["f1"])
    }

    func testTrackRetiredAfterTwoSecondsUnseen() {
        var tracker = FaceTracker()
        _ = tracker.update(with: [face(0.4, 0.4)], at: 0)
        _ = tracker.update(with: [], at: 2.05)
        XCTAssertEqual(ids(tracker.update(with: [face(0.4, 0.4)], at: 2.1)), ["f2"])
    }

    func testIDsAreNeverReusedWithinASession() {
        var tracker = FaceTracker()
        _ = tracker.update(with: [face(0.1, 0.1), face(0.6, 0.6)], at: 0)
        _ = tracker.update(with: [], at: 4)
        XCTAssertEqual(ids(tracker.update(with: [face(0.1, 0.1)], at: 4.1)), ["f3"])
    }

    func testResetStartsANewSession() {
        var tracker = FaceTracker()
        _ = tracker.update(with: [face(0.1, 0.1), face(0.6, 0.6)], at: 0)
        tracker.reset()
        XCTAssertEqual(ids(tracker.update(with: [face(0.6, 0.6)], at: 0.1)), ["f1"])
    }

    func testForgetTracksKeepsNumbering() {
        var tracker = FaceTracker()
        _ = tracker.update(with: [face(0.1, 0.1), face(0.6, 0.6)], at: 0)
        tracker.forgetTracks()
        XCTAssertEqual(ids(tracker.update(with: [face(0.1, 0.1)], at: 0.1)), ["f3"])
    }

    func testMissedFrameClearsLandmarks() {
        var tracker = FaceTracker()
        let mesh = [SIMD3<Float>(0.5, 0.5, 0)]
        let first = tracker.update(with: [FaceMeasurement(box: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), landmarks: mesh)], at: 0)
        XCTAssertTrue(first[0].hasLandmarks)
        let missed = tracker.update(with: [], at: frame)
        XCTAssertFalse(missed[0].hasLandmarks)
    }

    func testIoU() {
        let a = CGRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertEqual(iou(a, a), 1, accuracy: 1e-9)
        XCTAssertEqual(iou(a, CGRect(x: 0.5, y: 0, width: 1, height: 1)), 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(iou(a, CGRect(x: 2, y: 2, width: 1, height: 1)), 0)
    }
}
