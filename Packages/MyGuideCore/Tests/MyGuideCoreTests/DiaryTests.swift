import Foundation
import SwiftData
import Testing
@testable import MyGuideCore

@MainActor @Suite struct DiaryTests {
    static let oslo = TimeZone(identifier: "Europe/Oslo") ?? .gmt
    static let utc = TimeZone(identifier: "UTC") ?? .gmt
    static let t0 = WalkMemoryTests.t0
    static let trip = UUID()

    let store: MemoryStore
    init() throws {
        store = try WalkMemoryTests.clockedStore(WalkMemoryTests.Clock(Self.t0))
    }

    static func entry(_ id: String, at seconds: TimeInterval, city: String? = nil) -> DiaryEntry {
        DiaryEntry(id: id, kind: .photoStory, time: Date(timeIntervalSince1970: seconds), title: id, placeName: nil,
                   coordinate: nil, firstSentence: nil, city: city, hasPhoto: true)
    }

    /// A photo story at `t` with a grounding address in `city`.
    static func session(_ id: UUID = UUID(), at t: TimeInterval, city: String?, level1: String) -> StorySession {
        StorySession(
            id: id,
            capture: CaptureContext(coordinate: Coordinate(latitude: 48.2, longitude: 16.37), horizontalAccuracy: 5,
                                    heading: nil, headingAccuracy: nil, horizontalFOV: 55,
                                    takenAt: Date(timeIntervalSince1970: t), source: .camera),
            photoJPEG: Data([2]), thumbnailJPEG: Data([1]), language: .english,
            grounding: Grounding(candidates: [], address: city.map { Address(city: $0) }, failedSources: []),
            identified: IdentifiedStory(subject: "Gate", confidence: .likely, matchedCandidateID: nil, title: "Gate title",
                                        era: "E", story: level1),
            levels: [level1])
    }

    static func buzzStory(id: UUID, levels: [String], address: Address?) -> WalkStory {
        let place = Candidate(id: "osm:node/9", name: "Castle", coordinate: .at(north: 100), kind: "historic=castle")
        return WalkStory(id: id, kind: .buzz, place: place, position: .at(north: 5), course: nil, language: .english,
                         title: "Buzz title", levels: levels, createdAt: t0 + 50, address: address, detail: "50 m left")
    }

    func logBuzz(_ story: WalkStory, heardLevel: Int) throws {
        let place = try #require(story.place)
        let buzz = Buzz(id: story.id, place: WalkingPlace(candidate: place, tier: .top), distance: 50, bearing: 0,
                        title: story.title, detail: "50 m left", usedOverride: false)
        try store.recordBuzz(buzz, tripID: Self.trip, at: Self.t0)
        try store.saveWalkStory(story, tripID: Self.trip)
        if heardLevel > 0 {
            try store.setBuzzOutcome(story.id, .heard, deepestLevel: heardLevel, at: Self.t0 + 60)
        }
    }

    // MARK: - Grouping

    @Test func dayKeyIsLocalDate() {
        // 1793140200 = 2026-10-27 22:30 UTC (1793059200 = 2026-10-27 00:00 UTC, + 22.5 h = 81 000 s).
        // Oslo is UTC+1 on 27 Oct 2026 (summer time ended 25 Oct): 23:30 on the 27th. UTC: also the 27th.
        let late = Date(timeIntervalSince1970: 1_793_140_200)
        #expect(Diary.dayKey(late, timeZone: Self.oslo) == "2026-10-27")
        // 1793143800 = 23:30 UTC on the 27th (+ 84 600 s) = 00:30 on the 28th in Oslo, still the 27th in UTC.
        let after = Date(timeIntervalSince1970: 1_793_143_800)
        #expect(Diary.dayKey(after, timeZone: Self.oslo) == "2026-10-28")
        #expect(Diary.dayKey(after, timeZone: Self.utc) == "2026-10-27")
        // Zero padding: 1970-01-05 00:00 UTC = 4 days = 345 600 s.
        #expect(Diary.dayKey(Date(timeIntervalSince1970: 345_600), timeZone: Self.utc) == "1970-01-05")
    }

