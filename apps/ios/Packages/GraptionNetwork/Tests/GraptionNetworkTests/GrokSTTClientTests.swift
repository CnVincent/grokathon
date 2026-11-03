import XCTest
@testable import GraptionNetwork

final class GrokSTTClientTests: XCTestCase {
    func testBuildsEndpointAndEncodesSessionID() throws {
        let configuration = GrokSTTConfiguration(
            serverURL: URL(string: "ws://192.168.1.8:8000")!,
            sessionID: "demo+phone"
        )
        XCTAssertEqual(
            try configuration.sessionURL().absoluteString,
            "ws://192.168.1.8:8000/ws/stt?session_id=demo%2Bphone"
        )
    }

    func testParsesPartialWithLanguageAndSpeaker() throws {
        let json = """
        {
          "type": "stt.partial",
          "text": "नमस्ते",
          "language": "hi",
          "is_final": false,
          "speech_final": false,
          "words": [
            {"text": "नमस्ते", "start": 0.0, "end": 0.4, "speaker": 1, "confidence": 0.9}
          ]
        }
        """.data(using: .utf8)!

        XCTAssertEqual(
            GrokSTTEvent.parse(json),
            .partial(
                text: "नमस्ते",
                language: "hi",
                isFinal: false,
                speechFinal: false,
                speaker: 1
            )
        )
    }

    func testParsesDoneEvent() throws {
        let json = """
        {
          "type": "stt.done",
          "text": "hello there",
          "language": "en",
          "duration": 1.25,
          "words": [
            {"text": "hello", "start": 0.0, "end": 0.3, "speaker": 2, "confidence": 0.8},
            {"text": "there", "start": 0.3, "end": 0.6, "speaker": 2, "confidence": 0.7}
          ]
        }
        """.data(using: .utf8)!

        XCTAssertEqual(
            GrokSTTEvent.parse(json),
            .done(text: "hello there", language: "en", duration: 1.25, speaker: 2)
        )
    }

    func testParsesErrorEvent() throws {
        let json = """
        {"type": "stt.error", "code": "upstream", "message": "xAI closed the stream"}
        """.data(using: .utf8)!

        XCTAssertEqual(
            GrokSTTEvent.parse(json),
            .error(code: "upstream", message: "xAI closed the stream")
        )
    }

    func testUnknownJSONIsUnexpectedMessage() {
        let json = #"{"type":"not.a.real.event"}"#.data(using: .utf8)!
        let event = GrokSTTEvent.parse(json)
        guard case .error(let code, _) = event else {
            return XCTFail("expected unexpected_message, got \(event)")
        }
        XCTAssertEqual(code, "unexpected_message")
    }
}
