//
//  AppleSoundDetector.swift
//  Graption
//
//  Created by Arjun on 10/6/26.
//

import AVFoundation
import Dispatch
import SoundAnalysis

// Apple's built-in on-device sound classifier. Works offline.
// Analyzer, filter, and clock state are used only on `queue`.
public final class AppleSoundDetector: SoundDetector, @unchecked Sendable {
    public static let modelVersion = "apple-soundanalysis-v1"

    private let queue = DispatchQueue(
        label: "graption.audio.sounds"
    )

    private let format: AVAudioFormat
    private let request: SNClassifySoundRequest
    private let defaultFilter: SoundAlertFilter

    private var analyzer: SNAudioStreamAnalyzer?
    private var observer: ResultsObserver?
    private var filter: SoundAlertFilter
    private var onAlert: (@Sendable (SoundAlert) -> Void)?
    private var streamStart: TimeInterval?
    private var nextFramePosition: AVAudioFramePosition = 0

    public init(filter: SoundAlertFilter = SoundAlertFilter()) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw SoundDetectorError.invalidFormat
        }

        let request = try SNClassifySoundRequest(
            classifierIdentifier: .version1
        )

        // The default 3 s window is too slow for the 1 s alert
        // target. 1 s with 50% overlap gives a result every 0.5 s.
        request.windowDuration = CMTime(
            seconds: 1,
            preferredTimescale: 16_000
        )
        request.overlapFactor = 0.5

        self.format = format
        self.request = request
        self.defaultFilter = filter
        self.filter = filter
    }

    // Every label the classifier can report (303 in `.version1`).
    public static func knownClassifications() throws -> [String] {
        try SNClassifySoundRequest(
            classifierIdentifier: .version1
        ).knownClassifications
    }

    public func start(
        onAlert: @escaping @Sendable (SoundAlert) -> Void
    ) {
        queue.async { [self] in
            // A completed analyzer can't be reused, so make a new one.
            let analyzer = SNAudioStreamAnalyzer(format: format)
            let observer = ResultsObserver { [weak self] result in
                self?.queue.async {
                    self?.handle(result)
                }
            }

            do {
                try analyzer.add(request, withObserver: observer)
            } catch {
                print("Sound analysis unavailable: \(error)")
                self.analyzer = nil
                return
            }

            self.analyzer = analyzer
            self.observer = observer
            self.onAlert = onAlert
            filter = defaultFilter
            streamStart = nil
            nextFramePosition = 0
        }
    }

    public func process(samples: [Float], tStart: TimeInterval) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?[0] else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }

        queue.async { [self] in
            guard let analyzer else { return }

            let start = streamStart ?? tStart
            streamStart = start

            // Positions must only move forward, even across the
            // capture worker resetting its clock after an error.
            let position = max(
                nextFramePosition,
                AVAudioFramePosition(
                    ((tStart - start) * format.sampleRate).rounded()
                )
            )
            nextFramePosition = position + AVAudioFramePosition(
                buffer.frameLength
            )

            analyzer.analyze(buffer, atAudioFramePosition: position)
        }
    }

    public func finish() {
        queue.sync {
            analyzer?.completeAnalysis()
            analyzer = nil
        }
    }

    private func handle(_ result: SNClassificationResult) {
        guard let start = streamStart, let onAlert else { return }

        let classifications = result.classifications.map {
            (identifier: $0.identifier, confidence: $0.confidence)
        }

        let alerts = filter.alerts(
            for: classifications,
            at: start + result.timeRange.start.seconds
        )

        for alert in alerts {
            onAlert(alert)
        }
    }
}

public enum SoundDetectorError: Error {
    case invalidFormat
}

private final class ResultsObserver: NSObject, SNResultsObserving {
    private let receive: (SNClassificationResult) -> Void

    init(receive: @escaping (SNClassificationResult) -> Void) {
        self.receive = receive
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else {
            return
        }

        receive(result)
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        print("Sound analysis failed: \(error)")
    }
}
