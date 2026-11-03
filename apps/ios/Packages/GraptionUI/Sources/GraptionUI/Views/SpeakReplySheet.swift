import GraptionCore
import SwiftUI

public struct SpeakReplyDraft: Equatable, Sendable {
    public var text: String
    public var sourceLanguage: String
    public var targetLanguage: String
    public var voiceID: String

    public init(text: String, sourceLanguage: String, targetLanguage: String, voiceID: String) {
        self.text = text
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.voiceID = voiceID
    }
}

public struct SpokenReply: Equatable, Sendable {
    public var spokenText: String
    public var translated: Bool
    public var modelVersion: String
    /// True when the phone played audio Grok produced, rather than the on-device voice.
    public var usedServerAudio: Bool

    public init(spokenText: String, translated: Bool, modelVersion: String, usedServerAudio: Bool) {
        self.spokenText = spokenText
        self.translated = translated
        self.modelVersion = modelVersion
        self.usedServerAudio = usedServerAudio
    }
}

public enum SpeakReplyStatus {
    public static func text(source: String, target: String, reply: SpokenReply) -> String {
        if reply.translated && reply.usedServerAudio {
            return "Spoke the translation."
        }
        if reply.translated {
            return "Spoke the translation on this iPhone."
        }
        if SpeakingLanguage.sameSpokenLanguage(source, target) {
            return reply.usedServerAudio ? "Spoke your reply." : "Spoke your reply on this iPhone."
        }
        return "Spoke your words as typed. Add the xAI key to speak a translation."
    }
}

/// Type a reply in one language and hear it in another.
public struct SpeakReplySheet: View {
    @Environment(\.dismiss) private var dismiss

    private let speak: (SpeakReplyDraft) async throws -> SpokenReply

    @AppStorage("speakSourceLanguage") private var sourceCode = "en"
    @AppStorage("speakTargetLanguage") private var targetCode = "es-MX"
    @AppStorage("speakVoiceID") private var voiceID = "eve"
    @State private var text = ""
    @State private var customVoice = ""
    @State private var spokenText: String?
    @State private var status: String?
    @State private var isSpeaking = false
    @FocusState private var isTextFocused: Bool

