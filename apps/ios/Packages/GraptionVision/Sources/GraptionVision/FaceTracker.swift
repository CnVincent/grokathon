//
//  FaceTracker.swift
//  GraptionVision
//
//  v3 (#10). gives each face a stable per session id (f1 f2 ...).
//  moved out of Graption/CameraView.swift so it can be unit tested without a camera.
//  spec: GRAPTION_CONTEXT.md §6 FaceTracker.
//

import CoreGraphics
import Foundation

/// one detected face in one frame before tracking.
/// `box` and `landmarks` are normalized to the full portrait frame with a top left origin.
public struct FaceMeasurement: Sendable, Equatable {
    public let box: CGRect
    public let landmarks: [SIMD3<Float>]

    public init(box: CGRect, landmarks: [SIMD3<Float>] = []) {
        self.box = box
        self.landmarks = landmarks
    }
}

/// one tracked face as published to the app.
/// `landmarks` is empty when mediapipe found no mesh or the face was missed this frame.
public struct FaceTrack: Identifiable, Sendable, Equatable {
    /// `f1` `f2` ... unique within a session. matches `FaceId` in schemas/events.schema.json.
    public let id: String
    public let box: CGRect
    public let landmarks: [SIMD3<Float>]

    public var hasLandmarks: Bool { !landmarks.isEmpty }

    public init(id: String, box: CGRect, landmarks: [SIMD3<Float>] = []) {
        self.id = id
        self.box = box
        self.landmarks = landmarks
    }
}

/// matches each frame's faces to existing tracks so ids stay put as people move.
///
/// matching is greedy over all pairs best first so detection order can't swap ids.
/// pass 1 pairs by iou >= `minIoU`. pass 2 pairs the leftovers by center distance
/// to catch fast movers whose boxes no longer overlap.
///
/// a track lives `maxUnseen` seconds without a match so a face that drops out briefly
/// gets its old id back. it is only published for `maxCoastFrames` missed frames
/// so stale boxes don't linger on screen.
///
/// changes from the v2 tracker: iou pass added. ids are strings not ints.
/// tracks live 2 s instead of being dropped after 2 missed frames.
public struct FaceTracker: Sendable {
    public var minIoU: CGFloat = 0.3
    /// center distance limit as a multiple of the track's larger side.
    public var maxCenterDistance: CGFloat = 1.5
    /// seconds a track survives without a match before its id is retired.
    /// 2 s not 1 s so a face can turn away and back without a new id (on device test).
    /// tradeoff: someone new stepping into that spot within 2 s inherits the id.
    public var maxUnseen: Double = 2.0
    /// missed frames during which a track is still published at its predicted spot.
    public var maxCoastFrames = 2

    private var tracks: [TrackedFace] = []
    /// next id number. only `reset()` rewinds it so ids are never reused in a session.
    private var nextNumber = 1

    public init() {}

    /// updates tracks with this frame's faces and returns the faces to show. oldest track first.
    /// `timestamp` is in seconds and must not decrease between calls.
    public mutating func update(with measurements: [FaceMeasurement], at timestamp: Double) -> [FaceTrack] {
        var unmatchedTracks = Set(tracks.indices)
        var unmatchedMeasurements = Set(measurements.indices)

        // takes pairs in the given order and skips any whose track or face is already taken.
        func assign(_ candidates: [(track: Int, measurement: Int)]) {
            for candidate in candidates
            where unmatchedTracks.contains(candidate.track) && unmatchedMeasurements.contains(candidate.measurement) {
                tracks[candidate.track].update(with: measurements[candidate.measurement], timestamp: timestamp)
                unmatchedTracks.remove(candidate.track)
                unmatchedMeasurements.remove(candidate.measurement)
            }
        }

        // pass 1. overlap. highest iou first.
        var overlaps: [(track: Int, measurement: Int, iou: CGFloat)] = []
        for trackIndex in tracks.indices {
            for measurementIndex in measurements.indices {
                let overlap = iou(tracks[trackIndex].box, measurements[measurementIndex].box)
                if overlap >= minIoU {
                    overlaps.append((trackIndex, measurementIndex, overlap))
                }
            }
        }
        assign(overlaps.sorted { $0.iou > $1.iou }.map { ($0.track, $0.measurement) })

        // pass 2. center distance for whatever is left. closest first.
        var nearby: [(track: Int, measurement: Int, distance: CGFloat)] = []
        for trackIndex in unmatchedTracks {
            let box = tracks[trackIndex].box
            let radius = max(box.width, box.height) * maxCenterDistance
            for measurementIndex in unmatchedMeasurements {
                let distance = centerDistance(box, measurements[measurementIndex].box)
                if distance <= radius {
                    nearby.append((trackIndex, measurementIndex, distance))
                }
            }
        }
        assign(nearby.sorted { $0.distance < $1.distance }.map { ($0.track, $0.measurement) })

        // unmatched tracks coast. unmatched faces become new tracks.
        for trackIndex in unmatchedTracks {
            tracks[trackIndex].predict(at: timestamp)
        }
        for measurementIndex in unmatchedMeasurements.sorted() {
            tracks.append(
                TrackedFace(id: "f\(nextNumber)", measurement: measurements[measurementIndex], timestamp: timestamp)
            )
            nextNumber += 1
        }

        // retire tracks unseen too long or coasted fully out of frame.
        tracks.removeAll { track in
            timestamp - track.lastSeen > maxUnseen ||
                track.box.maxX < 0 || track.box.minX > 1 || track.box.maxY < 0 || track.box.minY > 1
        }
        // still alive but missed for a while means remembered not shown.
        return tracks.filter { $0.missedFrames <= maxCoastFrames }.map(\.output)
    }

