import SwiftUI
import GraptionAudio
import GraptionNetwork
import GraptionUI

@MainActor
struct ContentView: View {
    @State private var showSavedSessions = false
    @State private var capture: MicrophoneCapture?
    @StateObject private var toneMonitor = ToneConnectionMonitor(
        configuration: ToneClientConfiguration.fromAppConfiguration(
            sessionID: UUID().uuidString
        )
    )
    @State private var soundAlertModel = SoundAlertModel(
        contextClient: GrokSirenContextClient.fromAppConfiguration()
    )
    @State private var hasPrintedLabels = false
    @State private var isVisible = false
    @State private var pipeline = CaptionPipeline()
    @State private var isRecording = false
    @State private var isCalibrating = false
    @State private var calibrationCount: Int?
    @State private var isStarting = false
    @State private var threshold: Float = 0.001
    @State private var isPreparing = false
    @State private var isReady = false
    @State private var status = "Loading base.en…"
    @State private var setupFailed = false
    @State private var captions: [CaptionEntry] = []
    @State private var listenTask: Task<Void, Never>?
    @AppStorage("onlineCaptionsEnabled") private var onlineCaptionsEnabled = false
    @AppStorage("onlineCaptionConsent") private var onlineCaptionConsent = false
    @State private var grokClient: GrokSTTClient?
    @State private var grokEventTask: Task<Void, Never>?
    @State private var onlineBoostActive = false
    @State private var onlineCaptionID: UUID?
    @State private var grokModelVersion = ""
    @State private var showSpeakSheet = false

    private var canListen: Bool {
        capture != nil && isReady && !isPreparing && !isCalibrating && !isStarting
    }

    /// Newest three captions, oldest on the left, matching the three-bubble layout.
    private var bubbleCaptions: [LiveCaption] {
        captions.prefix(3).reversed().map { entry in
            LiveCaption(id: entry.id, speakerName: entry.speakerName, text: entry.text)
        }
    }

    private var bannerAlert: GraptionUI.SoundAlert? {
        guard let alert = soundAlertModel.currentAlert else { return nil }
        let message = soundAlertModel.contextLine ?? SoundAlertBanner.title(for: alert.label)
        return GraptionUI.SoundAlert(message: message)
    }

