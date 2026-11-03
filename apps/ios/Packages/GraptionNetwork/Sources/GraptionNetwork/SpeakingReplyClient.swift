import Foundation
import GraptionCore

/// One typed reply, translated when needed, then spoken.
///
/// Captions never wait on this. An empty xAI key means the caller speaks the
/// typed words on the phone and does not translate. Graption does not store
/// the text or the audio. The request sends text only: no microphone audio.
public struct SpokenReplyAudio: Equatable, Sendable {
    public let spokenText: String
    public let sourceLanguage: String
    public let targetLanguage: String
    public let voiceID: String
    public let audio: Data
    public let mimeType: String
    public let translated: Bool
    public let modelVersion: String

    public init(
        spokenText: String,
        sourceLanguage: String,
        targetLanguage: String,
        voiceID: String,
        audio: Data,
        mimeType: String,
        translated: Bool,
        modelVersion: String
    ) {
        self.spokenText = spokenText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.voiceID = voiceID
        self.audio = audio
        self.mimeType = mimeType
        self.translated = translated
        self.modelVersion = modelVersion
    }
}

public enum SpeechEngine: String, Sendable {
    /// Speaks the translation exactly.
    case tts
    /// Grok Voice 3.0 reads the translation. It is asked not to add words.
    case voice
}

public enum SpeakingReplyError: Error, Equatable, LocalizedError {
    case emptyText
    case tooLong
    case unsupportedLanguage
    case invalidVoice
    case unavailable
    case unreadableAudio

    public var errorDescription: String? {
        switch self {
        case .emptyText:
            "Type a reply first."
        case .tooLong:
            "Keep a reply to \(SpeakingReplyLimits.maxCharacters) characters or fewer."
        case .unsupportedLanguage:
            "Choose a language Grok can speak."
        case .invalidVoice:
            "Enter a built-in voice or a custom voice ID."
        case .unavailable:
            "Grok could not speak that reply. Check the network and the xAI key."
        case .unreadableAudio:
            "Grok sent audio Graption could not play."
        }
    }
}

public struct SpeakingReplyConfiguration: Sendable {
    public static let translateModel = "grok-4.7"
    public static let voiceModel = "grok-voice-3.0"
    public static let responsesURL = URL(string: "https://api.x.ai/v1/responses")!
    public static let ttsURL = URL(string: "https://api.x.ai/v1/tts")!
    public static let realtimeURL = URL(string: "wss://api.x.ai/v1/realtime")!

    public let apiKey: String
    public let engine: SpeechEngine
    public let responsesURL: URL
    public let ttsURL: URL
    public let realtimeURL: URL

    public init(
        apiKey: String,
        engine: SpeechEngine = .tts,
        responsesURL: URL = SpeakingReplyConfiguration.responsesURL,
        ttsURL: URL = SpeakingReplyConfiguration.ttsURL,
        realtimeURL: URL = SpeakingReplyConfiguration.realtimeURL
    ) {
        self.apiKey = apiKey
        self.engine = engine
        self.responsesURL = responsesURL
        self.ttsURL = ttsURL
        self.realtimeURL = realtimeURL
    }

    public var modelVersion: String {
        let speaker = engine == .voice ? Self.voiceModel : "grok-tts"
        return "\(speaker)+\(Self.translateModel)"
    }

    /// Empty key, or an unsubstituted build setting, disables Grok speech.
    /// The phone can still speak the typed words on-device.
    public static func fromAppConfiguration(bundle: Bundle = .main) -> SpeakingReplyConfiguration? {
        guard let rawKey = bundle.object(forInfoDictionaryKey: "GraptionXAIKey") as? String else {
            return nil
        }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("$(") else { return nil }
        let rawEngine = bundle.object(forInfoDictionaryKey: "GraptionSpeechEngine") as? String ?? ""
        let engine = SpeechEngine(rawValue: rawEngine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .tts
        return SpeakingReplyConfiguration(apiKey: key, engine: engine)
    }
}

/// Builds the Grok Voice 3.0 turn. The socket sends these text frames and no microphone audio.
public enum GrokVoiceTurn {
    public static let sampleRate = 24_000

