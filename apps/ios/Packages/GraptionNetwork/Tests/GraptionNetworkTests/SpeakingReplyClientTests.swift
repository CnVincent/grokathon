import XCTest
@testable import GraptionNetwork
import GraptionCore

final class SpeakingReplyClientTests: XCTestCase {
    override func tearDown() {
        SpeakingReplyStubURLProtocol.handler = nil
        super.tearDown()
    }

    func testMissingKeyDisablesGrokSpeech() {
        XCTAssertNil(SpeakingReplyConfiguration.fromAppConfiguration(bundle: Bundle(for: SpeakingReplyClientTests.self)))
        XCTAssertNil(GrokSpeakingReplyClient.fromAppConfiguration(bundle: Bundle(for: SpeakingReplyClientTests.self)))
    }

    func testEnglishBecomesSpanishTTSAndSendsNoMicrophoneAudio() async throws {
        let seen = RequestList()
        SpeakingReplyStubURLProtocol.handler = { request in
            seen.add(request)
            let path = request.url?.path ?? ""
            if path.hasSuffix("/responses") {
                let payload = #"{"status":"completed","output_text":"\"¿Dónde está el baño?\""}"#
                return (200, Data(payload.utf8), "application/json")
            }
            return (200, Data("ID3fake-mp3".utf8), "audio/mpeg")
        }
        let client = GrokSpeakingReplyClient(
            configuration: SpeakingReplyConfiguration(apiKey: "test-key", engine: .tts),
            session: stubSession()
        )

        let spoken = try await client.speak(
            text: " Where is the bathroom? ",
            sourceLanguage: "en",
            targetLanguage: "es-MX",
            voiceID: " Eve "
        )

        XCTAssertEqual(spoken.spokenText, "¿Dónde está el baño?")
        XCTAssertTrue(spoken.translated)
        XCTAssertEqual(spoken.voiceID, "eve")
        XCTAssertEqual(spoken.targetLanguage, "es-MX")
        XCTAssertEqual(spoken.mimeType, "audio/mpeg")
        XCTAssertEqual(spoken.audio, Data("ID3fake-mp3".utf8))
        XCTAssertEqual(spoken.modelVersion, "grok-tts+grok-4.7")

        let requests = seen.items
        XCTAssertEqual(requests.count, 2)
        let translation = try jsonBody(requests[0])
        XCTAssertEqual(Set(translation.keys), ["model", "input"])
        XCTAssertEqual(translation["model"] as? String, "grok-4.7")
        XCTAssertNil(translation["tools"])
        let input = try XCTUnwrap(translation["input"] as? [[String: Any]])
        let system = try XCTUnwrap(input.first?["content"] as? String)
        let user = try XCTUnwrap(input.last?["content"] as? String)
        XCTAssertTrue(system.contains("Spanish (Mexico)"))
        XCTAssertTrue(system.contains("Return only the spoken translation"))
        XCTAssertEqual(user, "Where is the bathroom?")
        XCTAssertFalse(system.contains("test-key"))

        let speech = try jsonBody(requests[1])
        XCTAssertEqual(speech["text"] as? String, "¿Dónde está el baño?")
        XCTAssertEqual(speech["voice_id"] as? String, "eve")
        XCTAssertEqual(speech["language"] as? String, "es-MX")
        XCTAssertEqual(requests[1].url?.absoluteString, "https://api.x.ai/v1/tts")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let raw = try XCTUnwrap(bodyData(from: requests[1]))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("test-key"))
    }

    func testSameLanguageSkipsTranslation() async throws {
        let seen = RequestList()
        SpeakingReplyStubURLProtocol.handler = { request in
            seen.add(request)
            XCTAssertTrue(request.url?.path.hasSuffix("/tts") == true)
            return (200, Data([0x49, 0x44, 0x33]), "audio/mpeg")
        }
        let client = GrokSpeakingReplyClient(
            configuration: SpeakingReplyConfiguration(apiKey: "test-key"),
            session: stubSession()
        )

        let spoken = try await client.speak(text: "Hello", sourceLanguage: "es-MX", targetLanguage: "es-ES", voiceID: "ara")

        XCTAssertFalse(spoken.translated)
        XCTAssertEqual(spoken.spokenText, "Hello")
        XCTAssertEqual(seen.items.count, 1)
        let speech = try jsonBody(seen.items[0])
        XCTAssertEqual(speech["language"] as? String, "es-ES")
        XCTAssertEqual(speech["text"] as? String, "Hello")
    }

    func testCustomVoiceIsForwardedAndInvalidInputDoesNotCallXAI() async {
        let seen = RequestList()
        SpeakingReplyStubURLProtocol.handler = { request in
            seen.add(request)
            return (200, Data("ID3".utf8), "audio/mpeg")
        }
        let client = GrokSpeakingReplyClient(
            configuration: SpeakingReplyConfiguration(apiKey: "test-key"),
            session: stubSession()
        )

        let spoken = try? await client.speak(text: "Hello", sourceLanguage: "en", targetLanguage: "en", voiceID: "abc123xy")
        XCTAssertEqual(spoken?.voiceID, "abc123xy")

        await assertRejects(.emptyText) {
            try await client.speak(text: "   ", sourceLanguage: "en", targetLanguage: "es-MX", voiceID: "eve")
        }
        await assertRejects(.tooLong) {
            try await client.speak(
                text: String(repeating: "a", count: 501),
                sourceLanguage: "en",
                targetLanguage: "es-MX",
                voiceID: "eve"
            )
        }
        await assertRejects(.unsupportedLanguage) {
            try await client.speak(text: "Hello", sourceLanguage: "en", targetLanguage: "zz", voiceID: "eve")
        }
        await assertRejects(.invalidVoice) {
            try await client.speak(text: "Hello", sourceLanguage: "en", targetLanguage: "es-MX", voiceID: "my voice")
        }
        XCTAssertEqual(seen.items.count, 1)
    }

    func testVoiceEngineSpeaksTheTranslationAndDoesNotCallTTS() async throws {
        let seen = RequestList()
        let captured = TextBox()
        SpeakingReplyStubURLProtocol.handler = { request in
            seen.add(request)
            XCTAssertTrue(request.url?.path.hasSuffix("/responses") == true)
            return (200, Data(#"{"status":"completed","output_text":"Hola."}"#.utf8), "application/json")
        }
        let client = GrokSpeakingReplyClient(
            configuration: SpeakingReplyConfiguration(apiKey: "test-key", engine: .voice),
            session: stubSession(),
            voiceSynthesizer: { text, voice, language in
                captured.text = "\(text)|\(voice)|\(language)"
                return Data("RIFFvoice".utf8)
            }
        )

        let spoken = try await client.speak(text: "Hello", sourceLanguage: "en", targetLanguage: "es-MX", voiceID: "rex")

        XCTAssertEqual(spoken.mimeType, "audio/wav")
        XCTAssertEqual(spoken.modelVersion, "grok-voice-3.0+grok-4.7")
        XCTAssertEqual(spoken.audio, Data("RIFFvoice".utf8))
        XCTAssertEqual(captured.text, "Hola.|rex|Spanish (Mexico)")
        XCTAssertEqual(seen.items.count, 1)
    }

    func testVoiceTurnIsTextOnlyAndWrapsPCM() throws {
        let messages = GrokVoiceTurn.messages(spokenText: "Hola.", voiceID: "abc123xy", languageName: "Spanish (Mexico)")
        let data = try JSONSerialization.data(withJSONObject: messages)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("verbatim"))
        XCTAssertTrue(text.contains("Do not answer"))
        XCTAssertTrue(text.contains("Hola."))
        XCTAssertTrue(text.contains("abc123xy"))
        XCTAssertTrue(text.contains("grok-voice-3.0") == false)
        XCTAssertFalse(text.contains("input_audio"))
        XCTAssertEqual(
            GrokVoiceTurn.realtimeURL()?.absoluteString,
            "wss://api.x.ai/v1/realtime?model=grok-voice-3.0"
        )

        let pcm = Data([0x01, 0x00, 0x02, 0x00])
        let delta = #"{"type":"response.output_audio.delta","delta":"\#(pcm.base64EncodedString())"}"#
        let wav = try GrokVoiceTurn.wav(from: [Data(delta.utf8), Data(#"{"type":"response.done"}"#.utf8)])
        XCTAssertEqual(wav.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(wav.suffix(4), pcm)

        XCTAssertThrowsError(
            try GrokVoiceTurn.wav(from: [Data(#"{"type":"error","message":"secret-upstream-echo"}"#.utf8)])
        ) { error in
            XCTAssertEqual(error as? SpeakingReplyError, .unavailable)
            XCTAssertFalse((error as? LocalizedError)?.errorDescription?.contains("secret") == true)
        }
    }

    func testUpstreamFailureHidesTheBody() async {
        SpeakingReplyStubURLProtocol.handler = { _ in
            (401, Data(#"{"error":"secret-upstream-echo"}"#.utf8), "application/json")
        }
        let client = GrokSpeakingReplyClient(
            configuration: SpeakingReplyConfiguration(apiKey: "test-key"),
            session: stubSession()
        )
        do {
            _ = try await client.speak(text: "Hello", sourceLanguage: "en", targetLanguage: "es-MX", voiceID: "eve")
            XCTFail("expected failure")
        } catch let error as SpeakingReplyError {
            XCTAssertEqual(error, .unavailable)
            XCTAssertFalse(error.localizedDescription?.contains("secret") == true)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    private func assertRejects(
        _ expected: SpeakingReplyError,
        _ call: () async throws -> SpokenReplyAudio
    ) async {
        do {
            _ = try await call()
            XCTFail("expected \(expected)")
        } catch let error as SpeakingReplyError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpeakingReplyStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(bodyData(from: request))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 1024)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class RequestList: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func add(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    var items: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class TextBox: @unchecked Sendable {
    var text = ""
}

private final class SpeakingReplyStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data, contentType) = try handler(request)
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": contentType]
                  )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
