import XCTest
@testable import GraptionNetwork

final class SirenContextClientTests: XCTestCase {
    override func tearDown() {
        SirenStubURLProtocol.handler = nil
        super.tearDown()
    }

    func testNeedsContextOnlyForSirenAndAlarm() {
        XCTAssertTrue(SirenContextCopy.needsContext("siren"))
        XCTAssertTrue(SirenContextCopy.needsContext("alarm"))
        XCTAssertFalse(SirenContextCopy.needsContext("doorbell"))
        XCTAssertFalse(SirenContextCopy.needsContext("dog_bark"))
    }

    func testBannerLineMatchesShelterWording() {
        XCTAssertEqual(
            SirenContextCopy.bannerLine(
                label: "siren",
                reason: "tornado warning for Fulton County, shelter now"
            ),
            "🚨 Siren: tornado warning for Fulton County, shelter now."
        )
        XCTAssertEqual(
            SirenContextCopy.bannerLine(
                label: "alarm",
                reason: "🚨 Alarm: smoke reported on campus, leave the building."
            ),
            "🚨 Alarm: smoke reported on campus, leave the building."
        )
    }

    func testUncertainReasonStaysEmpty() {
        let rejected = [
            "NONE",
            "none.",
            "n/a",
            "I don't know",
            "no official post",
            "maybe a test",
            "fire",
            String(repeating: "a", count: 81)
        ]
        for reason in rejected {
            XCTAssertNil(SirenContextCopy.bannerLine(label: "siren", reason: reason), reason)
        }
    }

    func testStaleAlertDoesNotUpdateBanner() {
        let current = UUID()
        let stale = UUID()
        XCTAssertNil(
            SirenContextCopy.applying(
                alertID: stale,
                currentID: current,
                label: "siren",
                reason: "tornado warning for Fulton County, shelter now"
            )
        )
        XCTAssertEqual(
            SirenContextCopy.applying(
                alertID: current,
                currentID: current,
                label: "siren",
                reason: "tornado warning for Fulton County, shelter now"
            ),
            "🚨 Siren: tornado warning for Fulton County, shelter now."
        )
    }

    func testHandlesStayOfficialAndCapped() {
        XCTAssertEqual(
            SirenContextConfiguration.resolvedHandles(from: " @NWS, NWS, bad handle, @GaTechPD "),
            ["NWS", "GaTechPD"]
        )
        let tooMany = (1...25).map { "Acct\($0)" }.joined(separator: ",")
        XCTAssertEqual(SirenContextConfiguration.resolvedHandles(from: tooMany).count, 20)
        XCTAssertEqual(
            SirenContextConfiguration.resolvedHandles(from: " "),
            SirenContextConfiguration.defaultHandles
        )
    }

    func testSearchWindowCoversTodayInUTC() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(
            DateComponents(calendar: calendar, year: 2026, month: 11, day: 2, hour: 19).date
        )
        let window = SirenContextAPI.searchWindow(containing: now)
        XCTAssertEqual(window.from, "2026-11-01")
        XCTAssertEqual(window.to, "2026-11-03")
    }

    func testRequestUsesXSearchAndSendsNoAudio() async throws {
        let captured = RequestBox()
        SirenStubURLProtocol.handler = { request in
            captured.request = request
            return (200, Data(#"{"status":"completed","output_text":"NONE"}"#.utf8))
        }
        let now = try XCTUnwrap(utcDate(year: 2026, month: 11, day: 2, hour: 19))
        let client = GrokSirenContextClient(
            configuration: SirenContextConfiguration(
                apiKey: "test-key",
                place: "Fulton County, near the Georgia Tech campus in Atlanta",
                handles: ["@NWS", "NWSAtlanta", "GaTechPD"]
            ),
            session: stubSession(),
            now: { now }
        )

        let reason = await client.explain(label: "siren")

        XCTAssertNil(reason)
        let request = try XCTUnwrap(captured.request)
        XCTAssertEqual(request.url?.absoluteString, "https://api.x.ai/v1/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(bodyData(from: request))
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertFalse(text.contains("test-key"))
        XCTAssertFalse(text.contains("audio"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["model", "input", "tools", "max_turns"])
        XCTAssertEqual(json["model"] as? String, "grok-4.7")
        XCTAssertEqual(json["max_turns"] as? Int, 2)
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "x_search")
        XCTAssertEqual(tools[0]["allowed_x_handles"] as? [String], ["NWS", "NWSAtlanta", "GaTechPD"])
        XCTAssertEqual(tools[0]["from_date"] as? String, "2026-11-01")
        XCTAssertEqual(tools[0]["to_date"] as? String, "2026-11-03")
        XCTAssertNil(tools[0]["excluded_x_handles"])
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        let user = try XCTUnwrap(input.last?["content"] as? String)
        XCTAssertTrue(user.contains("siren"))
        XCTAssertTrue(user.contains("Fulton County"))
    }

    func testCompletedAnswerBecomesAReason() async throws {
        SirenStubURLProtocol.handler = { _ in
            (200, Data("""
            {
              "status": "completed",
              "output": [
                {"type": "custom_tool_call", "name": "x_keyword_search", "text": "tornado Fulton"},
                {"type": "message", "content": [
                  {"type": "output_text", "text": "tornado warning for Fulton County, shelter now"}
                ]}
              ]
            }
            """.utf8))
        }
        let client = GrokSirenContextClient(
            configuration: SirenContextConfiguration(apiKey: "test-key"),
            session: stubSession()
        )

        let reason = await client.explain(label: "siren")

        XCTAssertEqual(reason, "tornado warning for Fulton County, shelter now")
        XCTAssertEqual(client.modelVersion, "grok-4.7")
    }

    func testNoneIncompleteAndDoorbellStayEmpty() async {
        SirenStubURLProtocol.handler = { _ in
            (200, Data(#"{"status":"completed","output_text":"NONE"}"#.utf8))
        }
        let client = GrokSirenContextClient(
            configuration: SirenContextConfiguration(apiKey: "test-key"),
            session: stubSession()
        )
        XCTAssertNil(await client.explain(label: "siren"))

        SirenStubURLProtocol.handler = { _ in
            (200, Data(#"{"status":"incomplete","output_text":"tornado warning for Fulton County, shelter now"}"#.utf8))
        }
        XCTAssertNil(await client.explain(label: "alarm"))

        let doorbell = RequestBox()
        SirenStubURLProtocol.handler = { request in
            doorbell.request = request
            return (500, Data())
        }
        XCTAssertNil(await client.explain(label: "doorbell"))
        XCTAssertNil(doorbell.request)
    }

    func testHTTPFailureStaysEmpty() async {
        SirenStubURLProtocol.handler = { _ in (401, Data(#"{"error":{"message":"bad key"}}"#.utf8)) }
        let client = GrokSirenContextClient(
            configuration: SirenContextConfiguration(apiKey: "test-key"),
            session: stubSession()
        )
        XCTAssertNil(await client.explain(label: "siren"))
    }

    func testMissingKeyDisablesLookup() {
        let bundle = Bundle(for: SirenContextClientTests.self)
        XCTAssertNil(SirenContextConfiguration.fromAppConfiguration(bundle: bundle))
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SirenStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func utcDate(year: Int, month: Int, day: Int, hour: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return DateComponents(calendar: calendar, year: year, month: month, day: day, hour: hour).date
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

private final class RequestBox: @unchecked Sendable {
    var request: URLRequest?
}

private final class SirenStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request)
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
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
