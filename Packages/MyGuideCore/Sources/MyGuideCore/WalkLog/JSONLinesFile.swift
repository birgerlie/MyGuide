import Foundation

public enum JSONLinesFileError: Error, Equatable { case closed }

/// Appends complete lines to one file, one unbuffered write per line. A crash loses at most the line being written.
/// The walk log and the photo timings file share it. Not Sendable: callers use it from one actor.
public final class JSONLinesFile {
    public let url: URL
    private var handle: FileHandle?

    /// Creates the file (and intermediate directories) when missing, then opens it for appending.
    /// With `startNewLineIfCut`, a last line left without its newline (a write cut short by a crash) is ended first,
    /// so the next line is not glued onto it.
    public init(url: URL, startNewLineIfCut: Bool = false) throws {
        self.url = url
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let h = try FileHandle(forUpdating: url)
        do {
            let end = try h.seekToEnd()
            if startNewLineIfCut, end > 0 {
                try h.seek(toOffset: end - 1)
                if try h.read(upToCount: 1)?.first != 0x0A {
                    try h.seekToEnd()
                    try h.write(contentsOf: Data([0x0A]))
                }
            }
            try h.seekToEnd()
        } catch {
            try? h.close()
            throw error
        }
        handle = h
    }

    /// Writes `line` (which carries its own trailing newline) in one write.
    public func append(_ line: Data) throws {
        guard let handle else { throw JSONLinesFileError.closed }
        try handle.write(contentsOf: line)
    }

    public func close() {
        try? handle?.close()
        handle = nil
    }

    deinit { try? handle?.close() }

    /// Keeps the last `keepLast` complete lines of the file at `url`. Atomic: the kept lines go to a temporary file
    /// in the same directory, which then replaces the original, so a crash leaves either the old or the new file.
    /// A missing file is left alone. A last line without its newline (cut short by a crash) is not a line and is
    /// dropped when the file is rewritten; a file that already has few enough lines is not touched.
    public static func trim(url: URL, keepLast: Int) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        let cut = lines.removeLast()   // after the last newline: empty when the file ends cleanly, else a cut line
        lines.removeAll { $0.isEmpty }
        let keep = max(keepLast, 0)
        guard lines.count > keep || !cut.isEmpty else { return }
        var out = Data()
        for line in lines.suffix(keep) {
            out.append(contentsOf: line)
            out.append(0x0A)
        }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try out.write(to: temp)
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}
