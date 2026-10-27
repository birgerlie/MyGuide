import Foundation

/// Turns story text into a cached MP3 with OpenAI text-to-speech (spec 8.1.5, 11).
public struct SpeechService: Sendable {
    public static let maxCharactersPerRequest = 4000

    private let openAI: OpenAIClient
    private let models: OpenAIModels
    private let cacheDirectory: URL
    private let now: @Sendable () -> Date

    public init(openAI: OpenAIClient, models: OpenAIModels = .current, cacheDirectory: URL,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.openAI = openAI
        self.models = models
        self.cacheDirectory = cacheDirectory
        self.now = now
    }

    public static func instructions(language: StoryLanguage) -> String {
        let base = "Warm, relaxed and conversational, like a friend telling a story on a walk. Unhurried, about 150 words per minute."
        switch language {
        case .english: return base
        case .norwegian: return base + " Speak Norwegian Bokmål with a natural Norwegian accent."
        }
    }

    /// Splits after `.`, `!` or `?` followed by whitespace, packs sentences greedily (single-space joined)
    /// into chunks of at most `maxCharacters`, and hard-splits a single sentence that is longer than the limit
    /// at the last space before the limit (or at the limit when there is no space).
    public static func chunks(_ text: String, maxCharacters: Int) -> [String] {
        precondition(maxCharacters > 0)
        var pieces: [String] = []
        for sentence in sentences(text) {
            pieces.append(contentsOf: split(sentence, maxCharacters: maxCharacters))
        }
        var result: [String] = []
        var current = ""
        for piece in pieces {
            if current.isEmpty {
                current = piece
            } else if current.count + 1 + piece.count <= maxCharacters {
                current += " " + piece
            } else {
                result.append(current)
                current = piece
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func sentences(_ text: String) -> [String] {
        let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var result: [String] = []
        var start = 0
        var i = 0
        while i < chars.count {
            if ".!?".contains(chars[i]), i + 1 < chars.count, chars[i + 1].isWhitespace {
                result.append(String(chars[start...i]))
                i += 1
                while i < chars.count, chars[i].isWhitespace { i += 1 }
                start = i
            } else {
                i += 1
            }
        }
        if start < chars.count { result.append(String(chars[start...])) }
        return result
    }

    private static func split(_ sentence: String, maxCharacters: Int) -> [String] {
        var rest = Substring(sentence)
        var parts: [String] = []
        while rest.count > maxCharacters {
            let window = rest.prefix(maxCharacters + 1)
            if let space = window.lastIndex(where: { $0.isWhitespace }), space > window.startIndex {
                parts.append(String(rest[..<space]))
                rest = rest[space...].drop(while: { $0.isWhitespace })
            } else {
                let cut = rest.index(rest.startIndex, offsetBy: maxCharacters)
                parts.append(String(rest[..<cut]))
                rest = rest[cut...]
            }
        }
        if !rest.isEmpty { parts.append(String(rest)) }
        return parts
    }

    /// True for an ID3 tag ("ID3") or an MPEG audio frame sync (0xFF, then a byte with the top 3 bits set).
    static func looksLikeMP3(_ data: Data) -> Bool {
        let b = Array(data.prefix(3))
        if b.count == 3, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 { return true }
        return b.count >= 2 && b[0] == 0xFF && (b[1] & 0xE0) == 0xE0
    }

    /// Returns the MP3 file for `text`. A cache hit makes no request and returns a nil usage entry.
    /// Nothing is written unless every chunk succeeded; the file is written atomically.
    public func audioFile(text: String, language: StoryLanguage, cacheKey: String) async throws -> (URL, UsageEntry?) {
        let safeKey = cacheKey.replacingOccurrences(of: "/", with: "_")
        let file = cacheDirectory.appending(path: "\(safeKey)-\(language.rawValue).mp3")
        if let existing = try? Data(contentsOf: file), !existing.isEmpty {
            return (file, nil)
        }
        let parts = Self.chunks(text, maxCharacters: Self.maxCharactersPerRequest)
        guard !parts.isEmpty else { throw OpenAIError.malformedResponse }

        let instructions = Self.instructions(language: language)
        var audio = Data()
        for part in parts {
            try Task.checkCancellation()
            let bytes = try await openAI.speech(model: models.speech, voice: models.voice,
                                                instructions: instructions, text: part)
            // A proxy page or truncated body must never be cached: it would make every Retry fail.
            guard Self.looksLikeMP3(bytes) else { throw OpenAIError.malformedResponse }
            audio.append(bytes)
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try audio.write(to: file, options: .atomic)

        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return (file, UsageEntry(date: now(), kind: .speech, model: models.speech,
                                 inputTokens: 0, outputTokens: 0, words: words, images: 0))
    }
}
