import Foundation
import XCTest
@testable import GraptionCore

final class SessionStoreTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @MainActor
    func testEndedSessionSurvivesNewStoreAndPreservesCaptionFields() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SessionRecorder(store: FileSessionStore(directory: directory))
        let first = SavedCaption(text: "Hello 👋", speakerID: "f1", tStart: 0.2, tEnd: 2,
            modelVersions: ["asr": "fake-asr-v1", "asd": "fake-asd-v1"])
        let second = SavedCaption(text: "Off-screen reply", speakerID: "unknown", tStart: 2, tEnd: 3,
            modelVersions: ["asr": "fake-asr-v1", "asd": "fake-asd-v1"])
        recorder.append(first)
        recorder.append(second)
        try await recorder.applyTone(captionID: first.id, tag: "happy", modelVersion: "fake-tone-v1")
        let beforeEnd = try await FileSessionStore(directory: directory).loadSessions()
        XCTAssertTrue(beforeEnd.isEmpty)
        try await recorder.end()
        let reopened = FileSessionStore(directory: directory)
        let loaded = try await reopened.loadSessions()
        XCTAssertEqual(loaded, [recorder.session])
        XCTAssertEqual(loaded.first?.captions[0].toneTag, "happy")
        XCTAssertNil(loaded.first?.captions[1].toneTag)
        XCTAssertEqual(loaded.first?.captions[1].speakerID, "unknown")

        // Assert the complete persisted allowlist, rather than only searching for audio keys.
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: files[0])) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["storageVersion", "id", "startedAt", "duration", "captions"])
        let captions = try XCTUnwrap(json["captions"] as? [[String: Any]])
        XCTAssertEqual(Set(captions[0].keys), ["id", "text", "speakerID", "toneTag", "tStart", "tEnd", "modelVersions"])
    }

    @MainActor
    func testLateToneAndRepeatedEndUpdateSameSession() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSessionStore(directory: directory)
        let recorder = SessionRecorder(store: store)
        let caption = SavedCaption(text: "Hi", speakerID: "f2", tStart: 0, tEnd: 1,
            modelVersions: ["asr": "fake-v1"])
        recorder.append(caption)
        recorder.append(caption)
        try await recorder.end()
        try await recorder.applyTone(captionID: UUID(), tag: "sad", modelVersion: "fake-tone-v1")
        try await recorder.applyTone(captionID: caption.id, tag: "happy", modelVersion: "fake-tone-v1")
        var loaded = try await store.loadSessions()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.captions.count, 1)
        XCTAssertEqual(loaded.first?.captions.first?.toneTag, "happy")
        try await recorder.applyTone(captionID: caption.id, tag: nil, modelVersion: "fake-tone-v2")
        try await recorder.end()
        loaded = try await store.loadSessions()
        XCTAssertEqual(loaded, [recorder.session])
        XCTAssertNil(loaded.first?.captions.first?.toneTag)
        XCTAssertEqual(loaded.first?.captions.first?.modelVersions["tone"], "fake-tone-v2")
    }

    func testEmptySessionsAndNewestFirst() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSessionStore(directory: directory)
        let old = SavedSession(startedAt: Date(timeIntervalSince1970: 1), duration: 0, captions: [])
        let new = SavedSession(startedAt: Date(timeIntervalSince1970: 2), duration: 0, captions: [])
        try await store.save(new)
        try await store.save(old)
        let loaded = try await store.loadSessions()
        XCTAssertEqual(loaded, [new, old])
    }

    func testInvalidTimingsCannotOverwriteSavedSession() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSessionStore(directory: directory)
        var session = SavedSession(duration: 1, captions: [])
        try await store.save(session)
        session.captions = [SavedCaption(text: "Invalid", speakerID: "f1", tStart: 2, tEnd: 1,
            modelVersions: [:])]
        do {
            try await store.save(session)
            XCTFail("Invalid timing should fail")
        } catch SessionStorageError.invalidTimings {}
        let loaded = try await store.loadSessions()
        XCTAssertTrue(try XCTUnwrap(loaded.first).captions.isEmpty)
    }

    @MainActor
    func testFailedSaveRetainsTranscriptForRetry() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A file where the store expects a directory forces a real I/O failure.
        try Data().write(to: directory)
        let recorder = SessionRecorder(store: FileSessionStore(directory: directory))
        recorder.append(SavedCaption(text: "Keep me", speakerID: "f1", tStart: 0, tEnd: 1,
            modelVersions: ["asr": "fake-v1"]))
        do {
            try await recorder.end()
            XCTFail("Save should fail")
        } catch {}
        XCTAssertEqual(recorder.session.captions.count, 1)
        try FileManager.default.removeItem(at: directory)
        try await recorder.end()
        let loaded = try await FileSessionStore(directory: directory).loadSessions()
        XCTAssertEqual(loaded, [recorder.session])
    }

    func testCorruptFileSurfacesError() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("bad JSON".utf8).write(to: directory.appendingPathComponent("broken.json"))
        do {
            _ = try await FileSessionStore(directory: directory).loadSessions()
            XCTFail("Corruption should be reported, not displayed as empty history")
        } catch is DecodingError {}
    }
}
