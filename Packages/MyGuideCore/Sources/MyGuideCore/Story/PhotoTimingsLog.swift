import Foundation

/// One photo story's timings and when it was taken. No story text, no photo (spec 10).
public struct PhotoTimingsEntry: Sendable, Equatable, Codable {
    public var at: Date
    public var timings: PhotoStoryTimings

    public init(at: Date, timings: PhotoStoryTimings) {
        self.at = at
        self.timings = timings
    }
}

/// `PhotoTimings.jsonl`: one entry per line, newest last, trimmed to the newest `keep` at launch (spec 10, 14.12).
public enum PhotoTimingsLog {
    public static let keep = 500

    public static func append(_ entry: PhotoTimingsEntry, to url: URL) throws {
        var line = try encoder.encode(entry)
        line.append(0x0A)
        let file = try JSONLinesFile(url: url, startNewLineIfCut: true)
        defer { file.close() }
        try file.append(line)
    }

    /// Every readable entry in order; a missing file, blank lines and lines that cannot be read give nothing.
    public static func read(_ url: URL) -> [PhotoTimingsEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap {
            try? decoder.decode(PhotoTimingsEntry.self, from: Data($0))
        }
    }

    /// Keeps the newest `keep` lines.
    public static func trim(_ url: URL) throws {
        try JSONLinesFile.trim(url: url, keepLast: keep)
    }

    /// The middle value; for an even count the lower of the two middle values. Nil for no values.
    public static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[(values.count - 1) / 2]
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            do { return try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) } catch {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date"))
            }
        }
        return d
    }
}
