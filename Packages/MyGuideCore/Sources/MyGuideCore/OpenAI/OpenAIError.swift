import Foundation

public enum OpenAIError: Error, Equatable, Sendable {
    case missingAPIKey
    case invalidAPIKey
    case quotaExceeded
    case rateLimited(String)
    case server(Int)
    case refused(String)
    case malformedResponse
    case network(String)
}