    @Test func daysGroupByLocalDateNewestFirst() throws {
        // 23:30 Oslo on the 27th = 22:30 UTC = 1793140200; 00:30 Oslo on the 28th = 23:30 UTC = 1793143800.
        // Both are the 27th in UTC, so grouping by Oslo date must split them and by UTC date must not.
        let entries = [Self.entry("a", at: 1_793_140_200), Self.entry("b", at: 1_793_143_800)]
        let oslo = Diary.days(entries, timeZone: Self.oslo)
        #expect(oslo.map(\.id) == ["2026-10-28", "2026-10-27"])
        #expect(oslo.map { $0.entries.map(\.id) } == [["b"], ["a"]])
        // Start of 28 Oct in Oslo = 27 Oct 23:00 UTC = 1793059200 + 82 800 = 1793142000.
        let newest = try #require(oslo.first)
        let oldest = try #require(oslo.last)
        #expect(newest.date == Date(timeIntervalSince1970: 1_793_142_000))
        // Start of 27 Oct in Oslo = 26 Oct 23:00 UTC = 1793059200 - 3 600 = 1793055600.
        #expect(oldest.date == Date(timeIntervalSince1970: 1_793_055_600))
        let utc = Diary.days(entries, timeZone: Self.utc)
        #expect(utc.map(\.id) == ["2026-10-27"])
        #expect(try #require(utc.first).entries.count == 2)
    }

    @Test func noEntriesNoDays() {
        #expect(Diary.days([], timeZone: Self.oslo).isEmpty)
    }

    @Test func entriesOldestFirstWithinDay() throws {
        // All on 1970-01-01 UTC: 3 600 s, 100 s, 100 s. Time order 100, 100, 3 600; the tie goes by id.
        let entries = [Self.entry("c", at: 3_600), Self.entry("b", at: 100), Self.entry("a", at: 100)]
        let days = Diary.days(entries, timeZone: Self.utc)
        #expect(days.count == 1)
        #expect(try #require(days.first).entries.map(\.id) == ["a", "b", "c"])
    }

    @Test func cityIsFirstEntryWithCity() throws {
        // Oldest first: a (100 s, no city), b (200 s, Wien), c (300 s, Graz). The first with a city is Wien,
        // whatever the input order.
        let entries = [Self.entry("c", at: 300, city: "Graz"), Self.entry("a", at: 100),
                       Self.entry("b", at: 200, city: "Wien")]
        #expect(try #require(Diary.days(entries, timeZone: Self.utc).first).city == "Wien")
        #expect(try #require(Diary.days([Self.entry("a", at: 100)], timeZone: Self.utc).first).city == nil)
    }

    // MARK: - Query