    var body: some View {
        Group {
            if isReady {
                LiveCaptionScreen(
                    cameraPreviewDestination: { AnyView(CameraView(captions: bubbleCaptions)) },
                    captions: bubbleCaptions,
                    soundAlert: bannerAlert,
                    isListening: isRecording || isCalibrating,
                    canListen: canListen,
                    statusText: "\(status) · \(toneMonitor.state.label)",
                    onMicrophone: {
                        if isRecording || isCalibrating {
                            stopListening()
                        } else {
                            listenTask = Task { await listen() }
                        }
                    },
                    calibrationCount: calibrationCount,
                    isSettingUp: isPreparing,
                    canSpeak: !isCalibrating && !isPreparing && !isStarting,
                    onSpeak: { showSpeakSheet = true }
                )
            } else {
                InstallBaseEnPage(
                    isInstalling: isPreparing,
                    detail: setupFailed ? status : nil,
                    install: { Task { await prepareModel(allowDownload: true) } },
                    onSpeak: { showSpeakSheet = true }
                )
            }
        }
        .sheet(isPresented: $showSpeakSheet) {
            SpeakReplySheet { draft in
                try await speakReply(draft)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                showSavedSessions = true
            } label: {
                Label("Saved sessions", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
        .sheet(isPresented: $showSavedSessions) {
            SavedSessionsView()
        }
        .animation(.default, value: soundAlertModel.currentAlert?.id)
        .animation(.default, value: soundAlertModel.contextLine)
        .sensoryFeedback(.warning, trigger: soundAlertModel.currentAlert?.id) { _, new in
            new != nil
        }
        .task {
            isVisible = true
            toneMonitor.start()
            do {
                // Reuse one capture so calibration survives Stop/Start.
                if capture == nil {
                    capture = MicrophoneCapture(
                        vad: EnergyVAD(threshold: 0.001),
                        soundDetector: try AppleSoundDetector()
                    )
                }
                printKnownLabelsOnce()
                configureCallbacks()
                await prepareModel(allowDownload: false)
            } catch {
                report(error)
            }
        }
        .onChange(of: onlineCaptionsEnabled) { _, enabled in
            guard isRecording else { return }
            if enabled, onlineCaptionConsent {
                Task { await startOnlineBoost() }
            } else {
                fallbackFromOnlineBoost()
            }
        }
        .onDisappear {
            isVisible = false
            toneMonitor.stop()
            listenTask?.cancel()
            stopOnlineBoost()
            capture?.onSegment = nil
            capture?.onSoundAlert = nil
            capture?.onSamples = nil
            capture?.stop()
            soundAlertModel.clear()
            pipeline.reset()
            isRecording = false
            isCalibrating = false
            calibrationCount = nil
        }
    }

    private func configureCallbacks() {
        guard let capture else { return }
        capture.onSoundAlert = { alert in
            // Calibration measures noise; it must not announce or display alerts.
            guard isRecording, !isCalibrating, isVisible else { return }
            soundAlertModel.show(alert)
        }
        capture.onSegment = { segment in pipeline.enqueue(segment) }
        capture.onError = { error in
            if isCalibrating {
                capture.stop()
                isCalibrating = false
            }
            report(error)
        }
        pipeline.onError = { id, error in
            report(error, captionID: id)
        }
        pipeline.onResult = { delivery in
            let caption = delivery.result
            // Retained for later queue/UI diagnostics: measures enqueue-to-callback
            // time, including queue wait and ASR, but not the actual visible frame.
            // let delay = CaptionPipeline.seconds(delivery.receivedAt.duration(to: .now))
            // let line = String(
            //     format: "%.2f–%.2f s: %@\nTranscription time: %.2f s · Total processing time: %.2f s\n",
            //     caption.tStart, caption.tEnd,
            //     caption.text.isEmpty ? "[No speech recognized]" : caption.text,
            //     delivery.transcriptionSeconds, delay
            // )
            let line = String(
                format: "%.2f–%.2f s: %@\nSpeech-to-text (ASR) transcription time: %.2f s\n",
                caption.tStart, caption.tEnd,
                caption.text.isEmpty ? "[No speech recognized]" : caption.text,
                delivery.transcriptionSeconds
            )
            // Log every result, including short noise-triggered empty transcriptions.
            print("Caption \(caption.captionID) [\(caption.asrModelVersion)] \(line)")
            // Whisper may emit a blank-audio marker; hide it only in presentation.
            let displayText = caption.text
                .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isBlankAudio = caption.text.contains("[BLANK_AUDIO]") && displayText.isEmpty
            let isShortEmpty = caption.tEnd - caption.tStart < 1 && displayText.isEmpty
            guard !isBlankAudio, !isShortEmpty else { return }
            // Online Grok STT owns the visible list while the boost is healthy.
            // WhisperKit keeps running so fallback captions can appear immediately.
            guard !onlineBoostActive else { return }
            // Stable caption IDs keep cards distinct when newer results arrive.
            captions.insert(CaptionEntry(
                result: caption,
                text: displayText.isEmpty ? "[No speech recognized]" : displayText,
                transcriptionSeconds: delivery.transcriptionSeconds
            ), at: 0)
        }
    }

    private func prepareModel(allowDownload: Bool) async {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        status = "Loading base.en…"
        do {
            try await pipeline.prepare(allowDownload: allowDownload)
            isReady = pipeline.isReady
            setupFailed = !isReady
            status = isReady ? "Ready" : "Could not load base.en"
        } catch {
            let missing = (error as? TranscriberError) == .modelNotProvisioned
            setupFailed = allowDownload || !missing
            if missing, !allowDownload {
                status = "Wi-Fi is needed"
            } else {
                report(error)
            }
        }
    }

    /// Quiet stretch before captions. The detector needs 2 seconds of audio;
    /// 3 seconds leaves room for the microphone to start.
    private func listen() async {
        guard let capture else { return }
        guard !isRecording, !isCalibrating, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        guard await capture.requestPermission() else {
            status = "Microphone permission denied"
            return
        }
        guard !Task.isCancelled, isVisible else { return }
        pipeline.reset()
        soundAlertModel.clear()
        captions.removeAll()
        do {
            try capture.start(calibrating: true)
        } catch {
            report(error)
            return
        }
        isCalibrating = true
        status = "Keep the room quiet"
        for count in [3, 2, 1] {
            guard !Task.isCancelled, isVisible, isCalibrating else { return }
            calibrationCount = count
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
        guard !Task.isCancelled, isVisible, isCalibrating else { return }
        calibrationCount = nil
        isCalibrating = false
        do {
            threshold = try capture.stopCalibration()
            print(String(format: "Calibrated RMS threshold: %.6f", threshold))
        } catch {
            capture.stop()
            report(error)
            return
        }
        guard !Task.isCancelled, isVisible else { return }
        do {
            try capture.start()
            isRecording = true
            status = "Listening"
            Task { await startOnlineBoost() }
        } catch {
            report(error)
        }
    }

    /// Speaks a typed reply. Listening pauses so the phone does not caption its own speaker.
    private func speakReply(_ draft: SpeakReplyDraft) async throws -> SpokenReply {
        let resume = isRecording
        if resume {
            capture?.stop()
            isRecording = false
        }
        defer {
            guard resume else { return }
            do {
                try capture?.start()
                isRecording = true
                status = onlineBoostActive ? "Listening · online" : "Listening"
            } catch {
                report(error)
            }
        }

        let player = ReplyAudioPlayer()
        if let client = GrokSpeakingReplyClient.fromAppConfiguration() {
            let audio = try await client.speak(
                text: draft.text,
                sourceLanguage: draft.sourceLanguage,
                targetLanguage: draft.targetLanguage,
                voiceID: draft.voiceID
            )
            let language = audio.translated ? audio.targetLanguage : audio.sourceLanguage
            var usedServerAudio = false
            do {
                try await player.play(data: audio.audio)
                usedServerAudio = true
            } catch {
                try await player.speak(text: audio.spokenText, language: language)
            }
            return SpokenReply(
                spokenText: audio.spokenText,
                translated: audio.translated,
                modelVersion: audio.modelVersion,
                usedServerAudio: usedServerAudio
            )
        }

        try await player.speak(text: draft.text, language: draft.sourceLanguage)
        return SpokenReply(
            spokenText: draft.text,
            translated: false,
            modelVersion: "ios-speech",
            usedServerAudio: false
        )
    }

    private func stopListening() {
        let wasCalibrating = isCalibrating
        isCalibrating = false
        calibrationCount = nil
        isRecording = false
        listenTask?.cancel()
        listenTask = nil
        stopOnlineBoost()
        capture?.stop()
        soundAlertModel.clear()
        status = wasCalibrating ? "Ready" : "Stopped; finishing pending captions"
    }

    private func startOnlineBoost() async {
        guard onlineCaptionsEnabled, onlineCaptionConsent else { return }
        guard let capture else { return }
        guard let toneConfig = ToneClientConfiguration.fromAppConfiguration(
            sessionID: UUID().uuidString
        ) else { return }
        if grokClient != nil {
            stopOnlineBoost()
        }

        let client = GrokSTTClient(configuration: GrokSTTConfiguration(toneConfig))
        grokClient = client
        grokEventTask = Task { @MainActor in
            for await event in client.events {
                handleGrokEvent(event)
            }
        }
        do {
            try await client.connect()
            capture.onSamples = { samples in
                let pcm = pcm16Data(from: samples)
                Task { await client.sendPCM(pcm) }
            }
        } catch {
            capture.onSamples = nil
            onlineBoostActive = false
            grokEventTask?.cancel()
            grokEventTask = nil
            grokClient = nil
            await client.disconnect()
            print("Online captions unavailable: \(error.localizedDescription)")
        }
    }

    private func stopOnlineBoost() {
        capture?.onSamples = nil
        onlineBoostActive = false
        onlineCaptionID = nil
        grokEventTask?.cancel()
        grokEventTask = nil
        let client = grokClient
        grokClient = nil
        guard let client else { return }
        Task {
            await client.finish()
            await client.disconnect()
        }
    }

    private func fallbackFromOnlineBoost() {
        guard onlineBoostActive || grokClient != nil || capture?.onSamples != nil else { return }
        capture?.onSamples = nil
        onlineBoostActive = false
        onlineCaptionID = nil
        grokEventTask?.cancel()
        grokEventTask = nil
        let client = grokClient
        grokClient = nil
        if let client {
            Task { await client.disconnect() }
        }
        if isRecording {
            status = "Listening"
        }
    }

    private func handleGrokEvent(_ event: GrokSTTEvent) {
        switch event {
        case .ready(let modelVersion):
            grokModelVersion = modelVersion
            onlineBoostActive = true
            if isRecording {
                status = "Listening · online"
            }
            print("Online captions ready [\(modelVersion)]")
        case .partial(let text, let language, let isFinal, let speechFinal, let speaker):
            presentOnlineCaption(
                text: text,
                language: language,
                speaker: speaker,
                endsUtterance: isFinal || speechFinal
            )
        case .done(let text, let language, _, let speaker):
            presentOnlineCaption(
                text: text,
                language: language,
                speaker: speaker,
                endsUtterance: true
            )
        case .error(_, let message):
            print("Online captions error: \(message)")
            fallbackFromOnlineBoost()
        case .disconnected:
            fallbackFromOnlineBoost()
        }
    }

    private func presentOnlineCaption(
        text: String,
        language: String?,
        speaker: Int?,
        endsUtterance: Bool
    ) {
        let display = formattedOnlineCaption(text: text, language: language)
        guard !display.isEmpty else { return }
        if onlineCaptionID == nil, endsUtterance, captions.first?.text == display {
            return
        }
        let speakerName = speaker.map { "Speaker \($0)" } ?? "Someone"
        if let id = onlineCaptionID, let index = captions.firstIndex(where: { $0.id == id }) {
            captions[index] = CaptionEntry(
                id: id,
                text: display,
                speakerName: speakerName
            )
        } else {
            let id = UUID()
            onlineCaptionID = id
            captions.insert(
                CaptionEntry(id: id, text: display, speakerName: speakerName),
                at: 0
            )
            print("Caption \(id) [\(grokModelVersion)] \(display)")
        }
        if endsUtterance {
            onlineCaptionID = nil
        }
    }

    private func formattedOnlineCaption(text: String, language: String?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let language, !language.isEmpty {
            return "[\(language)] \(trimmed)"
        }
        return trimmed
    }

    private func printKnownLabelsOnce() {
        guard !hasPrintedLabels,
              let labels = try? AppleSoundDetector.knownClassifications() else { return }
        hasPrintedLabels = true
        print("SoundAnalysis knows \(labels.count) sounds:")
        print(labels.joined(separator: "\n"))
    }

    private func report(_ error: Error, captionID: UUID? = nil) {
        status = error.localizedDescription
        print("Caption/capture error [\(captionID?.uuidString ?? "setup")]: \(error.localizedDescription)")
    }
}


private struct InstallBaseEnPage: View {
    var isInstalling: Bool
    var detail: String?
    var install: () -> Void
    var onSpeak: () -> Void = {}

    var body: some View {
        ZStack {
            Color(red: 11 / 255, green: 31 / 255, blue: 59 / 255)
                .ignoresSafeArea()
            VStack(spacing: 20) {
                Text("Install base.en")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Color(red: 1, green: 149 / 255, blue: 0))
                Text("Wi-Fi is needed")
                    .font(.title3)
                    .foregroundStyle(.white)
                if let detail, detail != "Wi-Fi is needed" {
                    Text(detail)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Button(isInstalling ? "Installing…" : "Install") {
                    install()
                }
                .disabled(isInstalling)
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 1, green: 149 / 255, blue: 0))
                Button("Speak a reply") {
                    onSpeak()
                }
                .buttonStyle(.bordered)
                .tint(Color(red: 1, green: 149 / 255, blue: 0))
            }
            .padding(32)
        }
    }
}

/// Presentation data only; the transcription/event contracts are unchanged.
private struct CaptionEntry: Identifiable {
    let id: UUID
    let result: TranscriptionResult?
    let text: String
    let speakerName: String
    let transcriptionSeconds: TimeInterval

    init(result: TranscriptionResult, text: String, transcriptionSeconds: TimeInterval) {
        self.id = result.captionID
        self.result = result
        self.text = text
        self.speakerName = "Someone"
        self.transcriptionSeconds = transcriptionSeconds
    }

    init(id: UUID, text: String, speakerName: String) {
        self.id = id
        self.result = nil
        self.text = text
        self.speakerName = speakerName
        self.transcriptionSeconds = 0
    }
}

private func pcm16Data(from samples: [Float]) -> Data {
    var data = Data(count: samples.count * MemoryLayout<Int16>.size)
    data.withUnsafeMutableBytes { rawBuffer in
        let destination = rawBuffer.bindMemory(to: Int16.self)
        for index in samples.indices {
            let clamped = min(max(samples[index], -1), 1)
            destination[index] = clamped.isFinite ? Int16(clamped * Float(Int16.max)) : 0
        }
    }
    return data
}
