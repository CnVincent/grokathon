import SwiftUI

/// Live captions screen. Pass `onMicrophone` to drive it from the real
/// microphone pipeline. With no handler, previews keep the scripted session.
public struct LiveCaptionScreen: View {
    @AppStorage("summaryConsent") private var summaryConsent = false
    @State private var simulator = LiveCaptionSessionSimulator()
    @State private var showSettings = false
    @State private var showConsentSheet = false
    @State private var showSummarySheet = false
    @State private var pendingSummaryAfterConsent = false
    @State private var summaryMessage = ""

    private let cameraPreviewDestination: (() -> AnyView)?
    private let suppliedCaptions: [LiveCaption]?
    private let suppliedAlert: SoundAlert?
    private let isListening: Bool
    private let canListen: Bool
    private let statusText: String?
    private let onMicrophone: (() -> Void)?
    private let onSetup: (() -> Void)?
    private let setupTitle: String
    private let onCalibrate: (() -> Void)?
    private let isCalibrating: Bool
    private let calibrationCount: Int?
    private let isSettingUp: Bool
    private let onWhatDidIMiss: (([LiveCaption]) async throws -> String)?

    public init(
        cameraPreviewDestination: (() -> AnyView)? = nil,
        captions: [LiveCaption]? = nil,
        soundAlert: SoundAlert? = nil,
        isListening: Bool = false,
        canListen: Bool = true,
        statusText: String? = nil,
        onMicrophone: (() -> Void)? = nil,
        onSetup: (() -> Void)? = nil,
        setupTitle: String = "Set up captions",
        onCalibrate: (() -> Void)? = nil,
        isCalibrating: Bool = false,
        calibrationCount: Int? = nil,
        isSettingUp: Bool = false,
        onWhatDidIMiss: (([LiveCaption]) async throws -> String)? = nil
    ) {
        self.cameraPreviewDestination = cameraPreviewDestination
        self.suppliedCaptions = captions
        self.suppliedAlert = soundAlert
        self.isListening = isListening
        self.canListen = canListen
        self.statusText = statusText
        self.onMicrophone = onMicrophone
        self.onSetup = onSetup
        self.setupTitle = setupTitle
        self.onCalibrate = onCalibrate
        self.isCalibrating = isCalibrating
        self.calibrationCount = calibrationCount
        self.isSettingUp = isSettingUp
        self.onWhatDidIMiss = onWhatDidIMiss
    }

    private var usesLiveAudio: Bool { onMicrophone != nil }

    private var displayedCaptions: [LiveCaption] {
        suppliedCaptions ?? simulator.captions
    }

    private var displayedAlert: SoundAlert? {
        usesLiveAudio ? suppliedAlert : simulator.soundAlert
    }

    public var body: some View {
        NavigationStack {
            screenContent
                .navigationDestination(isPresented: $showSettings) {
                    SettingsScreen(cameraPreviewDestination: cameraPreviewDestination)
                }
        }
    }

    private var screenContent: some View {
        VStack(spacing: 0) {
            CaptionHeaderView(
                subtitle: statusText ?? "Graption • Live camera",
                onSettings: { showSettings = true }
            )
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)

            if let alert = displayedAlert {
                SoundAlertBannerView(alert: alert)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            videoArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if onSetup != nil || onCalibrate != nil {
                preparationRow
            }

            whatDidIMissButton

            BottomControlsBar(
                isListening: isListening,
                canListen: canListen,
                onMicrophone: { onMicrophone?() }
            )
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .background(Color.graptionBackground.ignoresSafeArea())
        .overlay {
            if let calibrationCount {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    VStack(spacing: 8) {
                        Text("Calibrating")
                            .font(.title2.bold())
                            .foregroundStyle(Color.graptionAccent)
                        Text("\(calibrationCount)")
                            .font(.system(size: 120, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                        Text("Keep the room quiet")
                            .font(.title3.bold())
                            .foregroundStyle(Color.graptionAccent)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Calibrating. Keep the room quiet. \(calibrationCount)")
            }
        }
        .animation(.easeOut(duration: 0.2), value: calibrationCount)
        .toolbar(.hidden, for: .navigationBar)
        .animation(.easeOut(duration: 0.3), value: displayedAlert?.message)
        .task {
            guard !usesLiveAudio else { return }
            simulator.start()
        }
        .onDisappear {
            simulator.stop()
        }
        .sheet(isPresented: $showConsentSheet) {
            SummaryConsentView(
                onAccept: {
                    summaryConsent = true
                    pendingSummaryAfterConsent = true
                    showConsentSheet = false
                },
                onDecline: {
                    pendingSummaryAfterConsent = false
                    showConsentSheet = false
                }
            )
        }
        .sheet(isPresented: $showSummarySheet) {
            SummaryResultSheet(message: $summaryMessage)
        }
        .onChange(of: showConsentSheet) { _, isPresented in
            guard !isPresented, pendingSummaryAfterConsent else { return }
            pendingSummaryAfterConsent = false
            Task { await requestSummary() }
        }
    }

    private var videoArea: some View {
        ZStack(alignment: .bottom) {
            if let dest = cameraPreviewDestination {
                dest()
            } else {
                LiveVideoFeedView(captions: displayedCaptions)
            }

            if !displayedCaptions.isEmpty && cameraPreviewDestination != nil {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(displayedCaptions) { caption in
                        CaptionBubbleView(caption: caption)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var whatDidIMissButton: some View {
        Button {
            handleWhatDidIMissTapped()
        } label: {
            Text("What did I miss?")
                .font(.body.bold())
                .foregroundStyle(Color.graptionBackground)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 48)
                .background(Color.graptionAccent, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityLabel("What did I miss?")
    }

    private func handleWhatDidIMissTapped() {
        if !summaryConsent {
            showConsentSheet = true
            return
        }
        Task { await requestSummary() }
    }

    /// Consent is already granted. Never touches captions or the mic pipeline.
    @MainActor
    private func requestSummary() async {
        guard let onWhatDidIMiss else {
            summaryMessage = "The summary server is not configured. Captions keep working offline."
            showSummarySheet = true
            return
        }
        let cutoff = Date().addingTimeInterval(-120)
        let recent = displayedCaptions.filter {
            $0.spokenAt >= cutoff && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        summaryMessage = "Summarizing…"
        showSummarySheet = true
        do {
            summaryMessage = try await onWhatDidIMiss(recent)
        } catch {
            summaryMessage = "Couldn't summarize just now. Captions keep working."
        }
    }

    private var preparationRow: some View {
        HStack(spacing: 12) {
            if let onSetup {
                Button(setupTitle, action: onSetup)
                    .disabled(isSettingUp)
            }
            if let onCalibrate {
                Button(isCalibrating ? "Stop calibration" : "Calibrate room noise", action: onCalibrate)
                    .disabled(isSettingUp)
            }
        }
        .font(.footnote.bold())
        .foregroundStyle(Color.graptionAccent)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.graptionBackground)
    }
}

private struct SummaryResultSheet: View {
    @Binding var message: String

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(message)
                    .font(.body)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .background(Color.graptionBackground.ignoresSafeArea())
            .navigationTitle("What did I miss?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.graptionBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    LiveCaptionScreen()
}

#Preview("Accessibility XXXL") {
    LiveCaptionScreen()
        .dynamicTypeSize(.accessibility5)
}
