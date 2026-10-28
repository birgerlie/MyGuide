import Foundation

/// Minimal HTTP transport so clients can be tested without the network.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Sends `request` and returns the response head as soon as it arrives, with the body as a stream of lines
    /// (split at LF, CRLF or CR, terminators removed, blank lines kept).
    func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse)
}

extension HTTPClient {
    /// Default for test doubles: sends the whole request, then yields the body's lines.
    public func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let (data, response) = try await send(request)
        return (AsyncThrowingStream(lines: ServerSentEventLineSplitter.lines(in: data)), response)
    }
}

/// URLSession-backed transport. Any `URLError` becomes `OpenAIError.network`
/// (the name is historical; the error is used for all hosts).
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw OpenAIError.malformedResponse }
            return (data, http)
        } catch {
            throw Self.mapped(error)
        }
    }

    /// Streams the body with `URLSession.bytes(for:)`. The lines are split here rather than with `.lines`,
    /// because `AsyncLineSequence` drops empty lines, and the empty line is what ends a server-sent event.
    /// Errors while reading are mapped like `send`'s. Ending the consumer's iteration cancels the transfer.
    public func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw Self.mapped(error)
        }
        let dataTask = bytes.task
        guard let http = response as? HTTPURLResponse else {
            dataTask.cancel()
            throw OpenAIError.malformedResponse
        }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let reader = Task {
                var splitter = ServerSentEventLineSplitter()
                do {
                    for try await byte in bytes {
                        if let line = splitter.feed(byte) { continuation.yield(line) }
                    }
                    if let last = splitter.finish() { continuation.yield(last) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapped(error))
                }
            }
            continuation.onTermination = { @Sendable _ in
                reader.cancel()
                dataTask.cancel()
            }
        }
        return (stream, http)
    }

    /// A cancelled `URLError` becomes `CancellationError`, any other `URLError` becomes `OpenAIError.network`;
    /// everything else passes through.
    private static func mapped(_ error: Error) -> Error {
        guard let urlError = error as? URLError else { return error }
        if urlError.code == .cancelled { return CancellationError() }
        return OpenAIError.network(urlError.localizedDescription)
    }
}