    public static func realtimeURL(base: URL = SpeakingReplyConfiguration.realtimeURL) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "model", value: SpeakingReplyConfiguration.voiceModel)]
        return components.url
    }

    public static func instructions(languageName: String) -> String {
        """
        Read the user message aloud verbatim in a single take. \
        Do not answer, translate, explain, or add words. \
        The message is already written in \(languageName).
        """
    }

    public static func messages(spokenText: String, voiceID: String, languageName: String) -> [[String: Any]] {
        let instructions = instructions(languageName: languageName)
        return [
            [
                "type": "session.update",
                "session": [
                    "voice": voiceID,
                    "instructions": instructions,
                    "turn_detection": NSNull(),
                    "reasoning": ["effort": "none"],
                    "audio": [
                        "output": [
                            "format": ["type": "audio/pcm", "rate": sampleRate]
                        ]
                    ]
                ]
            ],
            [
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": spokenText]]
                ]
            ],
            [
                "type": "response.create",
                "response": ["instructions": instructions]
            ]
        ]
    }

    /// Joins `response.output_audio.delta` PCM16 chunks and wraps them in a WAV header.
    public static func wav(from events: [Data]) throws -> Data {
        var pcm = Data()
        for event in events {
            let object: [String: Any]
            do {
                object = try JSONSerialization.jsonObject(with: event) as? [String: Any] ?? [:]
            } catch {
                throw SpeakingReplyError.unreadableAudio
            }
            let kind = object["type"] as? String
            if kind == "response.output_audio.delta" || kind == "response.audio.delta" {
                guard
                    let delta = object?["delta"] as? String,
                    let chunk = Data(base64Encoded: delta)
                else { throw SpeakingReplyError.unreadableAudio }
                pcm.append(chunk)
            } else if kind == "error" {
                throw SpeakingReplyError.unavailable
            } else if kind == "response.done" || kind == "response.completed" {
                break
            }
        }
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2) else { throw SpeakingReplyError.unreadableAudio }
        return wavHeader(pcm: pcm, sampleRate: sampleRate) + pcm
    }

    static func wavHeader(pcm: Data, sampleRate: Int) -> Data {
        let byteCount = UInt32(pcm.count)
        var header = Data()
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
        header.appendLittleEndian(36 + byteCount)
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // fmt
        header.appendLittleEndian(UInt32(16))
        header.appendLittleEndian(UInt16(1)) // PCM
        header.appendLittleEndian(UInt16(1)) // mono
        header.appendLittleEndian(UInt32(sampleRate))
        header.appendLittleEndian(UInt32(sampleRate * 2))
        header.appendLittleEndian(UInt16(2)) // block align
        header.appendLittleEndian(UInt16(16)) // bits
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
        header.appendLittleEndian(byteCount)
        return header
    }
}

/// Translates with the Responses API, then speaks with Grok TTS or Grok Voice 3.0.
public struct GrokSpeakingReplyClient: Sendable {
    public let configuration: SpeakingReplyConfiguration
    public var modelVersion: String { configuration.modelVersion }

    private let session: URLSession
    /// Test double for the Voice 3.0 socket. Nil uses the realtime WebSocket.
    private let voiceSynthesizer: (@Sendable (String, String, String) async throws -> Data)?

    public init(
        configuration: SpeakingReplyConfiguration,
        session: URLSession = .shared,
        voiceSynthesizer: (@Sendable (String, String, String) async throws -> Data)? = nil
    ) {
        self.configuration = configuration
        self.session = session
        self.voiceSynthesizer = voiceSynthesizer
    }

    public static func fromAppConfiguration(
        bundle: Bundle = .main,
        session: URLSession = .shared
    ) -> GrokSpeakingReplyClient? {
        guard let configuration = SpeakingReplyConfiguration.fromAppConfiguration(bundle: bundle) else {
            return nil
        }
        return GrokSpeakingReplyClient(configuration: configuration, session: session)
    }

