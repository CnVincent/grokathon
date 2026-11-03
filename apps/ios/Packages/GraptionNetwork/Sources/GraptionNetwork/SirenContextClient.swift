import Foundation

/// Optional explanation for a siren or alarm banner.
///
/// The on-device alert is already on screen before this runs. A missing key,
/// a network failure, or an uncertain answer leaves that banner unchanged.
/// A wrong explanation is worse than none. The request is text only: label and place.
public protocol SirenContextClient: Sendable {
    var modelVersion: String { get }
    func explain(label: String) async -> String?
}

/// Banner copy for a confident official explanation.
public enum SirenContextCopy {
    public static func needsContext(_ label: String) -> Bool {
        label == "siren" || label == "alarm"
    }

    public static func title(for label: String) -> String {
        switch label {
        case "siren": "Siren"
        case "alarm": "Alarm"
        default: label
        }
    }

    /// `🚨 Siren: tornado warning for Fulton County, shelter now.`
    public static func bannerLine(label: String, reason: String) -> String? {
        guard let body = normalizedReason(reason, label: label) else { return nil }
        return "🚨 \(title(for: label)): \(body)."
    }

    /// Drops the answer when it belongs to an alert that is no longer on screen.
    public static func applying(
        alertID: UUID,
        currentID: UUID?,
        label: String,
        reason: String?
    ) -> String? {
        guard alertID == currentID, let reason else { return nil }
        return bannerLine(label: label, reason: reason)
    }

    static func normalizedReason(_ reason: String, label: String) -> String? {
        var text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("🚨") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let prefix = title(for: label) + ":"
        if text.lowercased().hasPrefix(prefix.lowercased()) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while text.hasSuffix(".") || text.hasSuffix("!") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return nil }
        let folded = text.lowercased()
        let refusal: Set<String> = ["none", "n/a", "na", "unknown", "unsure", "no", "nothing", "nope"]
        if refusal.contains(folded) { return nil }
        let hedges = [
            "no official", "not sure", "don't know", "do not know",
            "cannot determine", "can't tell", "unable to", "no active",
            "no clear", "no recent", "no post", "i searched", "as an ai",
            "maybe", "might", "possibly", "unclear", "could be"
        ]
        if hedges.contains(where: { folded.contains($0) }) { return nil }
        if text.contains(where: \.isNewline) { return nil }
        // Short enough for the banner, long enough to be an action.
        guard text.count >= 10, text.count <= 80 else { return nil }
        return text
    }
}

public struct SirenContextConfiguration: Sendable {
    public static let defaultModel = "grok-4.7"
    public static let defaultPlace = "Fulton County, near the Georgia Tech campus in Atlanta"
    /// Official accounts only. County warnings come from NWS Atlanta; campus alerts from GTPD.
    public static let defaultHandles = [
        "NWS", "NWSAtlanta", "NWSSPC", "GaTechPD", "GTPDalerts", "Atlanta_Police"
    ]

    public let apiKey: String
    public let endpoint: URL
    public let model: String
    public let place: String
    public let handles: [String]
    public let maxTurns: Int

    public init(
        apiKey: String,
        endpoint: URL = URL(string: "https://api.x.ai/v1/responses")!,
        model: String = defaultModel,
        place: String = defaultPlace,
        handles: [String] = defaultHandles,
        maxTurns: Int = 2
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
        let trimmedPlace = place.trimmingCharacters(in: .whitespacesAndNewlines)
        self.place = trimmedPlace.isEmpty ? Self.defaultPlace : trimmedPlace
        self.handles = Self.resolvedHandles(from: handles.joined(separator: ","))
        self.maxTurns = maxTurns
    }

    /// Empty key, or an unsubstituted build setting, disables the lookup.
    public static func fromAppConfiguration(bundle: Bundle = .main) -> SirenContextConfiguration? {
        guard
            let rawKey = bundle.object(forInfoDictionaryKey: "GraptionXAIKey") as? String
        else { return nil }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("$(") else { return nil }
        let place = bundle.object(forInfoDictionaryKey: "GraptionSirenPlace") as? String
        let handles = bundle.object(forInfoDictionaryKey: "GraptionSirenHandles") as? String
        let trimmedPlace = place?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return SirenContextConfiguration(
            apiKey: key,
            place: trimmedPlace.contains("$(") ? "" : trimmedPlace,
            handles: resolvedHandles(from: handles?.contains("$(") == true ? nil : handles)
        )
    }

