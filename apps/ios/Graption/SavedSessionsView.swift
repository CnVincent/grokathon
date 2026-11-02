import SwiftUI
import GraptionCore

@MainActor
struct SavedSessionsView: View {
    @State private var store: FileSessionStore?
    @State private var recorder: SessionRecorder?
    @State private var sessions: [SavedSession] = []
    @State private var errorMessage: String?
    @State private var isSaving = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                #if DEBUG
                Section("Session persistence demo") {
                    if let recorder {
                        ForEach(recorder.session.captions) { caption in
                            CaptionRow(caption: caption)
                        }
                        Button(isSaving ? "Saving…" : "End Session & Save") {
                            Task { await endSession() }
                        }
                        .disabled(isSaving)
                    } else {
                        Button("Start Fake Session") { startFakeSession() }
                            .disabled(store == nil)
                    }
                    Text("Synthetic captions only. No microphone or audio recording.")
                        .font(.footnote)
                }
                #endif
                Section("Saved sessions") {
                    if sessions.isEmpty {
                        Text("No saved sessions yet.")
                    }
                    ForEach(sessions) { session in
                        NavigationLink {
                            List {
                                ForEach(session.captions) { caption in
                                    CaptionRow(caption: caption)
                                }
                            }
                            .navigationTitle("Saved transcript")
                        } label: {
                            VStack(alignment: .leading) {
                                Text(session.startedAt.formatted(date: .abbreviated, time: .standard))
                                Text("\(session.captions.count) captions")
                                    .font(.subheadline)
                            }
                        }
                    }
                    Button("Reload Saved Sessions") {
                        Task { await reload() }
                    }
                }
            }
            .navigationTitle("Saved sessions")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            do {
                store = try FileSessionStore.onDevice()
                await reload()
            } catch {
                errorMessage = "Could not open local session storage. \(error.localizedDescription)"
            }
        }
        .alert("Session storage", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func reload() async {
        guard let store else { return }
        do {
            sessions = try await store.loadSessions()
        } catch {
            errorMessage = "Could not load saved sessions. \(error.localizedDescription)"
        }
    }

    #if DEBUG
    private func startFakeSession() {
        guard let store else { return }
        let recorder = SessionRecorder(store: store)
        let versions = ["asr": "fake-asr-v1", "asd": "fake-asd-v1"]
        recorder.append(SavedCaption(text: "Hello, everyone.", speakerID: "f1",
            toneTag: "happy", tStart: 0, tEnd: 2,
            modelVersions: versions.merging(["tone": "fake-tone-v1"]) { _, new in new }))
        recorder.append(SavedCaption(text: "Let's plan our next meeting.", speakerID: "f2",
            tStart: 2.5, tEnd: 5, modelVersions: versions))
        recorder.append(SavedCaption(text: "See you on Friday!", speakerID: "unknown",
            tStart: 5.5, tEnd: 7, modelVersions: versions))
        self.recorder = recorder
    }

    private func endSession() async {
        guard let recorder else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await recorder.end()
            self.recorder = nil
            await reload()
        } catch {
            errorMessage = "Could not save this session. Tap End Session & Save to retry. \(error.localizedDescription)"
        }
    }
    #endif
}

private struct CaptionRow: View {
    let caption: SavedCaption

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption.speakerID == "unknown" ? "Someone" : caption.speakerID)
                .font(.headline)
            Text(caption.text)
            if let tone = caption.toneTag {
                Text("Tone: \(tone)")
                    .font(.subheadline)
            }
            Text("\(caption.tStart.formatted())–\(caption.tEnd.formatted()) seconds")
                .font(.caption)
        }
    }
}

#Preview {
    ContentView()
}
