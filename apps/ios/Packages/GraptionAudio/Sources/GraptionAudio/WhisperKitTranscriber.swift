import Foundation
import WhisperKit

public protocol CaptionTranscriber: Sendable {
    func prepare(allowDownload: Bool) async throws
    func transcribe(_ segment: AudioSegment) async throws -> TranscriptionResult
}

/// The pipeline is the sole caller, serializing preparation and inference.
public actor WhisperKitTranscriber: CaptionTranscriber {
    private var model: WhisperKit?
    private let folderKey = "graption.whisperkit.base.en.folder"

    public init() {}

    public func prepare(allowDownload: Bool = false) async throws {
        guard model == nil else { return }
        var folder = UserDefaults.standard.string(forKey: folderKey)
        if let existing = folder, !FileManager.default.fileExists(atPath: existing) {
            folder = nil
        }
        if folder == nil {
            guard allowDownload else { throw TranscriberError.modelNotProvisioned }
            // Model assets stay in the device's cache, never in the repository.
            let downloaded = try await WhisperKit.download(variant: "openai_whisper-base.en")
            folder = downloaded.path
            UserDefaults.standard.set(folder, forKey: folderKey)
        }
        // WhisperKit also needs a local tokenizer, not only the Core ML files.
        let tokenizerBase = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface")
        if !allowDownload {
            let tokenizer = tokenizerBase.appendingPathComponent("models/openai/whisper-base.en")
            for filename in ["tokenizer.json", "tokenizer_config.json"] {
                let data = try? Data(contentsOf: tokenizer.appendingPathComponent(filename))
                guard let data, (try? JSONSerialization.jsonObject(with: data)) != nil else {
                    throw TranscriberError.modelNotProvisioned
                }
            }
        }
        let loaded = try await WhisperKit(WhisperKitConfig(
            modelFolder: folder, tokenizerFolder: tokenizerBase, verbose: false, prewarm: true,
            load: true, download: false
        ))
        model = loaded
    }

    public func transcribe(_ segment: AudioSegment) async throws -> TranscriptionResult {
        guard let model else { throw TranscriberError.modelNotReady }
        let options = DecodingOptions(language: "en", skipSpecialTokens: true,
                                      wordTimestamps: true, concurrentWorkerCount: 1)
        // filter selects WhisperKit's array-returning overload, not its legacy optional overload.
        let results = try await model.transcribe(
            audioArray: segment.samples, decodeOptions: options
        ).filter { _ in true }
        let words = results.flatMap { $0.segments }.flatMap { $0.words ?? [] }.map {
            TranscriptionResult.Word(
                text: $0.word,
                tStart: segment.tStart + Double($0.start),
                tEnd: segment.tStart + Double($0.end)
            )
        }
        return TranscriptionResult(
            captionID: segment.captionID,
            text: results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            tStart: segment.tStart, tEnd: segment.tEnd, words: words,
            asrModelVersion: "whisperkit-0.9.4-base.en"
        )
    }
}

public enum TranscriberError: LocalizedError {
    case modelNotProvisioned, modelNotReady

    public var errorDescription: String? {
        switch self {
        case .modelNotProvisioned: return "Set up base.en online before starting offline captions."
        case .modelNotReady: return "The transcription model is not ready."
        }
    }
}