    @Test func photoStoryEntry() throws {
        let id = UUID()
        try store.save(Self.session(id, at: 1_000, city: "Wien", level1: "A gate. It is old."))
        let entry = try #require(try store.diaryEntries().first)
        #expect(entry == DiaryEntry(
            id: "capture:\(id.uuidString)", kind: .photoStory, time: Date(timeIntervalSince1970: 1_000),
            title: "Gate title", placeName: "Gate", coordinate: Coordinate(latitude: 48.2, longitude: 16.37),
            firstSentence: "A gate.", city: "Wien", hasPhoto: true))
    }

    @Test func unheardBuzzIsHidden() throws {
        let unheard = UUID(), heard = UUID()
        try logBuzz(Self.buzzStory(id: unheard, levels: ["Prepared."], address: nil), heardLevel: 0)
        try logBuzz(Self.buzzStory(id: heard, levels: ["Heard."], address: nil), heardLevel: 1)
        // A buzz story with no log entry counts as unheard too.
        try store.saveWalkStory(Self.buzzStory(id: UUID(), levels: ["Orphan."], address: nil), tripID: Self.trip)
        let entries = try store.diaryEntries()
        #expect(entries.map(\.id) == ["walk:\(heard.uuidString)"])
    }

    @Test func heardBuzzUsesPlaceCoordinate() throws {
        let id = UUID()
        try logBuzz(Self.buzzStory(id: id, levels: ["Heard. More."], address: Address(city: "Wien")), heardLevel: 1)
        let entry = try #require(try store.diaryEntries().first)
        // The place is 100 m north, the walker 5 m north: the entry takes the place.
        #expect(entry.kind == .buzz && entry.coordinate == .at(north: 100))
        #expect(entry.placeName == "Castle" && entry.title == "Buzz title")
        #expect(entry.firstSentence == "Heard." && entry.city == "Wien" && !entry.hasPhoto)
        #expect(entry.time == Self.t0 + 50)
    }

    @Test func stopUsesStoryPosition() throws {
        let id = UUID()
        let stop = WalkStory(id: id, kind: .stop, place: nil, position: .at(north: 20), course: nil, language: .english,
                             title: "Stop title", levels: ["Square. Big."], createdAt: Self.t0 + 10,
                             address: Address(city: "Wien"), detail: nil)
        try store.saveWalkStory(stop, tripID: Self.trip)
        let entry = try #require(try store.diaryEntries().first)
        #expect(entry.id == "walk:\(id.uuidString)" && entry.kind == .stop)
        #expect(entry.coordinate == .at(north: 20) && entry.placeName == nil)
        #expect(entry.firstSentence == "Square." && entry.city == "Wien" && !entry.hasPhoto)
    }

    @Test func addressNeverLookedUpOrFailedGivesNoCity() throws {
        let unknown = WalkStory(id: UUID(), kind: .stop, place: nil, position: .at(north: 1), course: nil,
                                language: .english, title: "S", levels: ["One."], createdAt: Self.t0,
                                address: nil, addressLookedUp: false, detail: nil)
        let failed = WalkStory(id: UUID(), kind: .stop, place: nil, position: .at(north: 2), course: nil,
                               language: .english, title: "S", levels: ["One."], createdAt: Self.t0,
                               address: nil, addressLookedUp: true, detail: nil)
        try store.saveWalkStory(unknown, tripID: Self.trip)
        try store.saveWalkStory(failed, tripID: Self.trip)
        let entries = try store.diaryEntries()
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.city == nil })
    }

    @Test func libraryPhotoEntry() throws {
        let taken = Date(timeIntervalSince1970: 4_000)
        let withPlace = try #require(try store.importLibraryPhoto(
            jpeg: TestImages.jpeg(width: 100, height: 100), assetIdentifier: "a", takenAt: taken,
            coordinate: Coordinate(latitude: 48.2, longitude: 16.36)))
        let without = try #require(try store.importLibraryPhoto(
            jpeg: TestImages.jpeg(width: 100, height: 100), assetIdentifier: "b", takenAt: taken + 1, coordinate: nil))
        let entries = try store.diaryEntries().sorted { $0.time < $1.time }
        #expect(entries == [
            DiaryEntry(id: "library:\(withPlace.uuidString)", kind: .libraryPhoto, time: taken, title: "",
                       placeName: nil, coordinate: Coordinate(latitude: 48.2, longitude: 16.36), firstSentence: nil,
                       city: nil, hasPhoto: true),
            DiaryEntry(id: "library:\(without.uuidString)", kind: .libraryPhoto, time: taken + 1, title: "",
                       placeName: nil, coordinate: nil, firstSentence: nil, city: nil, hasPhoto: true)])
    }

    @Test func emptyStoreHasNoEntries() throws {
        #expect(try store.diaryEntries().isEmpty)
    }

    @Test func corruptJSONKeepsTheEntryWithoutTheField() throws {
        let captureID = UUID(), buzzID = UUID(), stopID = UUID()
        try store.save(Self.session(captureID, at: 1_000, city: "Wien", level1: "Gate."))
        try logBuzz(Self.buzzStory(id: buzzID, levels: ["Heard."], address: Address(city: "Wien")), heardLevel: 1)
        try store.saveWalkStory(WalkStory(id: stopID, kind: .stop, place: nil, position: .at(north: 20), course: nil,
                                          language: .english, title: "S", levels: ["Stop."], createdAt: Self.t0,
                                          address: Address(city: "Wien"), detail: nil), tripID: Self.trip)
        for capture in try store.context.fetch(FetchDescriptor<CaptureRecord>()) {
            capture.groundingJSON = Data("not json".utf8)
        }
        for walk in try store.context.fetch(FetchDescriptor<WalkStoryRecord>()) {
            walk.addressJSON = Data("not json".utf8)
            if walk.kind == "buzz" { walk.placeJSON = Data("not json".utf8) }
        }
        var corrupt: [String] = []
        let entries = try store.diaryEntries(onCorrupt: { corrupt.append($0) })
        #expect(corrupt.sorted() == [
            "capture:\(captureID.uuidString) groundingJSON", "walk:\(buzzID.uuidString) addressJSON",
            "walk:\(buzzID.uuidString) placeJSON", "walk:\(stopID.uuidString) addressJSON"].sorted())
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0.city == nil })
        let buzz = try #require(entries.first { $0.kind == .buzz })
        #expect(buzz.coordinate == nil && buzz.placeName == "Castle")
        let capture = try #require(entries.first { $0.kind == .photoStory })
        #expect(capture.coordinate == Coordinate(latitude: 48.2, longitude: 16.37))
    }

    @Test func allKindsGroupIntoDays() throws {
        // Capture at 1 000 s and library photo at 1 001 s: 1970-01-01 UTC. Buzz story at t0 + 50 = 1 000 050 s =
        // 11 d (950 400 s) + 49 650 s: 1970-01-12 UTC. Newest day first.
        try store.save(Self.session(at: 1_000, city: "Wien", level1: "Gate."))
        _ = try store.importLibraryPhoto(jpeg: TestImages.jpeg(width: 50, height: 50), assetIdentifier: "x",
                                         takenAt: Date(timeIntervalSince1970: 1_001), coordinate: nil)
        try logBuzz(Self.buzzStory(id: UUID(), levels: ["Heard."], address: nil), heardLevel: 1)
        let days = Diary.days(try store.diaryEntries(), timeZone: Self.utc)
        #expect(days.map(\.id) == ["1970-01-12", "1970-01-01"])
        let first = try #require(days.last), second = try #require(days.first)
        #expect(first.entries.map(\.kind) == [.photoStory, .libraryPhoto])
        #expect(first.city == "Wien" && second.city == nil)
    }

    @Test func onlyBuzzAndStopWalkKindsAreListed() throws {
        let stopID = UUID(), oddID = UUID()
        try store.saveWalkStory(WalkStory(id: stopID, kind: .stop, place: nil, position: .at(north: 1), course: nil,
                                          language: .english, title: "S", levels: ["Stop."], createdAt: Self.t0,
                                          address: nil, detail: nil), tripID: Self.trip)
        try store.saveWalkStory(WalkStory(id: oddID, kind: .stop, place: nil, position: .at(north: 2), course: nil,
                                          language: .english, title: "S", levels: ["Odd."], createdAt: Self.t0,
                                          address: nil, detail: nil), tripID: Self.trip)
        let odd = try #require(try store.context.fetch(FetchDescriptor<WalkStoryRecord>()).first { $0.id == oddID })
        odd.kind = "future"
        var corrupt: [String] = []
        let entries = try store.diaryEntries(onCorrupt: { corrupt.append($0) })
        #expect(entries.map(\.id) == ["walk:\(stopID.uuidString)"])
        #expect(corrupt == ["walk:\(oddID.uuidString) kind"])
    }

    @Test(arguments: [1, 2, 3]) func buzzHeardAtAnyLevelIsListed(level: Int) throws {
        let id = UUID()
        try logBuzz(Self.buzzStory(id: id, levels: ["One.", "Two.", "Three."], address: nil), heardLevel: level)
        #expect(try store.diaryEntries().map(\.id) == ["walk:\(id.uuidString)"])
    }

    // MARK: - Daylight saving

    @Test func twentyFiveHourDayGroupsAsOneDay() throws {
        // Oslo leaves summer time on 2026-10-25 at 01:00 UTC, so the 25th runs from 2026-10-24 22:00 UTC
        // (local 00:00 CEST) to 2026-10-25 23:00 UTC (local 00:00 CET): 25 h.
        // 2026-10-25 00:00 UTC = 1792886400; start = 1792886400 - 2 h = 1792879200; end = 1792886400 + 23 h
        // = 1792886400 + 82 800 = 1792969200.
        let before = Self.entry("before", at: 1_792_879_199)   // 23:59:59 local on the 24th
        let start = Self.entry("start", at: 1_792_879_200)     // 00:00 local on the 25th
        let last = Self.entry("last", at: 1_792_969_199)       // 23:59:59 local on the 25th
        let next = Self.entry("next", at: 1_792_969_200)       // 00:00 local on the 26th
        let days = Diary.days([next, last, start, before], timeZone: Self.oslo)
        #expect(days.map(\.id) == ["2026-10-26", "2026-10-25", "2026-10-24"])
        #expect(days.map { $0.entries.map(\.id) } == [["next"], ["start", "last"], ["before"]])
        // Day start of the 25th = 1792879200.
        #expect(days[1].date == Date(timeIntervalSince1970: 1_792_879_200))
    }

    @Test func twentyThreeHourDayGroupsAsOneDay() throws {
        // Oslo enters summer time on 2026-03-29 at 01:00 UTC: the 29th runs from 2026-03-28 23:00 UTC to
        // 2026-03-29 22:00 UTC: 23 h. 2026-03-29 00:00 UTC = 1774742400; start = 1774742400 - 1 h = 1774738800;
        // end = 1774742400 + 22 h = 1774742400 + 79 200 = 1774821600.
        let before = Self.entry("before", at: 1_774_738_799)
        let start = Self.entry("start", at: 1_774_738_800)
        let last = Self.entry("last", at: 1_774_821_599)
        let next = Self.entry("next", at: 1_774_821_600)
        let days = Diary.days([next, last, start, before], timeZone: Self.oslo)
        #expect(days.map(\.id) == ["2026-03-30", "2026-03-29", "2026-03-28"])
        #expect(days.map { $0.entries.map(\.id) } == [["next"], ["start", "last"], ["before"]])
        #expect(days[1].date == Date(timeIntervalSince1970: 1_774_738_800))
    }
}
