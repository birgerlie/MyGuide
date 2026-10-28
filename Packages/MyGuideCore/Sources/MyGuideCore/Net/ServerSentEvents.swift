import Foundation

/// One dispatched server-sent event. `event` is nil when the event had no (or an empty) `event:` field.
public struct ServerSentEvent: Sendable, Equatable {
    public var event: String?
    public var data: String

    public init(event: String?, data: String) {
        self.event = event
        self.data = data
    }
}

/// Line-by-line parser for the `text/event-stream` format (WHATWG HTML, "Server-sent events"):
/// - `event:` sets the event type, `data:` appends a data line (several are joined with "\n");
/// - one space after the colon is stripped, a line without a colon is a field with an empty value;
/// - a line starting with ":" is a comment;
/// - a blank line ends the event; it is dispatched only if it had at least one `data:` line;
/// - `id:`, `retry:` and unknown fields are ignored (nothing here reconnects).
/// An event that never gets its blank line is never dispatched.
public struct ServerSentEventParser: Sendable {
    private var eventType: String?
    private var dataLines: [String] = []

    public init() {}

    /// Feeds one line, without its line terminator. Returns the event a blank line completes.
    public mutating func feed(line: String) -> ServerSentEvent? {
        if line.isEmpty {
            defer { eventType = nil; dataLines = [] }
            guard !dataLines.isEmpty else { return nil }
            return ServerSentEvent(event: eventType, data: dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = line[...]
            value = ""
        }
        switch field {
        case "event":
            eventType = value.isEmpty ? nil : String(value)
        case "data":
            dataLines.append(String(value))
        default:
            break
        }
        return nil
    }
}

/// Splits a byte stream into lines at LF, CRLF or a lone CR, as server-sent events require.
/// Unlike Foundation's `AsyncLineSequence` (`bytes.lines`), which silently drops empty lines,
/// this keeps them: the blank line is what ends an SSE event.
struct ServerSentEventLineSplitter: Sendable {
    private var buffer: [UInt8] = []
    private var lastWasCR = false

    /// Feeds one byte; returns a line when this byte ends one.
    mutating func feed(_ byte: UInt8) -> String? {
        switch byte {
        case 0x0A: // LF
            if lastWasCR {
                lastWasCR = false // second half of CRLF; the line was already returned at CR
                return nil
            }
            return takeLine()
        case 0x0D: // CR
            lastWasCR = true
            return takeLine()
        default:
            lastWasCR = false
            buffer.append(byte)
            return nil
        }
    }

    /// The trailing line of a stream that did not end with a line terminator, if any.
    mutating func finish() -> String? {
        buffer.isEmpty ? nil : takeLine()
    }

    private mutating func takeLine() -> String {
        // Line terminators are ASCII and never occur inside a UTF-8 multi-byte sequence, so each line decodes whole.
        defer { buffer.removeAll(keepingCapacity: true) }
        return String(decoding: buffer, as: UTF8.self)
    }

    /// All lines of a complete body.
    static func lines(in data: Data) -> [String] {
        var splitter = ServerSentEventLineSplitter()
        var lines = data.compactMap { splitter.feed($0) }
        if let last = splitter.finish() { lines.append(last) }
        return lines
    }
}

extension AsyncThrowingStream where Element == String, Failure == Error {
    /// A stream that yields `lines` and finishes.
    init(lines: [String]) {
        self.init { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
}
