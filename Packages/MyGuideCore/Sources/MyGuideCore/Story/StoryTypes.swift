import Foundation

public enum StoryLanguage: String, Sendable, Codable, CaseIterable {
    case english = "en"
    case norwegian = "nb"

    /// Language edition code used for Wikipedia hosts.
    public var wikipediaCode: String {
        switch self {
        case .english: "en"
        case .norwegian: "no"
        }
    }

    /// Language name used in prompts.
    public var promptName: String {
        switch self {
        case .english: "English"
        case .norwegian: "Norwegian Bokmål"
        }
    }
}
