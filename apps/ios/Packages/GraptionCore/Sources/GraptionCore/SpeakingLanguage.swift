import Foundation

/// Languages Grok TTS can speak. Voice and language are independent:
/// any built-in voice can speak any code in `all`.
public struct SpeakingLanguage: Identifiable, Hashable, Sendable {
    public let code: String
    public let name: String

    public var id: String { code }

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }

    public static let all: [SpeakingLanguage] = [
        SpeakingLanguage(code: "en", name: "English"),
        SpeakingLanguage(code: "ar-EG", name: "Arabic (Egypt)"),
        SpeakingLanguage(code: "ar-SA", name: "Arabic (Saudi Arabia)"),
        SpeakingLanguage(code: "ar-AE", name: "Arabic (United Arab Emirates)"),
        SpeakingLanguage(code: "bn", name: "Bengali"),
        SpeakingLanguage(code: "zh", name: "Chinese (Simplified)"),
        SpeakingLanguage(code: "fr", name: "French"),
        SpeakingLanguage(code: "de", name: "German"),
        SpeakingLanguage(code: "hi", name: "Hindi"),
        SpeakingLanguage(code: "id", name: "Indonesian"),
        SpeakingLanguage(code: "it", name: "Italian"),
        SpeakingLanguage(code: "ja", name: "Japanese"),
        SpeakingLanguage(code: "ko", name: "Korean"),
        SpeakingLanguage(code: "pt-BR", name: "Portuguese (Brazil)"),
        SpeakingLanguage(code: "pt-PT", name: "Portuguese (Portugal)"),
        SpeakingLanguage(code: "ru", name: "Russian"),
        SpeakingLanguage(code: "es-MX", name: "Spanish (Mexico)"),
        SpeakingLanguage(code: "es-ES", name: "Spanish (Spain)"),
        SpeakingLanguage(code: "tr", name: "Turkish"),
        SpeakingLanguage(code: "vi", name: "Vietnamese"),
    ]

    public static func named(_ code: String) -> String {
        canonical(code).flatMap { known in all.first { $0.code == known }?.name } ?? code
    }

    /// Returns the canonical BCP-47 code, or nil when Grok TTS does not list it.
    public static func canonical(_ code: String) -> String? {
        let key = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.code.lowercased() == key }?.code
    }

    /// English and English match. Spanish (Mexico) and Spanish (Spain) match.
    /// English and Spanish do not, so the reply is translated first.
    public static func sameSpokenLanguage(_ source: String, _ target: String) -> Bool {
        guard let source = canonical(source), let target = canonical(target) else { return false }
        let sourcePrimary = source.split(separator: "-").first?.lowercased()
        let targetPrimary = target.split(separator: "-").first?.lowercased()
        return sourcePrimary != nil && sourcePrimary == targetPrimary
    }
}

public enum SpeakingReplyLimits {
    public static let maxCharacters = 500
}

public struct SpeakingVoiceChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum SpeakingVoice {
    public static let builtIn: [SpeakingVoiceChoice] = [
        SpeakingVoiceChoice(id: "eve", name: "Eve"),
        SpeakingVoiceChoice(id: "ara", name: "Ara"),
        SpeakingVoiceChoice(id: "leo", name: "Leo"),
        SpeakingVoiceChoice(id: "rex", name: "Rex"),
        SpeakingVoiceChoice(id: "sal", name: "Sal"),
    ]

    /// Built-in ids and xAI custom voice ids. The custom id is an identifier, not audio.
    public static func canonical(_ voiceID: String) -> String? {
        let cleaned = voiceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleaned.wholeMatch(of: /^[a-z0-9][a-z0-9_-]{0,63}$/) != nil else { return nil }
        return cleaned
    }
}
