import XCTest
@testable import GraptionNetwork
import GraptionCore

final class ToneClientTests: XCTestCase {
    func testBuildsEndpointAndEncodesSessionID() throws {
        let configuration = ToneClientConfiguration(
            serverURL: URL(string: "ws://192.168.1.8:8000")!,
            sessionID: "demo+phone"
        )
        XCTAssertEqual(
            try configuration.sessionURL().absoluteString,
            "ws://192.168.1.8:8000/ws/session?session_id=demo%2Bphone"
        )
    }

    func testToneRequestUsesSharedSchemaKeys() throws {
        let event = Events(
            schemaVersion: .the12,
            sessionID: "demo",
            type: .toneRequest,
            captionID: "3f1c2a9e-8b7d-4c6e-9a01-2b3c4d5e6f70",
            tEnd: 1.1,
            tStart: 1.0,
            audioB64: "AAABAAIA",
            sampleRate: 16_000
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as! [String: Any]
        XCTAssertEqual(object["type"] as? String, "tone_request")
        XCTAssertEqual(object["schema_version"] as? String, "1.2")
        XCTAssertEqual(object["session_id"] as? String, "demo")
    }
}
