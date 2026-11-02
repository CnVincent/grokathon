//
//  SoundDetector.swift
//  Graption
//
//  Created by Arjun on 10/6/26.
//

import Foundation

// Anything that turns mic audio into sound alerts.
// MicrophoneCapture calls these in order from one queue.
public protocol SoundDetector: AnyObject, Sendable {
    // Clears state and sets where alerts go, on any thread.
    func start(onAlert: @escaping @Sendable (SoundAlert) -> Void)

    // 16 kHz mono float samples starting at `tStart`.
    func process(samples: [Float], tStart: TimeInterval)

    // Called after the last buffer to emit anything pending.
    func finish()
}

// Lets UI work fire alerts without a mic or classifier.
public final class MockSoundDetector: SoundDetector, @unchecked Sendable {
    private var onAlert: (@Sendable (SoundAlert) -> Void)?

    public init() {}

    public func start(
        onAlert: @escaping @Sendable (SoundAlert) -> Void
    ) {
        self.onAlert = onAlert
    }

    public func process(samples: [Float], tStart: TimeInterval) {}

    public func finish() {}

    public func trigger(
        _ label: String,
        t: TimeInterval = 0,
        confidence: Double = 1
    ) {
        onAlert?(
            SoundAlert(label: label, t: t, confidence: confidence)
        )
    }
}
