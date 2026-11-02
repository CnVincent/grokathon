import Foundation

/// Main-actor queue ownership keeps microphone callbacks and UI delivery simple.
/// Awaiting the transcriber yields the main actor while model work runs elsewhere.
@MainActor
public final class CaptionPipeline {
    public struct Delivery {
        public let result: TranscriptionResult
        public let transcriptionSeconds: TimeInterval
        public let receivedAt: ContinuousClock.Instant
    }

    public private(set) var isReady = false
    public private(set) var isPreparing = false
    public var onResult: ((Delivery) -> Void)?
    public var onError: ((UUID?, Error) -> Void)?

    private let transcriber: any CaptionTranscriber
    private let maxPendingSegments: Int
    private var pending: [(AudioSegment, ContinuousClock.Instant)] = []
    private var isProcessing = false
    private var generation = 0

    public init(transcriber: any CaptionTranscriber = WhisperKitTranscriber(),
                maxPendingSegments: Int = 8) {
        precondition(maxPendingSegments > 0)
        self.transcriber = transcriber
        self.maxPendingSegments = maxPendingSegments
    }

    public func prepare(allowDownload: Bool = false) async throws {
        guard !isReady, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        try await transcriber.prepare(allowDownload: allowDownload)
        isReady = true
    }

    public func enqueue(_ segment: AudioSegment) {
        guard isReady else {
            onError?(segment.captionID, TranscriberError.modelNotReady)
            return
        }
        guard pending.count < maxPendingSegments else {
            onError?(segment.captionID, PipelineError.queueFull)
            return
        }
        pending.append((segment, ContinuousClock.now))
        guard !isProcessing else { return }
        isProcessing = true
        Task { await drain() }
    }

    /// Discard queued work and suppress an old session's in-flight result.
    public func reset() {
        generation += 1
        pending.removeAll()
    }

    private func drain() async {
        defer { isProcessing = false }
        while !pending.isEmpty {
            let (segment, receivedAt) = pending.removeFirst()
            let session = generation
            let started = ContinuousClock.now
            do {
                let result = try await transcriber.transcribe(segment)
                guard session == generation else { continue }
                onResult?(Delivery(result: result,
                                   transcriptionSeconds: Self.seconds(started.duration(to: .now)),
                                   receivedAt: receivedAt))
            } catch {
                guard session == generation else { continue }
                onError?(segment.captionID, error)
            }
        }
    }

    public static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

public enum PipelineError: LocalizedError {
    case queueFull
    public var errorDescription: String? {
        "Caption queue is full; this segment was dropped."
    }
}
