import Foundation

public struct TokenUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// Model choices, kept in one place so they can be swapped (spec 11).
public struct OpenAIModels: Sendable {
    public var story = "gpt-5-mini"
    public var storyReasoningEffort: String? = "low"
    public var speech = "gpt-4o-mini-tts"
    public var voice = "coral"
    public var image = "gpt-image-2.5-flare"

    public init() {}

    public static let current = OpenAIModels()
}