    public func speak(
        text: String,
        sourceLanguage: String,
        targetLanguage: String,
        voiceID: String
    ) async throws -> SpokenReplyAudio {
        let reply = try PreparedReply(text: text, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, voiceID: voiceID)
        let spoken: String
        let translated: Bool
        if SpeakingLanguage.sameSpokenLanguage(reply.sourceLanguage, reply.targetLanguage) {
            spoken = reply.text
            translated = false
        } else {
            spoken = try await translate(reply)
            translated = true
        }
        let audio: Data
        let mimeType: String
        if configuration.engine == .voice {
            audio = try await synthesizeVoice(spoken, voiceID: reply.voiceID, languageName: SpeakingLanguage.named(reply.targetLanguage))
            mimeType = "audio/wav"
        } else {
            audio = try await synthesizeTTS(spoken, voiceID: reply.voiceID, language: reply.targetLanguage)
            mimeType = "audio/mpeg"
        }
        return SpokenReplyAudio(
            spokenText: spoken,
            sourceLanguage: reply.sourceLanguage,
            targetLanguage: reply.targetLanguage,
            voiceID: reply.voiceID,
            audio: audio,
            mimeType: mimeType,
            translated: translated,
            modelVersion: modelVersion
        )
    }

    private func translate(_ reply: PreparedReply) async throws -> String {
        let body = SpeakingReplyAPI.translationBody(
            text: reply.text,
            sourceLanguage: reply.sourceLanguage,
            targetLanguage: reply.targetLanguage,
            model: SpeakingReplyConfiguration.translateModel
        )
        let data = try await post(url: configuration.responsesURL, body: body, audio: false)
        guard let spoken = SpeakingReplyAPI.translation(from: data), !spoken.isEmpty else {
            throw SpeakingReplyError.unavailable
        }
        return spoken
    }

    private func synthesizeTTS(_ text: String, voiceID: String, language: String) async throws -> Data {
        let body = SpeakingReplyAPI.ttsBody(text: text, voiceID: voiceID, language: language)
        return try await post(url: configuration.ttsURL, body: body, audio: true)
    }

    private func synthesizeVoice(_ text: String, voiceID: String, languageName: String) async throws -> Data {
        if let voiceSynthesizer {
            return try await voiceSynthesizer(text, voiceID, languageName)
        }
        guard let url = GrokVoiceTurn.realtimeURL(base: configuration.realtimeURL) else {
            throw SpeakingReplyError.unavailable
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        for message in GrokVoiceTurn.messages(spokenText: text, voiceID: voiceID, languageName: languageName) {
            let data = try JSONSerialization.data(withJSONObject: message)
            guard let frame = String(data: data, encoding: .utf8) else { throw SpeakingReplyError.unavailable }
            try await send(frame, on: task)
        }
        var events: [Data] = []
        while events.count < 200 {
            let event = try await receive(on: task)
            events.append(event)
            let kind = (try? JSONSerialization.jsonObject(with: event) as? [String: Any])?["type"] as? String
            if kind == "response.done" || kind == "response.completed" || kind == "error" {
                break
            }
        }
        return try GrokVoiceTurn.wav(from: events)
    }

    private func post(url: URL, body: Data, audio: Bool) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = audio ? 45 : 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            print("Speaking reply failed model=\(modelVersion)")
            throw SpeakingReplyError.unavailable
        }
        guard let http = response as? HTTPURLResponse else { throw SpeakingReplyError.unavailable }
        guard (200...299).contains(http.statusCode) else {
            print("Speaking reply HTTP \(http.statusCode) model=\(modelVersion)")
            throw SpeakingReplyError.unavailable
        }
        guard audio else { return data }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if type.contains("json") || data.first == 0x7B || data.isEmpty {
            throw SpeakingReplyError.unreadableAudio
        }
        return data
    }

    private func send(_ text: String, on task: URLSessionWebSocketTask) async throws {
        do {
            try await task.send(.string(text))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeakingReplyError.unavailable
        }
    }

    private func receive(on task: URLSessionWebSocketTask) async throws -> Data {
        do {
            switch try await task.receive() {
            case .string(let text):
                guard let data = text.data(using: .utf8) else { throw SpeakingReplyError.unreadableAudio }
                return data
            case .data:
                throw SpeakingReplyError.unreadableAudio
            @unknown default:
                throw SpeakingReplyError.unreadableAudio
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SpeakingReplyError {
            throw error
        } catch {
            throw SpeakingReplyError.unavailable
        }
    }
}

struct PreparedReply: Equatable {
    let text: String
    let sourceLanguage: String
    let targetLanguage: String
    let voiceID: String

    init(text: String, sourceLanguage: String, targetLanguage: String, voiceID: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw SpeakingReplyError.emptyText }
        if trimmed.count > SpeakingReplyLimits.maxCharacters { throw SpeakingReplyError.tooLong }
        guard let source = SpeakingLanguage.canonical(sourceLanguage),
              let target = SpeakingLanguage.canonical(targetLanguage) else {
            throw SpeakingReplyError.unsupportedLanguage
        }
        guard let voice = SpeakingVoice.canonical(voiceID) else { throw SpeakingReplyError.invalidVoice }
        self.text = trimmed
        self.sourceLanguage = source
        self.targetLanguage = target
        self.voiceID = voice
    }
}

