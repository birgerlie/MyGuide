import Foundation
import Testing
@testable import MyGuideCore

@Suite struct ServerSentEventsTests {
    /// Feeds every line and collects the events the parser dispatches.
    static func events(_ lines: [String]) -> [ServerSentEvent] {
        var parser = ServerSentEventParser()
        return lines.compactMap { parser.feed(line: $0) }
    }

    // MARK: - Parser

    @Test func oneEvent() {
        let events = Self.events(["event: response.output_text.delta", #"data: {"delta":"Hi"}"#, ""])
        #expect(events == [ServerSentEvent(event: "response.output_text.delta", data: #"{"delta":"Hi"}"#)])
    }

    @Test func multiLineDataIsJoinedWithNewline() {
        let events = Self.events(["data: first", "data: second", "data:", "data: fourth", ""])
        #expect(events == [ServerSentEvent(event: nil, data: "first\nsecond\n\nfourth")])
    }

    @Test func commentIsIgnored() {
        let events = Self.events([": keep-alive", "event: e", ": in the middle", "data: x", ""])
        #expect(events == [ServerSentEvent(event: "e", data: "x")])
    }

    @Test func eventWithoutBlankLineYieldsNothingUntilTheNextBlankLine() {
        var parser = ServerSentEventParser()
        #expect(parser.feed(line: "event: a") == nil)
        #expect(parser.feed(line: "data: 1") == nil)
        #expect(parser.feed(line: "data: 2") == nil)
        #expect(parser.feed(line: "") == ServerSentEvent(event: "a", data: "1\n2"))
    }

    @Test func eventsAreIndependent() {
        // The second event has no `event:` line, so its type must not carry over from the first.
        let events = Self.events(["event: a", "data: 1", "", "data: 2", ""])
        #expect(events == [ServerSentEvent(event: "a", data: "1"), ServerSentEvent(event: nil, data: "2")])
    }

    @Test func onlyOneLeadingSpaceIsStripped() {
        let events = Self.events(["data:x", "", "data:  y", "", "data", ""])
        #expect(events.map(\.data) == ["x", " y", ""])
    }

    @Test func blankLinesWithoutDataDispatchNothing() {
        // An `event:` line with no data, then a blank line, is discarded per the SSE rules.
        #expect(Self.events(["", "", "event: lonely", "", "id: 7", "retry: 10", ""]).isEmpty)
    }

    @Test func valueKeepsColonsAfterTheFirst() {
        let events = Self.events([#"data: {"a":"b:c"}"#, ""])
        #expect(events.map(\.data) == [#"{"a":"b:c"}"#])
    }

    // MARK: - Line splitter

    @Test func splitterKeepsBlankLinesForEveryLineEnding() {
        // LF, CRLF and a lone CR each end a line; the blank lines that end SSE events must survive.
        let body = Data("event: a\ndata: 1\n\nevent: b\r\ndata: 2\r\n\r\ndata: 3\r\rtail".utf8)
        #expect(ServerSentEventLineSplitter.lines(in: body)
            == ["event: a", "data: 1", "", "event: b", "data: 2", "", "data: 3", "", "tail"])
    }

    @Test func splitterHandlesEmptyAndUnterminatedBodies() {
        #expect(ServerSentEventLineSplitter.lines(in: Data()) == [])
        #expect(ServerSentEventLineSplitter.lines(in: Data("a\n".utf8)) == ["a"])
        #expect(ServerSentEventLineSplitter.lines(in: Data("\n".utf8)) == [""])
        #expect(ServerSentEventLineSplitter.lines(in: Data("a".utf8)) == ["a"])
    }

    @Test func splitterKeepsMultiByteCharactersWhole() {
        #expect(ServerSentEventLineSplitter.lines(in: Data("data: blåbær æøå\n\n".utf8)) == ["data: blåbær æøå", ""])
    }

    // MARK: - HTTPClient default

    @Test func defaultLinesSplitsTheSentBodyAndKeepsBlankLines() async throws {
        let client = SendOnlyHTTPClient(status: 201, body: Data("event: a\r\ndata: 1\r\n\r\n".utf8))
        let request = URLRequest(url: URL(string: "https://example.invalid/x")!)
        let (stream, response) = try await client.lines(request)
        var lines: [String] = []
        for try await line in stream { lines.append(line) }
        #expect(response.statusCode == 201)
        #expect(lines == ["event: a", "data: 1", ""])
    }

    // MARK: - URLSession transport

    @Test func urlSessionLinesKeepBlankLines() async throws {
        // Served through a URLProtocol so the real `URLSession.bytes(for:)` path runs without the network.
        let body = "event: a\ndata: 1\n\nevent: b\r\ndata: 2\r\n\r\n"
        let client = URLSessionHTTPClient(session: CannedURLProtocol.session(status: 200, body: Data(body.utf8)))
        let (stream, response) = try await client.lines(URLRequest(url: URL(string: "https://canned.invalid/sse")!))
        var lines: [String] = []
        for try await line in stream { lines.append(line) }
        #expect(response.statusCode == 200)
        #expect(lines == ["event: a", "data: 1", "", "event: b", "data: 2", ""])
    }

    @Test func urlSessionLinesReturnNon2xxBody() async throws {
        let client = URLSessionHTTPClient(session: CannedURLProtocol.session(status: 401, body: Data("{\n\"error\": {}\n}".utf8)))
        let (stream, response) = try await client.lines(URLRequest(url: URL(string: "https://canned.invalid/sse")!))
        var lines: [String] = []
        for try await line in stream { lines.append(line) }
        #expect(response.statusCode == 401)
        #expect(lines == ["{", #""error": {}"#, "}"])
    }
}

/// Answers every request with a canned status and body; the canned answer travels in a request header,
/// so concurrent tests never share state.
private final class CannedURLProtocol: URLProtocol, @unchecked Sendable {
    static func session(status: Int, body: Data) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CannedURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Canned-Status": String(status), "X-Canned-Body": body.base64EncodedString()]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status = Int(request.value(forHTTPHeaderField: "X-Canned-Status") ?? "") ?? 500
        let body = Data(base64Encoded: request.value(forHTTPHeaderField: "X-Canned-Body") ?? "") ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Implements only `send`, so `lines` comes from the protocol's default implementation.
private struct SendOnlyHTTPClient: HTTPClient {
    let status: Int
    let body: Data
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