    public init(speak: @escaping (SpeakReplyDraft) async throws -> SpokenReply) {
        self.speak = speak
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    replyCard
                    languageCard
                    voiceCard
                    if let spokenText {
                        resultCard(spokenText)
                    }
                }
                .padding(16)
            }
        }
        .background(Color.graptionBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if SpeakingLanguage.canonical(sourceCode) == nil { sourceCode = "en" }
            if SpeakingLanguage.canonical(targetCode) == nil { targetCode = "es-MX" }
            if SpeakingVoice.builtIn.contains(where: { $0.id == voiceID }) == false, voiceID != "eve" {
                customVoice = voiceID
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            CircleIconButton(systemName: "chevron.left", accessibilityLabel: "Back to live captions") {
                dismiss()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Speak a reply")
                    .font(.headline.bold())
                    .foregroundStyle(Color.graptionAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("Type in your language. Graption speaks it in theirs.")
                    .font(.footnote)
                    .foregroundStyle(Color.graptionSecondaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.graptionBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.graptionAccent).frame(height: 1)
        }
    }

    private var replyCard: some View {
        SettingsCard {
            Text("Your reply")
                .font(.title3.bold())
                .foregroundStyle(Color.graptionAccent)
            TextField("Type what you want to say", text: $text, axis: .vertical)
                .lineLimit(3...6)
                .focused($isTextFocused)
                .foregroundStyle(.white)
                .font(.body)
                .padding(12)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.graptionAccent, lineWidth: 1))
                .accessibilityLabel("Reply to speak")
            HStack {
                Text("\(text.count)/\(SpeakingReplyLimits.maxCharacters)")
                    .font(.caption)
                    .foregroundStyle(text.count > SpeakingReplyLimits.maxCharacters ? Color.graptionAccent : Color.graptionSecondaryText)
                Spacer()
            }
            Button(action: submit) {
                Text(isSpeaking ? "Speaking…" : "Speak")
                    .font(.body.bold())
                    .foregroundStyle(Color.graptionBackground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.graptionAccent, in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!canSubmit)
            .accessibilityLabel("Speak reply")
            if let status {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(Color.graptionSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var languageCard: some View {
        SettingsCard {
            Text("Languages")
                .font(.title3.bold())
                .foregroundStyle(Color.graptionAccent)
            languagePicker("I type in", selection: $sourceCode)
            languagePicker("They hear", selection: $targetCode)
        }
    }

    private var voiceCard: some View {
        SettingsCard {
            Text("Voice")
                .font(.title3.bold())
                .foregroundStyle(Color.graptionAccent)
            Picker("Voice", selection: voiceChoice) {
                ForEach(SpeakingVoice.builtIn) { voice in
                    Text(voice.name).tag(voice.id)
                }
                Text("Custom voice").tag("custom")
            }
            .pickerStyle(.menu)
            .tint(Color.graptionAccent)
            if voiceChoice.wrappedValue == "custom" {
                TextField(
                    "Voice ID",
                    text: $customVoice,
                    prompt: Text("Paste a voice ID").foregroundStyle(Color.graptionSecondaryText)
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.white)
                .font(.callout)
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.graptionAccent, lineWidth: 1))
                .accessibilityLabel("Custom voice ID")
                .onChange(of: customVoice) { _, newValue in
                    voiceID = newValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
            }
            Text("Built-in voices speak every language. For your own voice, create a Custom Voice in the xAI console and paste its voice ID. Graption sends that ID, not a recording.")
                .font(.footnote)
                .foregroundStyle(Color.graptionSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resultCard(_ spoken: String) -> some View {
        SettingsCard {
            Text("Spoken aloud")
                .font(.title3.bold())
                .foregroundStyle(Color.graptionAccent)
            Text(spoken)
                .font(.body)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Spoken aloud. \(spoken)")
        }
    }

    private func languagePicker(_ title: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(Color.graptionAccent)
            Picker(title, selection: selection) {
                ForEach(SpeakingLanguage.all) { language in
                    Text(language.name).tag(language.code)
                }
            }
            .pickerStyle(.menu)
            .tint(Color.graptionAccent)
        }
    }

    private var voiceChoice: Binding<String> {
        Binding(
            get: {
                SpeakingVoice.builtIn.contains(where: { $0.id == voiceID }) ? voiceID : "custom"
            },
            set: { newValue in
                if newValue == "custom" {
                    if SpeakingVoice.builtIn.contains(where: { $0.id == voiceID }) {
                        voiceID = customVoice
                    }
                } else {
                    voiceID = newValue
                }
            }
        )
    }

    private var selectedVoiceID: String {
        if SpeakingVoice.builtIn.contains(where: { $0.id == voiceID }) {
            return voiceID
        }
        return customVoice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var canSubmit: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !isSpeaking
            && !trimmed.isEmpty
            && trimmed.count <= SpeakingReplyLimits.maxCharacters
            && !selectedVoiceID.isEmpty
    }

    private func submit() {
        isTextFocused = false
        let draft = SpeakReplyDraft(
            text: text,
            sourceLanguage: sourceCode,
            targetLanguage: targetCode,
            voiceID: selectedVoiceID
        )
        isSpeaking = true
        status = "Speaking…"
        Task {
            do {
                let reply = try await speak(draft)
                spokenText = reply.spokenText
                status = SpeakReplyStatus.text(source: draft.sourceLanguage, target: draft.targetLanguage, reply: reply)
            } catch {
                spokenText = nil
                status = error.localizedDescription
            }
            isSpeaking = false
        }
    }
}

#Preview {
    SpeakReplySheet { draft in
        SpokenReply(
            spokenText: "¿Dónde está el baño?",
            translated: true,
            modelVersion: "preview",
            usedServerAudio: true
        )
    }
}