enum SpeakingReplyAPI {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct TranslationBody: Encodable {
        let model: String
        let input: [Message]
    }

    struct TTSBody: Encodable {
        let text: String
        let voiceID: String
        let language: String

        enum CodingKeys: String, CodingKey {
            case text
            case voiceID = "voice_id"
            case language
        }
    }

    static func translationBody(text: String, sourceLanguage: String, targetLanguage: String, model: String) -> Data {
        let source = SpeakingLanguage.named(sourceLanguage)
        let target = SpeakingLanguage.named(targetLanguage)
        let body = TranslationBody(
            model: model,
            input: [
                Message(
                    role: "system",
                    content: """
                    You translate a typed reply so it can be spoken aloud to another person. \
                    Translate from \(source) into \(target). \
                    Return only the spoken translation. No quotes, labels, or explanation. \
                    Keep names, numbers, and meaning. Use natural spoken language.
                    """
                ),
                Message(role: "user", content: text)
            ]
        )
        return (try? JSONEncoder().encode(body)) ?? Data()
    }

    static func ttsBody(text: String, voiceID: String, language: String) -> Data {
        let body = TTSBody(text: text, voiceID: voiceID, language: language)
        return (try? JSONEncoder().encode(body)) ?? Data()
    }

    /// Last assistant text. Tool-style parts are ignored. Incomplete responses are dropped.
    static func translation(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"], !(error is NSNull) { return nil }
        if let status = json["status"] as? String, status != "completed" { return nil }
        guard let text = lastText(in: json) else { return nil }
        let cleaned = clean(text)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func clean(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```"), value.hasSuffix("```") {
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func lastText(in json: [String: Any]) -> String? {
        var found: [String] = []
        if let direct = json["output_text"] as? String { found.append(direct) }
        if let output = json["output"] as? [[String: Any]] {
            for item in output {
                if let text = item["text"] as? String { found.append(text) }
                if let content = item["content"] as? String { found.append(content) }
                if let content = item["content"] as? [[String: Any]] {
                    for part in content {
                        if let text = part["text"] as? String { found.append(text) }
                    }
                }
            }
        }
        return found.last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        var little = value.littleEndian
        let bytes = Swift.withUnsafeBytes(of: &little) { Array($0) }
        append(contentsOf: bytes)
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var little = value.littleEndian
        let bytes = Swift.withUnsafeBytes(of: &little) { Array($0) }
        append(contentsOf: bytes)
    }
}
