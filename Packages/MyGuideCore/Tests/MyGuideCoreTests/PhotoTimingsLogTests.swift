import Foundation
import Testing
@testable import MyGuideCore

@Suite struct PhotoTimingsLogTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    static func tempURL() throws -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("timings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("PhotoTimings.jsonl"))
    }

    static func timings(_ i: Int, listAgeS: Int? = nil) -> PhotoStoryTimings {
        PhotoStoryTimings(feedbackMs: i, guessMs: nil, placeSearchMs: i * 2, articleMs: nil, firstTextMs: 5,
                          modelMs: 100 + i, listFresh: i % 2 == 0, listAgeS: listAgeS, articleChars: 0)
    }

    /// Entry i is taken i seconds after t0, so entry 1 is the first of the file.
    static func entry(_ i: Int) -> PhotoTimingsEntry { PhotoTimingsEntry(at: t0 + Double(i), timings: timings(i)) }

    @Test func appendAndReadRoundTrip() throws {
        let (dir, file) = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let entries = [Self.entry(1), PhotoTimingsEntry(at: Self.t0 + 2.25, timings: Self.timings(2, listAgeS: 42))]
        for e in entries { try PhotoTimingsLog.append(e, to: file) }
        #expect(PhotoTimingsLog.read(file) == entries)
    }

    @Test func dateIsIso8601WithFractionalSecondsInUTC() throws {
        let (dir, file) = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 1_000_000 s after the epoch is 1970-01-12T13:46:40Z (11 days = 950 400 s, plus 49 600 s = 13 h 46 min 40 s);
        // plus 0.25 s gives ".250".
        try PhotoTimingsLog.append(PhotoTimingsEntry(at: Self.t0 + 0.25, timings: Self.timings(1)), to: file)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\"at\":\"1970-01-12T13:46:40.250Z\""))
        #expect(text.hasSuffix("\n"))
        #expect(!text.contains("story"))
    }

    @Test func speechTimeRoundTrips() throws {
        let (dir, file) = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        var timings = Self.timings(3)
        timings.speechMs = 1234
        let entry = PhotoTimingsEntry(at: Self.t0, timings: timings)
        try PhotoTimingsLog.append(entry, to: file)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("\"speechMs\":1234"))
        #expect(PhotoTimingsLog.read(file) == [entry])
    }

    @Test func lineWrittenBeforeSpeechTimeReadsAsNil() throws {
        let (dir, file) = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A line as the previous version wrote it: no "speechMs" key. Its values are timings(1): feedback 1, search
        // 1 × 2 = 2, first text 5, model 100 + 1 = 101, fresh 1 % 2 == 0 → false, no list age, 0 article characters.
        let old = #"{"at":"1970-01-12T13:46:40.000Z","timings":{"articleChars":0,"feedbackMs":1,"firstTextMs":5,"listFresh":false,"modelMs":101,"placeSearchMs":2}}"#
        try Data((old + "\n").utf8).write(to: file)
        let entries = PhotoTimingsLog.read(file)
        #expect(entries.count == 1)
        #expect(entries.first?.timings == Self.timings(1))
        #expect(entries.first?.timings.speechMs == nil)
    }

    @Test func readOfMissingFileIsEmpty() throws {
        let (dir, file) = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(PhotoTimingsLog.read(file).isEmpty)
    }

    @Test func readSkipsUnreadableAndBlankLines() throws {
        let (dir, file) = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        try PhotoTimingsLog.append(Self.entry(1), to: file)
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd()
        try h.write(contentsOf: Data("garbage\n\n{\"at\":\"nope\"}\n".utf8))
        try h.close()
        try PhotoTimingsLog.append(Self.entry(2), to: file)
        #expect(PhotoTimingsLog.read(file) == [Self.entry(1), Self.entry(2)])
    }

    @Test func trimKeepsNewest500() throws {
        let (dir, file) = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 502 entries numbered 1...502; the newest 500 are 3...502.
        for i in 1...502 { try PhotoTimingsLog.append(Self.entry(i), to: file) }
        try PhotoTimingsLog.trim(file)
        let kept = PhotoTimingsLog.read(file)
        #expect(kept.count == 500)
        #expect(kept.first == Self.entry(3))
        #expect(kept.last == Self.entry(502))
        // No temp file is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["PhotoTimings.jsonl"])
    }

    @Test func trimBelowLimitChangesNothing() throws {
        let (dir, file) = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 1...3 { try PhotoTimingsLog.append(Self.entry(i), to: file) }
        let before = try Data(contentsOf: file)
        try PhotoTimingsLog.trim(file)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func trimOfMissingFileIsANoOp() throws {
        let (dir, file) = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        try PhotoTimingsLog.trim(file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func trimDropsATruncatedLastLine() throws {
        let (dir, file) = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 1...4 { try PhotoTimingsLog.append(Self.entry(i), to: file) }
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd()
        try h.write(contentsOf: Data("{\"at\":\"1970-01-12T13:4".utf8))
        try h.close()
        try JSONLinesFile.trim(url: file, keepLast: 2)
        // The cut line is not a line; the two newest complete ones remain, and the file ends with a newline.
        #expect(PhotoTimingsLog.read(file) == [Self.entry(3), Self.entry(4)])
        #expect(try Data(contentsOf: file).last == 0x0A)
    }

    @Test func appendAfterATruncatedLineStartsANewLine() throws {
        let (dir, file) = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        try PhotoTimingsLog.append(Self.entry(1), to: file)
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd()
        try h.write(contentsOf: Data("{\"at\":\"1970".utf8))
        try h.close()
        try PhotoTimingsLog.append(Self.entry(2), to: file)
        #expect(PhotoTimingsLog.read(file) == [Self.entry(1), Self.entry(2)])
    }

    @Test func trimWithKeepZeroEmptiesTheFile() throws {
        let (dir, file) = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 1...3 { try PhotoTimingsLog.append(Self.entry(i), to: file) }
        try JSONLinesFile.trim(url: file, keepLast: 0)
        #expect(try Data(contentsOf: file).isEmpty)
    }

    @Test func medianValues() {
        #expect(PhotoTimingsLog.median([]) == nil)
        #expect(PhotoTimingsLog.median([5]) == 5)
        // [1, 9, 3] sorted is [1, 3, 9]; index (3-1)/2 = 1 gives 3.
        #expect(PhotoTimingsLog.median([1, 9, 3]) == 3)
        // [4, 1, 3, 2] sorted is [1, 2, 3, 4]; index (4-1)/2 = 1 (integer division) gives the lower middle, 2.
        #expect(PhotoTimingsLog.median([4, 1, 3, 2]) == 2)
        // [7, 7] gives 7; unsorted input is not mutated in meaning.
        #expect(PhotoTimingsLog.median([7, 7]) == 7)
    }

    @Test func jsonLinesFileAppendAfterCloseThrows() throws {
        let (dir, file) = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = try JSONLinesFile(url: file)
        f.close()
        #expect(throws: JSONLinesFileError.closed) { try f.append(Data("x\n".utf8)) }
    }
}
