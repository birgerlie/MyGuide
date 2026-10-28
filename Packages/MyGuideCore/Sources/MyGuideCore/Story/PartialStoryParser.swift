import Foundation

/// What can be read so far from a first-story JSON document that is still streaming in.
public struct PartialFirstStory: Sendable, Equatable {
    public var subject: String?
    public var confidence: String?
    public var matchedCandidateID: String?
    public var title: String?
    public var era: String?
    /// May be incomplete while the story is still growing.
    public var story: String?

    public init(
        subject: String? = nil, confidence: String? = nil, matchedCandidateID: String? = nil,
        title: String? = nil, era: String? = nil, story: String? = nil
    ) {
        self.subject = subject
        self.confidence = confidence
        self.matchedCandidateID = matchedCandidateID
        self.title = title
        self.era = era
        self.story = story
    }
}

/// Incremental, tolerant reader for the streamed first-story JSON object.
///
/// - A string field counts once its closing quote has arrived; `story` is also reported
///   while it grows, with the escapes decoded so far.
/// - An escape (or half of a UTF-16 surrogate pair) that is not complete is held back.
/// - Property order does not matter; unknown keys, and known keys with a value of the
///   wrong type, are skipped. `matchedCandidateID: null` gives nil.
/// - Never throws. Malformed input freezes the state it had reached.
///
/// Each scalar is processed exactly once, so feeding is linear in the total input.
public struct PartialStoryParser: Sendable {
    private enum Field { case subject, confidence, matchedCandidateID, title, era, story }

    private enum State: Sendable {
        case start               // before the opening brace
        case beforeKey           // after `{` or `,`
        case inKey
        case afterKey            // expecting `:`
        case beforeValue
        case inField(Field)      // inside the string value of a known field
        case bare                // a bare literal or number (e.g. null, true, 12)
        case skipping            // skipping a value we do not read
        case afterValue          // expecting `,` or `}`
        case done                // after the closing brace
        case failed
    }

    private var state = State.start
    private var result = PartialFirstStory()
    private var string = JSONStringDecoder()
    private var key: Field?          // the field the current value belongs to, if known
    private var bareText = ""
    // Skipping state.
    private var depth = 0
    private var skipInString = false
    private var skipEscaped = false

    public init() {}

    /// Feeds the next piece of the stream and returns the state after all chunks so far.
    public mutating func append(_ chunk: String) -> PartialFirstStory {
        for scalar in chunk.unicodeScalars { consume(scalar) }
        return result
    }

    private static func isSpace(_ s: Unicode.Scalar) -> Bool {
        s == " " || s == "\n" || s == "\r" || s == "\t"
    }

    private static func field(named name: String) -> Field? {
        switch name {
        case "subject": .subject
        case "confidence": .confidence
        case "matchedCandidateID": .matchedCandidateID
        case "title": .title
        case "era": .era
        case "story": .story
        default: nil
        }
    }

    private mutating func fail() { state = .failed }

    private mutating func consume(_ c: Unicode.Scalar) {
        switch state {
        case .failed, .done:
            return
        case .start:
            if Self.isSpace(c) { return }
            if c == "{" { state = .beforeKey } else { fail() }
        case .beforeKey:
            if Self.isSpace(c) { return }
            if c == "\"" { string.reset(); state = .inKey }
            else if c == "}" { state = .done }
            else { fail() }
        case .inKey:
            switch string.feed(c) {
            case .more: break
            case .closed:
                key = Self.field(named: string.text)
                state = .afterKey
            case .malformed: fail()
            }
        case .afterKey:
            if Self.isSpace(c) { return }
            if c == ":" { state = .beforeValue } else { fail() }
        case .beforeValue:
            if Self.isSpace(c) { return }
            beginValue(c)
        case .inField(let field):
            switch string.feed(c) {
            case .more:
                if field == .story { result.story = string.text }
            case .closed:
                store(field, string.text)
                state = .afterValue
            case .malformed: fail()
            }
        case .bare:
            if Self.isSpace(c) || c == "," || c == "}" {
                if key == .matchedCandidateID, bareText == "null" { result.matchedCandidateID = nil }
                state = .afterValue
                consume(c)
            } else {
                bareText.unicodeScalars.append(c)
            }
        case .skipping:
            skip(c)
        case .afterValue:
            if Self.isSpace(c) { return }
            if c == "," { state = .beforeKey }
            else if c == "}" { state = .done }
            else { fail() }
        }
    }