    /// forgets every track and restarts ids at `f1`. call when a session ends.
    public mutating func reset() {
        tracks.removeAll()
        nextNumber = 1
    }

    /// forgets every track mid session. used after the frame rotates since old boxes no longer
    /// line up. faces come back with new ids and old ids are not reused.
    public mutating func forgetTracks() {
        tracks.removeAll()
    }
}

/// intersection over union of two boxes. 0 when they don't touch.
func iou(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let intersection = lhs.intersection(rhs)
    guard !intersection.isNull, !intersection.isEmpty else { return 0 }
    let intersectionArea = intersection.width * intersection.height
    let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
    return unionArea > 0 ? intersectionArea / unionArea : 0
}

private func centerDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
}

/// internal state for one track. smoothing and prediction are unchanged from v2.
private struct TrackedFace: Sendable {
    let id: String
    var box: CGRect
    var landmarks: [SIMD3<Float>] = []
    var velocity = CGPoint.zero
    var missedFrames = 0
    /// last time a face was matched. drives the `maxUnseen` cutoff.
    private(set) var lastSeen: Double
    var xFilter = OneEuroFilter()
    var yFilter = OneEuroFilter()
    var widthFilter = OneEuroFilter()
    var heightFilter = OneEuroFilter()
    private var lastTimestamp: Double?

    init(id: String, measurement: FaceMeasurement, timestamp: Double) {
        self.id = id
        self.box = measurement.box
        self.lastSeen = timestamp
        update(with: measurement, timestamp: timestamp)
    }

    /// matched this frame. smooth the box and record velocity for coasting.
    mutating func update(with measurement: FaceMeasurement, timestamp: Double) {
        let filtered = CGRect(
            x: xFilter.filter(measurement.box.minX, at: timestamp),
            y: yFilter.filter(measurement.box.minY, at: timestamp),
            width: widthFilter.filter(measurement.box.width, at: timestamp),
            height: heightFilter.filter(measurement.box.height, at: timestamp)
        )
        if let lastTimestamp {
            let timeScale = max(timestamp - lastTimestamp, 1.0 / 120.0)
            velocity = CGPoint(
                x: (filtered.midX - box.midX) / timeScale,
                y: (filtered.midY - box.midY) / timeScale
            )
        }
        box = filtered
        landmarks = measurement.landmarks
        missedFrames = 0
        lastSeen = timestamp
        lastTimestamp = timestamp
    }

    /// missed this frame. drift along the last velocity which decays toward zero.
    mutating func predict(at timestamp: Double) {
        let deltaTime = max(timestamp - (lastTimestamp ?? timestamp), 1.0 / 120.0)
        let decay = pow(0.65, deltaTime * 15.0)
        box = box.offsetBy(
            dx: velocity.x * deltaTime * decay,
            dy: velocity.y * deltaTime * decay
        )
        velocity.x *= decay
        velocity.y *= decay
        // landmarks from an older frame would not line up with the predicted box.
        landmarks = []
        missedFrames += 1
        lastTimestamp = timestamp
    }

    var output: FaceTrack { FaceTrack(id: id, box: box, landmarks: landmarks) }
}
