import Foundation

/// One caption line sent to `POST /summary`.
public struct MissedCaptionLine: Codable, Equatable, Sendable {
    public var speaker: String
    public var text: String
    public var tone: String?
    public var tEnd: Double

    public init(speaker: String, text: String, tone: String? = nil, tEnd: Double) {
        self.speaker = speaker
        self.text = text
        self.tone = tone
        self.tEnd = tEnd
    }

    enum CodingKeys: String, CodingKey {
        case speaker
        case text
        case tone
        case tEnd = "t_end"
    }
}

public enum SummaryClientError: Error, Equatable, Sendable {
    case httpStatus(Int)
    case invalidResponse
}

/// Maps a tone-server URL (`ws`/`wss`/`http`/`https`) onto `POST /summary`.
public func summaryURL(from serverURL: URL) -> URL {
    var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) ?? URLComponents()
    switch components.scheme {
    case "ws":
        components.scheme = "http"
    case "wss":
        components.scheme = "https"
    default:
        break
    }
    components.path = "/summary"
    return components.url ?? serverURL
}

/// Session-scoped HTTP client for the optional "What did I miss?" summary.
/// Captions never wait on this type: callers treat failures as unavailable copy.
public struct SummaryClient: Sendable {
    private let summaryURL: URL
    private let urlSession: URLSession

    public init(summaryURL: URL, urlSession: URLSession = .shared) {
        self.summaryURL = summaryURL
        self.urlSession = urlSession
    }

    public func summarize(_ lines: [MissedCaptionLine], token: String?) async throws -> String {
        var request = URLRequest(url: summaryURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(SummaryRequest(lines: lines))

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SummaryClientError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw SummaryClientError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(SummaryResponse.self, from: data).summary
    }
}

private struct SummaryRequest: Encodable, Sendable {
    let lines: [MissedCaptionLine]
}

private struct SummaryResponse: Decodable, Sendable {
    let summary: String
}
