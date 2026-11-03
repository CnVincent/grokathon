import Foundation

/// Configuration for one app-session connection to the optional online STT socket.
public struct GrokSTTConfiguration: Sendable {
    public let serverURL: URL
    public let sessionID: String
    public let token: String?

    public init(serverURL: URL, sessionID: String, token: String? = nil) {
        self.serverURL = serverURL
        self.sessionID = sessionID
        self.token = token?.isEmpty == true ? nil : token
    }

    public init(_ configuration: ToneClientConfiguration) {
        self.init(
            serverURL: configuration.serverURL,
            sessionID: configuration.sessionID,
            token: configuration.token
        )
    }

    public func sessionURL() throws -> URL {
        guard serverURL.scheme == "ws" || serverURL.scheme == "wss" else {
            throw GrokSTTClientError.invalidServerURL
        }
        guard !sessionID.isEmpty else { throw GrokSTTClientError.emptySessionID }
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            throw GrokSTTClientError.invalidServerURL
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([basePath, "ws/stt"].filter { !$0.isEmpty }.joined(separator: "/"))
        var allowedCharacters = CharacterSet.urlQueryAllowed
        allowedCharacters.remove(charactersIn: "+&=")
        guard let encodedSessionID = sessionID.addingPercentEncoding(
            withAllowedCharacters: allowedCharacters
        ) else {
            throw GrokSTTClientError.invalidServerURL
        }
        components.percentEncodedQuery = "session_id=\(encodedSessionID)"
        guard let url = components.url else { throw GrokSTTClientError.invalidServerURL }
        return url
    }
}

public enum GrokSTTClientError: Error, Equatable, Sendable {
    case invalidServerURL
    case emptySessionID
    case notConnected
}

/// Incoming STT messages. Unknown JSON becomes `.error` with code `unexpected_message`.
public enum GrokSTTEvent: Sendable, Equatable {
    case ready(modelVersion: String)
    case partial(text: String, language: String?, isFinal: Bool, speechFinal: Bool, speaker: Int?)
    case done(text: String, language: String?, duration: Double?, speaker: Int?)
    case error(code: String, message: String)
    case disconnected

    public static func parse(_ data: Data) -> GrokSTTEvent {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else {
            return .error(code: "unexpected_message", message: "Invalid JSON")
        }

        switch type {
        case "stt.ready":
            return .ready(modelVersion: stringValue(object["model_version"]) ?? "")
        case "stt.partial":
            return .partial(
                text: stringValue(object["text"]) ?? "",
                language: stringValue(object["language"]),
                isFinal: boolValue(object["is_final"]),
                speechFinal: boolValue(object["speech_final"]),
                speaker: firstSpeaker(in: object["words"])
            )
        case "stt.done":
            return .done(
                text: stringValue(object["text"]) ?? "",
                language: stringValue(object["language"]),
                duration: doubleValue(object["duration"]),
                speaker: firstSpeaker(in: object["words"])
            )
        case "stt.error":
            return .error(
                code: stringValue(object["code"]) ?? "unexpected_message",
                message: stringValue(object["message"]) ?? ""
            )
        default:
            return .error(code: "unexpected_message", message: "Unknown type \(type)")
        }
    }

    /// Caption speaker is the first word that carries a diarization label.
    private static func firstSpeaker(in wordsValue: Any?) -> Int? {
        guard let words = wordsValue as? [[String: Any]] else { return nil }
        for word in words {
            if let speaker = intValue(word["speaker"]) {
                return speaker
            }
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if value is NSNull { return nil }
        return value as? String
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }
}

/// Session-scoped client for the optional Grok STT WebSocket.
///
/// `connect()` may throw. After that, socket failures are delivered as `.error` or
/// `.disconnected` so the caption pipeline can fall back to WhisperKit. PCM frames
/// are never logged.
public actor GrokSTTClient {
    public nonisolated let events: AsyncStream<GrokSTTEvent>

    private let configuration: GrokSTTConfiguration
    private let urlSession: URLSession
    private let continuation: AsyncStream<GrokSTTEvent>.Continuation
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var didDisconnect = false

    public init(configuration: GrokSTTConfiguration, urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.urlSession = urlSession
        let (stream, continuation) = AsyncStream.makeStream(of: GrokSTTEvent.self)
        self.events = stream
        self.continuation = continuation
    }

    public func connect() async throws {
        guard socket == nil else { return }
        didDisconnect = false
        var request = URLRequest(url: try configuration.sessionURL())
        if let token = configuration.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let task = urlSession.webSocketTask(with: request)
        task.resume()
        socket = task
        do {
            try await sendText(Self.startMessage)
        } catch {
            socket = nil
            task.cancel(with: .goingAway, reason: nil)
            throw error
        }
        startReceiving()
    }

    public func sendPCM(_ data: Data) async {
        guard !data.isEmpty, let socket else { return }
        do {
            try await socket.send(.data(data))
        } catch {
            self.socket = nil
            continuation.yield(.error(code: "send_failed", message: error.localizedDescription))
            emitDisconnected()
        }
    }

    public func finish() async {
        guard socket != nil else { return }
        do {
            try await sendText(#"{"type":"audio.done"}"#)
        } catch {
            continuation.yield(.error(code: "send_failed", message: error.localizedDescription))
        }
    }

    public func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        emitDisconnected()
    }

    private static let startMessage = #"{"type":"stt.start","sample_rate":16000,"keyterms":["Graption"]}"#

    private func sendText(_ text: String) async throws {
        guard let socket else { throw GrokSTTClientError.notConnected }
        try await socket.send(.string(text))
    }

    private func startReceiving() {
        receiveTask?.cancel()
        receiveTask = Task { await receiveLoop() }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let socket else { break }
            do {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .string(let text):
                    data = Data(text.utf8)
                case .data(let binaryData):
                    data = binaryData
                @unknown default:
                    continuation.yield(
                        .error(code: "unexpected_message", message: "Unsupported WebSocket message")
                    )
                    continue
                }
                continuation.yield(GrokSTTEvent.parse(data))
            } catch is CancellationError {
                break
            } catch {
                self.socket = nil
                emitDisconnected()
                break
            }
        }
    }

    private func emitDisconnected() {
        guard !didDisconnect else { return }
        didDisconnect = true
        continuation.yield(.disconnected)
        continuation.finish()
    }
}
