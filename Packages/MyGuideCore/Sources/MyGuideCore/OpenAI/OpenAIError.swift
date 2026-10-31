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
    /// The model this app calls no longer exists (`model_not_found`); only an app update helps.
    case modelRetired
    /// OpenAI's moderation refused the request (`moderation_blocked`, `content_policy…`).
    case contentBlocked
    /// The guide server's free allowance for today is used up (`daily_quota`); never retried.
    case dailyQuota
    /// The guide server's spend cap is reached (`server_budget`); never retried.
    case serverBudget
    /// The guide server wants a device attestation this device cannot give (`attest_required`); only an own key helps.
    case attestUnavailable
}
