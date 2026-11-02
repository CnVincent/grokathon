import Foundation
import GraptionCore

/// Configuration for one app-session connection to the tone server.
public struct ToneClientConfiguration: Sendable {
    public let serverURL: URL
    public let sessionID: String
    public let token: String?

    public init(serverURL: URL, sessionID: String, token: String? = nil) {
        self.serverURL = serverURL
        self.sessionID = sessionID
        self.token = token?.isEmpty == true ? nil : token
    }

    /// Reads values injected by the app target's xcconfig files. Returns nil when tone is disabled.
    public static func fromAppConfiguration(
        bundle: Bundle = .main,
        sessionID: String
    ) -> ToneClientConfiguration? {
        guard
            let value = bundle.object(forInfoDictionaryKey: "GraptionToneURL") as? String,
            let url = URL(string: value),
            !value.isEmpty
        else {
            return nil
        }
        let token = bundle.object(forInfoDictionaryKey: "GraptionToneToken") as? String
        return ToneClientConfiguration(serverURL: url, sessionID: sessionID, token: token)
    }

    public func sessionURL() throws -> URL {
        guard serverURL.scheme == "ws" || serverURL.scheme == "wss" else {
            throw ToneClientError.invalidServerURL
        }
        guard !sessionID.isEmpty else { throw ToneClientError.emptySessionID }
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            throw ToneClientError.invalidServerURL
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([basePath, "ws/session"].filter { !$0.isEmpty }.joined(separator: "/"))
        var allowedCharacters = CharacterSet.urlQueryAllowed
        allowedCharacters.remove(charactersIn: "+&=")
        guard let encodedSessionID = sessionID.addingPercentEncoding(
            withAllowedCharacters: allowedCharacters
        ) else {
            throw ToneClientError.invalidServerURL
        }
        components.percentEncodedQuery = "session_id=\(encodedSessionID)"
        guard let url = components.url else { throw ToneClientError.invalidServerURL }
        return url
    }
}

public enum ToneClientError: Error, Equatable, Sendable {
    case invalidServerURL
    case emptySessionID
    case notConnected
    case unexpectedMessage
}

public enum ToneServerEvent: Sendable {
    case toneResult(Events)
    case sessionError(Events)
}

/// A small, session-scoped client for the P2 FastAPI endpoint.
/// Captions never wait on this actor: callers treat failures as unavailable tone and retry later.
public actor ToneClient {
    public static let reconnectDelay: Duration = .seconds(5)

    private let configuration: ToneClientConfiguration
    private let urlSession: URLSession
    private var socket: URLSessionWebSocketTask?

    public init(configuration: ToneClientConfiguration, urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.urlSession = urlSession
    }

    public func connect() throws {
        guard socket == nil else { return }
        var request = URLRequest(url: try configuration.sessionURL())
        if let token = configuration.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let task = urlSession.webSocketTask(with: request)
        task.resume()
        socket = task
    }

    public func disconnect() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    /// Verifies that an idle socket is still live without sending user audio.
    public func ping() async throws {
        guard let socket else { throw ToneClientError.notConnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Sends one VAD segment as the schema-v1.2 tone_request text frame expected by P2.
    public func sendToneRequest(
        captionID: String,
        tStart: Double,
        tEnd: Double,
        sampleRate: Int,
        pcm16: Data
    ) async throws {
        if socket == nil { try connect() }
        let event = Events(
            schemaVersion: .the12,
            sessionID: configuration.sessionID,
            type: .toneRequest,
            captionID: captionID,
            tEnd: tEnd,
            tStart: tStart,
            audioB64: pcm16.base64EncodedString(),
            sampleRate: sampleRate
        )
        let data = try JSONEncoder().encode(event)
        guard let text = String(data: data, encoding: .utf8), let socket else {
            throw ToneClientError.notConnected
        }
        do {
            try await socket.send(.string(text))
        } catch {
            self.socket = nil
            throw error
        }
    }

    /// Receives the next result or recoverable server error. Other event types are rejected.
    public func receiveNext() async throws -> ToneServerEvent {
        guard let socket else { throw ToneClientError.notConnected }
        do {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let binaryData): data = binaryData
            @unknown default: throw ToneClientError.unexpectedMessage
            }
            let event = try JSONDecoder().decode(Events.self, from: data)
            switch event.type {
            case .toneResult: return .toneResult(event)
            case .sessionError: return .sessionError(event)
            default: throw ToneClientError.unexpectedMessage
            }
        } catch {
            self.socket = nil
            throw error
        }
    }

    /// Waits five seconds and establishes a fresh session socket after a failed receive/send.
    public func reconnect() async throws {
        disconnect()
        try await Task.sleep(for: Self.reconnectDelay)
        try connect()
    }
}
