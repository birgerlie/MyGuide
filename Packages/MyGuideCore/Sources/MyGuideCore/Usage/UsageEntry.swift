import Foundation

public enum UsageKind: String, Sendable, Codable {
    case story, speech, image
}

/// One billable OpenAI call, kept for the usage and cost counter.
public struct UsageEntry: Sendable, Equatable {
    public var date: Date
    public var kind: UsageKind
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    /// Words of text sent to speech synthesis; 0 for other kinds.
    public var words: Int
    /// Images generated; 0 for other kinds.
    public var images: Int

    public init(date: Date, kind: UsageKind, model: String, inputTokens: Int, outputTokens: Int, words: Int, images: Int) {
        self.date = date
        self.kind = kind
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.words = words
        self.images = images
    }
}
