import Foundation

public enum WalkLogWriterError: Error, Equatable { case closed }

/// Appends events to one run file, one unbuffered write per line. A crash loses at most the line being written.
/// Not Sendable: the app uses it from the main actor.
public final class WalkLogWriter {
    public let url: URL
    private var handle: FileHandle?

    /// Creates the file (and intermediate directories) when missing, then opens it for appending.
    public init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        handle = h
    }

    public func append(_ event: WalkLogEvent) throws {
        guard let handle else { throw WalkLogWriterError.closed }
        try handle.write(contentsOf: WalkLogCodec.line(event))
    }

    public func close() {
        try? handle?.close()
        handle = nil
    }

    deinit { try? handle?.close() }
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

    /// "yyyyMMdd-HHmmss-<UUID>.jsonl" in `timeZone`.
    public static func fileName(start: Date, runID: UUID, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
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
