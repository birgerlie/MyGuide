import Foundation

/// How one model is billed.
public enum Price: Sendable, Equatable {
    case tokens(inputPerMillion: Double, outputPerMillion: Double)
    /// USD per minute of spoken audio. Spoken at 150 words per minute (spec 6).
    case speechPerMinute(Double)
    case perImage(Double)
}

/// Estimated USD prices per model. `estimatedUSD` is stored at record time, so a later price change
/// does not rewrite history.
public struct PriceTable: Sendable {
    public static let wordsPerMinute = 150.0

    public var asOf: String
    public var prices: [String: Price]

    public init(asOf: String, prices: [String: Price]) {
        self.asOf = asOf
        self.prices = prices
    }

    /// Checked against OpenAI's pricing pages on 2026-10-27.
    /// - gpt-5-mini is deprecated: shutdown 2026-12-11 (replacement gpt-5.6-terra).
    /// - gpt-4o-mini-tts snapshots are removed 2027-01-06. $0.015/min is an estimate (spec 6); OpenAI lists
    ///   $0.60 text in / $12 audio out per 1M tokens.
    /// - gpt-image-1 shut down 2026-10-23; gpt-image-2.5-flare is billed per token ($5 text in / $30 image out per 1M).
    public static let current = PriceTable(asOf: "2026-10-27", prices: [
        "gpt-5-mini": .tokens(inputPerMillion: 0.25, outputPerMillion: 2.00),
        "gpt-4o-mini-tts": .speechPerMinute(0.015),
        "gpt-image-2.5-flare": .tokens(inputPerMillion: 5.00, outputPerMillion: 30.00),
    ])

    /// nil when the model is not in the table, or when its price type does not fit the entry's kind.
    public func estimatedUSD(_ entry: UsageEntry) -> Double? {
        guard let price = prices[entry.model] else { return nil }
        switch (entry.kind, price) {
        case (.story, .tokens) where entry.inputTokens == 0 && entry.outputTokens == 0,
             (.image, .tokens) where entry.inputTokens == 0 && entry.outputTokens == 0:
            // The API reported no tokens: unknown, never $0.
            return nil
        case let (.story, .tokens(input, output)), let (.image, .tokens(input, output)):
            return Double(entry.inputTokens) * input / 1_000_000 + Double(entry.outputTokens) * output / 1_000_000
        case let (.speech, .speechPerMinute(perMinute)):
            return Double(entry.words) / Self.wordsPerMinute * perMinute
        case let (.image, .perImage(each)):
            return Double(entry.images) * each
        default:
            return nil
        }
    }
}