    private mutating func beginValue(_ c: Unicode.Scalar) {
        switch c {
        case "\"":
            if let key {
                string.reset()
                state = .inField(key)
                if key == .story { result.story = "" }
            } else {
                beginSkipping(opening: c)
            }
        case "{", "[":
            beginSkipping(opening: c)
        case "}", "]", ",", ":":
            fail()
        default:
            bareText = String(Character(c))
            state = .bare
        }
    }

    private mutating func beginSkipping(opening c: Unicode.Scalar) {
        depth = 0
        skipInString = false
        skipEscaped = false
        state = .skipping
        skip(c)
    }

    /// Skips one string, object or array, tracking nesting and string escapes.
    private mutating func skip(_ c: Unicode.Scalar) {
        if skipInString {
            if skipEscaped { skipEscaped = false }
            else if c == "\\" { skipEscaped = true }
            else if c == "\"" {
                skipInString = false
                if depth == 0 { state = .afterValue }
            }
            return
        }
        switch c {
        case "\"":
            skipInString = true
        case "{", "[":
            depth += 1
        case "}", "]":
            depth -= 1
            if depth == 0 { state = .afterValue } else if depth < 0 { fail() }
        default:
            break
        }
    }

    private mutating func store(_ field: Field, _ value: String) {
        switch field {
        case .subject: result.subject = value
        case .confidence: result.confidence = value
        case .matchedCandidateID: result.matchedCandidateID = value
        case .title: result.title = value
        case .era: result.era = value
        case .story: result.story = value
        }
    }
}

/// Decodes the body of one JSON string a scalar at a time. An escape that is not complete,
/// and a high surrogate still waiting for its low half, are held back from `text`.
private struct JSONStringDecoder: Sendable {
    enum Step { case more, closed, malformed }
    private enum Escape { case none, backslash, hex(digits: Int, value: UInt32) }

    private(set) var text = ""
    private var escape = Escape.none
    private var highSurrogate: UInt32?

    mutating func reset() {
        text = ""
        escape = .none
        highSurrogate = nil
    }

    mutating func feed(_ c: Unicode.Scalar) -> Step {
        switch escape {
        case .none:
            if c == "\\" { escape = .backslash; return .more }
            if c == "\"" { flushHighSurrogate(); return .closed }
            emit(c)
            return .more
        case .backslash:
            escape = .none
            switch c {
            case "\"": emit("\"")
            case "\\": emit("\\")
            case "/": emit("/")
            case "b": emit("\u{08}")
            case "f": emit("\u{0C}")
            case "n": emit("\n")
            case "r": emit("\r")
            case "t": emit("\t")
            case "u": escape = .hex(digits: 0, value: 0)
            default: return .malformed
            }
            return .more
        case .hex(let digits, let value):
            guard let nibble = Character(c).hexDigitValue else { return .malformed }
            let next = value << 4 | UInt32(nibble)
            if digits + 1 < 4 {
                escape = .hex(digits: digits + 1, value: next)
            } else {
                escape = .none
                emitCodeUnit(next)
            }
            return .more
        }
    }

    private mutating func emit(_ c: Unicode.Scalar) {
        flushHighSurrogate()
        text.unicodeScalars.append(c)
    }

    private mutating func flushHighSurrogate() {
        if highSurrogate != nil {
            highSurrogate = nil
            text.unicodeScalars.append("\u{FFFD}")
        }
    }

    private mutating func emitCodeUnit(_ unit: UInt32) {
        if let high = highSurrogate {
            highSurrogate = nil
            if (0xDC00...0xDFFF).contains(unit) {
                let scalar = 0x10000 + ((high - 0xD800) << 10) + (unit - 0xDC00)
                text.unicodeScalars.append(Unicode.Scalar(scalar) ?? "\u{FFFD}")
                return
            }
            text.unicodeScalars.append("\u{FFFD}")
        }
        if (0xD800...0xDBFF).contains(unit) {
            highSurrogate = unit
        } else if (0xDC00...0xDFFF).contains(unit) {
            text.unicodeScalars.append("\u{FFFD}")
        } else {
            text.unicodeScalars.append(Unicode.Scalar(unit) ?? "\u{FFFD}")
        }
    }
}
