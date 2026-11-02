//
//  OneEuroFilter.swift
//  GraptionVision
//
//  smooths jittery box coordinates. moved unchanged from Graption/CameraView.swift (v2).
//

import Foundation

struct OneEuroFilter: Sendable {
    private let minCutoff: Double
    private let beta: Double
    private let derivativeCutoff: Double
    private var previousValue: Double?
    private var previousDerivative = 0.0
    private var previousTimestamp: Double?

    // Inputs are normalized (0...1) image coordinates, so beta is much larger than the
    // pixel-space defaults from the paper; otherwise the speed term never reduces lag.
    init(minCutoff: Double = 1.25, beta: Double = 8.0, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    mutating func filter(_ value: Double, at timestamp: Double) -> Double {
        guard let previousValue, let previousTimestamp else {
            self.previousValue = value
            self.previousTimestamp = timestamp
            return value
        }

        let deltaTime = max(timestamp - previousTimestamp, 1.0 / 120.0)
        let rawDerivative = (value - previousValue) / deltaTime
        let derivativeAlpha = smoothingFactor(deltaTime, cutoff: derivativeCutoff)
        let derivative = exponentialFilter(
            rawDerivative,
            previous: self.previousDerivative,
            alpha: derivativeAlpha
        )
        let valueAlpha = smoothingFactor(deltaTime, cutoff: minCutoff + beta * abs(derivative))
        let filteredValue = exponentialFilter(value, previous: previousValue, alpha: valueAlpha)

        self.previousValue = filteredValue
        self.previousDerivative = derivative
        self.previousTimestamp = timestamp
        return filteredValue
    }

    private func smoothingFactor(_ deltaTime: Double, cutoff: Double) -> Double {
        let tau = 1.0 / (2.0 * .pi * cutoff)
        return 1.0 / (1.0 + tau / deltaTime)
    }

    private func exponentialFilter(_ value: Double, previous: Double, alpha: Double) -> Double {
        alpha * value + (1.0 - alpha) * previous
    }
}
