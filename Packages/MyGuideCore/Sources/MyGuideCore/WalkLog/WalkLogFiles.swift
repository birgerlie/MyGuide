import Foundation

public enum WalkLogWriterError: Error, Equatable { case closed }

/// Appends events to one run file, one unbuffered write per line. A crash loses at most the line being written.
/// Not Sendable: the app uses it from the main actor.
public final class WalkLogWriter {
    public let url: URL
    private let file: JSONLinesFile
    private var isClosed = false

    /// Creates the file (and intermediate directories) when missing, then opens it for appending.
    public init(url: URL) throws {
        self.url = url
        file = try JSONLinesFile(url: url)
    }

    public func append(_ event: WalkLogEvent) throws {
        guard !isClosed else { throw WalkLogWriterError.closed }
        try file.append(WalkLogCodec.line(event))
    }

    public func close() {
        isClosed = true
        file.close()
    }
}

public enum WalkLogReader {
    /// Every readable event in order, plus the number of non-blank lines that could not be read
    /// (a line cut short by a crash, or an unknown event).
    public static func read(_ data: Data) -> (events: [WalkLogEvent], unreadable: Int) {
        var events: [WalkLogEvent] = []
        var unreadable = 0
        for piece in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let line = Data(piece)
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { continue }
            if let event = WalkLogCodec.event(from: line) { events.append(event) } else { unreadable += 1 }
        }
        return (events, unreadable)
    }
}

public enum WalkLogStore {
    public static let keep = 20

    /// "yyyyMMdd-HHmmss-<UUID>.jsonl" in UTC, so names sort by start time whatever time zone the phone is in (a run
    /// started after travelling west never sorts older and is never pruned first).
    public static func fileName(start: Date, runID: UUID) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        let stamp = String(format: "%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                           c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return "\(stamp)-\(runID.uuidString).jsonl"
    }

    /// The `.jsonl` files of `directory`, newest first (file names sort by start time).
    public static func runFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Deletes the oldest run files beyond `keep`; never `sparing`.
    public static func prune(in directory: URL, keep: Int = keep, sparing: URL?) throws {
        let spared = sparing?.lastPathComponent
        for file in try runFiles(in: directory).dropFirst(max(keep, 0)) where file.lastPathComponent != spared {
            try FileManager.default.removeItem(at: file)
        }
    }
}
