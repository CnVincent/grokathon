//
//  EnergyVAD.swift
//  Graption
//
//  Created by Derek Kwong on 10/5/26.
//

import Foundation

public final class EnergyVAD {
    private var segmentStart: TimeInterval?
    private var segmentSamples: [Float] = []
    private var silenceDuration: TimeInterval = 0
    // Keep 300 ms before activation so quieter word beginnings reach the ASR model.
    private var preRollSamples: [Float] = []
    private let maxPreRollSamples = 4_800

    public private(set) var threshold: Float
    private var isCalibrating = false
    private var calibrationLevels: [Float] = []
    private var calibrationEnergy: Double = 0
    private var calibrationWindowSamples = 0
    // Bound memory to the first 30 seconds, measured in fixed 20 ms windows.
    private let maxCalibrationWindows = 1_500
    private let sampleRate: Double = 16_000
    private let maxSegmentSamples = 160_000

    public init(threshold: Float) {
        precondition(threshold.isFinite && threshold > 0)
        self.threshold = threshold
    }

    /// Collect ambient noise only; no segments are emitted in this mode.
    public func beginCalibration() {
        reset()
        isCalibrating = true
    }

    public func completeCalibration() throws -> Float {
        defer { reset() }
        guard isCalibrating, calibrationLevels.count >= 100 else {
            throw CalibrationError.tooShort
        }
        let sorted = calibrationLevels.sorted()
        let noise = sorted[Int(ceil(Double(sorted.count) * 0.9)) - 1]
        // Twice the 90th-percentile RMS (~6 dB margin); isolated spikes do not dominate.
        threshold = max(0.001, noise * 2)
        return threshold
    }

    public func process(
        samples: [Float],
        tStart: TimeInterval
    ) -> [AudioSegment] {
        guard !samples.isEmpty else { return [] }
        if isCalibrating {
            collectCalibration(samples)
            return []
        }

        var completed: [AudioSegment] = []
        var offset = 0

        // Usually runs once. If a buffer crosses the 10-second
        // boundary, loop again to process the remaining samples.
        while offset < samples.count {
            // At 16 kHz, exactly 20 ms means 320 samples.
            // Ten seconds is exactly 500 such buffers, so those
            // buffers would not need a partial split.
            //
            // Actual buffer sizes may vary. Limit this chunk to
            // the remaining capacity to enforce the 10-second cap.
            // Reserve room for pre-roll before choosing a chunk, including large buffers.
            let prefixCount = segmentStart == nil ? preRollSamples.count : 0
            let remainingCapacity =
                maxSegmentSamples - segmentSamples.count - prefixCount
            let count = min(
                remainingCapacity,
                samples.count - offset
            )

            let chunk = Array(samples[offset..<(offset + count)])
            let chunkStart = tStart + Double(offset) / sampleRate
            let duration = Double(count) / sampleRate
            let isSpeech = rms(chunk) >= threshold

            // Begin a segment when speech is detected while idle.
            if isSpeech && segmentStart == nil {
                segmentStart = chunkStart - Double(preRollSamples.count) / sampleRate
                segmentSamples.append(contentsOf: preRollSamples)
                preRollSamples.removeAll(keepingCapacity: true)
            }

            // Retain a bounded look-back while idle; never emit silence alone.
            if segmentStart != nil {
                // Keep quiet samples too, preserving pauses.
                segmentSamples.append(contentsOf: chunk)

                if isSpeech {
                    silenceDuration = 0
                } else {
                    silenceDuration += duration
                }

                // Finish after 500 ms of consecutive silence
                // or exactly 10 seconds of collected audio.
                if silenceDuration >= 0.5
                    || segmentSamples.count >= maxSegmentSamples {
                    if let segment = finishSegment() {
                        completed.append(segment)
                    }
                }
            } else {
                // Keep only the latest 300 ms, even if this input buffer is larger.
                if chunk.count >= maxPreRollSamples {
                    preRollSamples = Array(chunk.suffix(maxPreRollSamples))
                } else {
                    preRollSamples.append(contentsOf: chunk)
                    let excess = preRollSamples.count - maxPreRollSamples
                    if excess > 0 { preRollSamples.removeFirst(excess) }
                }
            }

            // Continue processing any samples left after a split.
            offset += count
        }

        return completed
    }

    /// Call when capture stops to emit any unfinished segment.
    public func flush() -> AudioSegment? {
        // Calibration contains no caption audio to flush.
        guard !isCalibrating else { return nil }
        return finishSegment()
    }

    /// Discard unfinished audio when cancelling a session.
    public func reset() {
        segmentStart = nil
        segmentSamples.removeAll(keepingCapacity: true)
        preRollSamples.removeAll(keepingCapacity: true)
        silenceDuration = 0
        isCalibrating = false
        calibrationLevels.removeAll(keepingCapacity: true)
        calibrationEnergy = 0
        calibrationWindowSamples = 0
    }

    private func collectCalibration(_ samples: [Float]) {
        for sample in samples {
            guard calibrationLevels.count < maxCalibrationWindows else { break }
            // Reject unusable input rather than calibrating from non-finite samples.
            guard sample.isFinite else { reset(); return }
            calibrationEnergy += Double(sample) * Double(sample)
            calibrationWindowSamples += 1
            if calibrationWindowSamples == 320 {
                calibrationLevels.append(Float((calibrationEnergy / 320).squareRoot()))
                calibrationEnergy = 0
                calibrationWindowSamples = 0
            }
        }
    }

    private func finishSegment() -> AudioSegment? {
        guard let start = segmentStart,
              !segmentSamples.isEmpty else {
            reset()
            return nil
        }

        // Includes trailing silence. Assumes continuous 16 kHz audio.
        let segment = AudioSegment(
            samples: segmentSamples,
            tStart: start,
            tEnd: start + Double(segmentSamples.count) / sampleRate
        )

        reset()
        return segment
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }

        let meanSquare = samples.reduce(Float(0)) {
            $0 + $1 * $1
        } / Float(samples.count)

        return meanSquare.squareRoot()
    }
}

public enum CalibrationError: LocalizedError {
    case tooShort
    public var errorDescription: String? {
        "Calibration needs at least 2 seconds of captured room noise without speaking. Previous threshold kept."
    }
}