    /// Strips `@`, drops blanks and duplicates, and keeps at most 20 handles (the x_search cap).
    public static func resolvedHandles(from raw: String?) -> [String] {
        let source = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = (source?.isEmpty == false ? source! : defaultHandles.joined(separator: ","))
            .split(separator: ",")
        var seen = Set<String>()
        var handles: [String] = []
        for part in parts {
            var handle = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if handle.hasPrefix("@") { handle.removeFirst() }
            guard handle.wholeMatch(of: /^[A-Za-z0-9_]{1,15}$/) != nil else { continue }
            guard seen.insert(handle.lowercased()).inserted else { continue }
            handles.append(handle)
            if handles.count == 20 { break }
        }
        return handles.isEmpty ? defaultHandles : handles
    }
}

/// Grok Responses API client. The only tool is `x_search`, limited to official handles.
public struct GrokSirenContextClient: SirenContextClient, Sendable {
    public let configuration: SirenContextConfiguration
    public var modelVersion: String { configuration.model }

    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        configuration: SirenContextConfiguration,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.session = session
        self.now = now
    }

    public static func fromAppConfiguration(
        bundle: Bundle = .main,
        session: URLSession = .shared
    ) -> GrokSirenContextClient? {
        guard let configuration = SirenContextConfiguration.fromAppConfiguration(bundle: bundle) else {
            return nil
        }
        return GrokSirenContextClient(configuration: configuration, session: session)
    }

    public func explain(label: String) async -> String? {
        guard SirenContextCopy.needsContext(label) else { return nil }
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = SirenContextAPI.body(
            label: label,
            place: configuration.place,
            handles: configuration.handles,
            model: configuration.model,
            maxTurns: configuration.maxTurns,
            now: now()
        )
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard (200...299).contains(http.statusCode) else {
                print("Siren context HTTP \(http.statusCode) model=\(configuration.model)")
                return nil
            }
            return SirenContextAPI.reason(from: data, label: label)
        } catch is CancellationError {
            return nil
        } catch let error as URLError where error.code == .cancelled {
            return nil
        } catch {
            print("Siren context failed model=\(configuration.model)")
            return nil
        }
    }
}

enum SirenContextAPI {
    private struct Body: Encodable {
        let model: String
        let input: [Message]
        let tools: [Tool]
        let maxTurns: Int

        enum CodingKeys: String, CodingKey {
            case model, input, tools
            case maxTurns = "max_turns"
        }
    }

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    private struct Tool: Encodable {
        let type = "x_search"
        let allowedXHandles: [String]
        let fromDate: String
        let toDate: String

        enum CodingKeys: String, CodingKey {
            case type
            case allowedXHandles = "allowed_x_handles"
            case fromDate = "from_date"
            case toDate = "to_date"
        }
    }

    static func body(
        label: String,
        place: String,
        handles: [String],
        model: String,
        maxTurns: Int,
        now: Date
    ) -> Data {
        let window = searchWindow(containing: now)
        let body = Body(
            model: model,
            input: [
                Message(
                    role: "system",
                    content: """
                    You explain a siren or alarm that a Deaf person just heard. \
                    Use x_search and trust only posts from the allowed official accounts. \
                    Reply with one short action line and no emoji, like: \
                    tornado warning for Fulton County, shelter now. \
                    If no official post clearly explains this sound right now, reply with exactly NONE. \
                    Never guess. A wrong warning is worse than none.
                    """
                ),
                Message(
                    role: "user",
                    content: "A \(label) was just detected in \(place). Why is it sounding, and what should they do right now?"
                )
            ],
            tools: [
                Tool(
                    allowedXHandles: handles,
                    fromDate: window.from,
                    toDate: window.to
                )
            ],
            maxTurns: maxTurns
        )
        return (try? JSONEncoder().encode(body)) ?? Data()
    }

    /// Inclusive start is 00:00 UTC yesterday. Exclusive end is 00:00 UTC tomorrow.
    /// That is the previous UTC day and the current one, which still covers a US evening
    /// after UTC has rolled to the next date.
    static func searchWindow(containing now: Date) -> (from: String, to: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        let to = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return (format(from), format(to))
    }

    /// Last assistant text in the Responses payload. Tool calls come first and are ignored.
    static func reason(from data: Data, label: String) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let error = json["error"], !(error is NSNull) { return nil }
        if let status = json["status"] as? String, status != "completed" { return nil }
        guard let text = lastText(in: json) else { return nil }
        return SirenContextCopy.normalizedReason(text, label: label)
    }

    private static func lastText(in json: [String: Any]) -> String? {
        var found: [String] = []
        if let direct = json["output_text"] as? String {
            found.append(direct)
        }
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

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
