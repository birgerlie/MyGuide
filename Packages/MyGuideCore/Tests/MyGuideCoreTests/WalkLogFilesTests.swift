import Foundation
import Testing
@testable import MyGuideCore

@Suite struct WalkLogFilesTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("walklog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func event(_ i: Int) -> WalkLogEvent { WalkLogEvent(at: t0 + Double(i), kind: .busy(i % 2 == 0)) }

    @Test func writerAppendsAndReaderReads() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = try WalkLogWriter(url: dir.appendingPathComponent("nested/run.jsonl"))
        for i in 0..<3 { try writer.append(Self.event(i)) }
        writer.close()
        let result = WalkLogReader.read(try Data(contentsOf: writer.url))
        #expect(result.events == [Self.event(0), Self.event(1), Self.event(2)])
        #expect(result.unreadable == 0)
    }

    @Test func reopeningAppendsRatherThanTruncates() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("run.jsonl")
        let first = try WalkLogWriter(url: url)
        try first.append(Self.event(0))
        first.close()
        let second = try WalkLogWriter(url: url)
        try second.append(Self.event(1))
        second.close()
        #expect(WalkLogReader.read(try Data(contentsOf: url)).events == [Self.event(0), Self.event(1)])
    }

    @Test func appendAfterCloseThrows() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = try WalkLogWriter(url: dir.appendingPathComponent("run.jsonl"))
        writer.close()
        #expect(throws: WalkLogWriterError.closed) { try writer.append(Self.event(0)) }
    }

    @Test func truncatedLastLineIsCountedNotFatal() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var data = Data()
        data.append(WalkLogCodec.line(Self.event(0)))
        data.append(WalkLogCodec.line(Self.event(1)))
        data.append(WalkLogCodec.line(Self.event(2)).prefix(10))
        let url = dir.appendingPathComponent("run.jsonl")
        try data.write(to: url)
        let result = WalkLogReader.read(try Data(contentsOf: url))
        // Hand: two complete lines read, the 10-byte stub is one unreadable line.
        #expect(result.events == [Self.event(0), Self.event(1)])
        #expect(result.unreadable == 1)
    }

    @Test func blankLinesIgnored() {
        var data = WalkLogCodec.line(Self.event(0))
        data.append(contentsOf: Data("\n\n".utf8))
        let result = WalkLogReader.read(data)
        #expect(result.events == [Self.event(0)])
        #expect(result.unreadable == 0)
    }

    @Test func fileNameFormat() throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        // Hand: days from epoch to 2026-01-01: 56 * 365 = 20 440, plus 14 leap days (1972...2024) = 20 454.
        // 2026-10-28 is 300 days later (Jan-Sep 273 + 27) = 20 754. Seconds: 20 754 * 86 400 + 13*3600 + 3*60 + 9,
        // which is 2026-10-28 13:03:09 UTC (14:03:09 in Oslo, UTC+1 since CEST ended on 25 Oct). The name is UTC:
        // "20261028-130309", not Oslo's 140309.
        let start = Date(timeIntervalSince1970: 20_754 * 86_400 + 13 * 3600 + 3 * 60 + 9)
        #expect(WalkLogStore.fileName(start: start, runID: id) == "20261028-130309-11111111-2222-3333-4444-555555555555.jsonl")
        // Hand: one second before midnight UTC, 20 754 * 86 400 - 1 = 2026-10-27 23:59:59 UTC (already 00:59:59 on
        // the 28th in Oslo): the UTC date "20261027" and time "235959" are used.
        let lateEvening = Date(timeIntervalSince1970: 20_754 * 86_400 - 1)
        #expect(WalkLogStore.fileName(start: lateEvening, runID: id) == "20261027-235959-11111111-2222-3333-4444-555555555555.jsonl")
    }

    /// A run started later sorts newer even when the phone moved west in between: local names would sort it older.
    @Test func laterRunSortsNewerAfterTravellingWest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Hand: first run at 2026-10-28 13:00:00 UTC (14:00 in Oslo); second run 2 h later at 15:00:00 UTC, which is
        // 11:00 in New York (UTC-4 until 1 Nov). Local names would be 140000 vs 110000, the newer sorting older; UTC
        // names are 130000 and 150000.
        let first = Date(timeIntervalSince1970: 20_754 * 86_400 + 13 * 3600)
        let second = first.addingTimeInterval(2 * 3600)
        let older = WalkLogStore.fileName(start: first, runID: UUID())
        let newer = WalkLogStore.fileName(start: second, runID: UUID())
        #expect(older.hasPrefix("20261028-130000-"))
        #expect(newer.hasPrefix("20261028-150000-"))
        try Self.makeFiles([older, newer], in: dir)
        #expect(try WalkLogStore.runFiles(in: dir).map(\.lastPathComponent) == [newer, older])
    }

    static func makeFiles(_ names: [String], in dir: URL) throws {
        for n in names { try Data("x".utf8).write(to: dir.appendingPathComponent(n)) }
    }

    static func names(_ n: Int) -> [String] { (0..<n).map { String(format: "202610%02d-120000-run.jsonl", $0 + 1) } }

    @Test func pruneKeepsNewest20AndSpares() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = Self.names(23)
        try Self.makeFiles(names, in: dir)
        // Hand: 23 files; the 20 newest are indices 3...22; indices 0, 1, 2 are beyond keep; the oldest (0) is spared,
        // so 1 and 2 go: 23 - 2 = 21 files left.
        try WalkLogStore.prune(in: dir, sparing: dir.appendingPathComponent(names[0]))
        let left = Set(try WalkLogStore.runFiles(in: dir).map(\.lastPathComponent))
        #expect(left.count == 21)
        #expect(left.contains(names[0]))
        #expect(!left.contains(names[1]))
        #expect(!left.contains(names[2]))
        #expect(left.contains(names[3]))
    }

    @Test func pruneWithoutSparingKeeps20() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.makeFiles(Self.names(23), in: dir)
        // Hand: 23 - 20 = 3 deleted.
        try WalkLogStore.prune(in: dir, sparing: nil)
        #expect(try WalkLogStore.runFiles(in: dir).count == 20)
    }

    @Test func pruneFewerThanKeepDeletesNothing() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.makeFiles(Self.names(5), in: dir)
        try WalkLogStore.prune(in: dir, sparing: nil)
        #expect(try WalkLogStore.runFiles(in: dir).count == 5)
    }

    @Test func runFilesNewestFirstOnlyJsonl() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.makeFiles(["20261001-120000-a.jsonl", "20261003-120000-c.jsonl", "20261002-120000-b.jsonl", "notes.txt"], in: dir)
        let names = try WalkLogStore.runFiles(in: dir).map(\.lastPathComponent)
        #expect(names == ["20261003-120000-c.jsonl", "20261002-120000-b.jsonl", "20261001-120000-a.jsonl"])
    }
}
