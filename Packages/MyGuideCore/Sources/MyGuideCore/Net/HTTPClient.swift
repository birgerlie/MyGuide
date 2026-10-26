import Foundation

/// Minimal HTTP transport so clients can be tested without the network.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
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
        } catch let error as URLError {
            throw OpenAIError.network(error.localizedDescription)
        }
    }
}
