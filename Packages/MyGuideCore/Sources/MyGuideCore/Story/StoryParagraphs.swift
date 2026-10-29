import Foundation

/// A story text as separate paragraphs, so the screen can put air between them instead of one blank line.
public enum StoryParagraphs {
    /// Splits on line breaks (one or more, with any whitespace between); each paragraph is trimmed and empty ones
    /// are dropped. A text still streaming in keeps its last, unfinished paragraph.
    public static func split(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
