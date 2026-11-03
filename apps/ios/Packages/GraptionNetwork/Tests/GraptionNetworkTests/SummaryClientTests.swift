import XCTest
@testable import GraptionNetwork

final class SummaryClientTests: XCTestCase {
    override func tearDown() {
        SummaryStubURLProtocol.reset()
        super.tearDown()
    }

    func testSummaryURLMapsWebSocketSchemes() {
        XCTAssertEqual(
            summaryURL(from: URL(string: "ws://192.168.1.8:8000")!).absoluteString,
            "http://192.168.1.8:8000/summary"
        )
        XCTAssertEqual(
            summaryURL(from: URL(string: "wss://example.com/ws")!).absoluteString,
            "https://example.com/summary"
        )
    }

    func testSummarizePostsTEndAndParsesSummaryWithoutBearerWhenTokenMissing() async throws {
        SummaryStubURLProtocol.responseStatus = 200
        SummaryStubURLProtocol.responseBody = Data(
            #"{"summary":"Two people discussed lunch.","model_version":"test","window_seconds":120}"#.utf8
        )

        let client = SummaryClient(
            summaryURL: URL(string: "http://192.168.1.8:8000/summary")!,
            urlSession: Self.stubbedSession()
        )
        let lines = [
            MissedCaptionLine(speaker: "Someone", text: "Want lunch?", tone: nil, tEnd: 12.5)
        ]
        let summary = try await client.summarize(lines, token: nil)

        XCTAssertEqual(summary, "Two people discussed lunch.")
        let request = try XCTUnwrap(SummaryStubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let body = try XCTUnwrap(SummaryStubURLProtocol.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let postedLines = try XCTUnwrap(object["lines"] as? [[String: Any]])
        XCTAssertEqual(postedLines.first?["t_end"] as? Double, 12.5)
        XCTAssertEqual(postedLines.first?["speaker"] as? String, "Someone")
        XCTAssertEqual(postedLines.first?["text"] as? String, "Want lunch?")
    }

    func testSummarizeSetsBearerHeaderOnlyWhenTokenPassed() async throws {
        SummaryStubURLProtocol.responseStatus = 200
        SummaryStubURLProtocol.responseBody = Data(
            #"{"summary":"ok","model_version":"test","window_seconds":120}"#.utf8
        )

        let client = SummaryClient(
            summaryURL: URL(string: "http://example.com/summary")!,
            urlSession: Self.stubbedSession()
        )
        _ = try await client.summarize([], token: "secret-token")

        let request = try XCTUnwrap(SummaryStubURLProtocol.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertNotNil(SummaryStubURLProtocol.lastBody)
    }

    func testSummarizeThrowsOnNon200() async {
        SummaryStubURLProtocol.responseStatus = 503
        SummaryStubURLProtocol.responseBody = Data(#"{"detail":"down"}"#.utf8)

        let client = SummaryClient(
            summaryURL: URL(string: "http://example.com/summary")!,
            urlSession: Self.stubbedSession()
        )
        do {
            _ = try await client.summarize([], token: nil)
            XCTFail("expected non-200 to throw")
        } catch let error as SummaryClientError {
            XCTAssertEqual(error, .httpStatus(503))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private static func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SummaryStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class SummaryStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseStatus = 200
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    static func reset() {
        responseStatus = 200
        responseBody = Data()
        lastRequest = nil
        lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = Self.body(from: request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://example.com/summary")!,
            statusCode: Self.responseStatus,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
