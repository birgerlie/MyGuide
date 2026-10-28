import Foundation
import Testing
@testable import MyGuideCore

@Suite struct DayStoryPagesTests {
    static let a = "library:00000000-0000-0000-0000-00000000000A"
    static let b = "capture:00000000-0000-0000-0000-00000000000B"
    static let c = "library:00000000-0000-0000-0000-00000000000C"
    static let t = Date(timeIntervalSince1970: 1_800_000_000)

    static func story(summary: String = "A good walk.", captions: [String: String] = [:], photoIDs: [String],
                      totalPhotos: Int) -> DayStory {
        DayStory(dayKey: "2026-10-28", createdAt: t, language: .english, summary: summary, captions: captions,
                 photoIDs: photoIDs, totalPhotos: totalPhotos)
    }

    @Test func pagesFollowTheStoryOrderWithCaptionsAndTimes() {
        let story = Self.story(captions: [Self.a: "Fortress gate.", Self.b: "Cathedral roof.", Self.c: "Harbour."],
                               photoIDs: [Self.b, Self.a, Self.c], totalPhotos: 3)
        let times = [Self.a: Self.t + 10, Self.b: Self.t + 20, Self.c: Self.t + 30]
        let pages = DayStoryPages(story: story, photoTimes: times)
        #expect(pages.summary == "A good walk.")
        #expect(pages.photos == [
            DayStoryPages.Photo(id: Self.b, time: Self.t + 20, caption: "Cathedral roof."),
            DayStoryPages.Photo(id: Self.a, time: Self.t + 10, caption: "Fortress gate."),
            DayStoryPages.Photo(id: Self.c, time: Self.t + 30, caption: "Harbour."),
        ])
        // Every photo of the day was sent: 3 sent of 3, so no note.
        #expect(pages.countNote == nil)
    }

    @Test func aPhotoNoLongerKeptDropsOutAndTheRestKeepTheirOrder() {
        let story = Self.story(captions: [Self.a: "Gone.", Self.b: "Kept B.", Self.c: "Kept C."],
                               photoIDs: [Self.a, Self.b, Self.c], totalPhotos: 3)
        let pages = DayStoryPages(story: story, photoTimes: [Self.b: Self.t, Self.c: Self.t + 1])
        #expect(pages.photos.map(\.id) == [Self.b, Self.c])
        #expect(pages.photos.compactMap(\.caption) == ["Kept B.", "Kept C."])
    }

    @Test func noPhotoLeftKeepsTheSummaryPage() {
        let story = Self.story(captions: [Self.a: "Gone."], photoIDs: [Self.a], totalPhotos: 1)
        let pages = DayStoryPages(story: story, photoTimes: [:])
        #expect(pages.photos.isEmpty)
        #expect(pages.summary == "A good walk.")
    }

    @Test func missingOrBlankCaptionsShowNoCaptionAndOthersAreTrimmed() {
        let story = Self.story(captions: [Self.b: "  \n ", Self.c: "  Harbour at dusk.\n"],
                               photoIDs: [Self.a, Self.b, Self.c], totalPhotos: 3)
        let times = [Self.a: Self.t, Self.b: Self.t, Self.c: Self.t]
        let pages = DayStoryPages(story: story, photoTimes: times)
        #expect(pages.photos.map(\.caption) == [nil, nil, "Harbour at dusk."])
    }

    @Test func aRepeatedPhotoIDGetsOnePage() {
        let story = Self.story(photoIDs: [Self.a, Self.b, Self.a], totalPhotos: 2)
        let pages = DayStoryPages(story: story, photoTimes: [Self.a: Self.t, Self.b: Self.t])
        #expect(pages.photos.map(\.id) == [Self.a, Self.b])
    }

    @Test func summaryIsTrimmed() {
        let pages = DayStoryPages(story: Self.story(summary: "\n  We walked.  ", photoIDs: [], totalPhotos: 0),
                                  photoTimes: [:])
        #expect(pages.summary == "We walked.")
    }

    @Test func countNoteWhenPhotosWereLeftOut() {
        let ids = (0..<12).map { "library:00000000-0000-0000-0000-0000000000\(10 + $0)" }
        // 12 ids sent, 20 photos that day: 20 > 12, so "12 of 20 photos".
        let pages = DayStoryPages(story: Self.story(photoIDs: ids, totalPhotos: 20), photoTimes: [:])
        #expect(pages.countNote == "12 of 20 photos")
        // 2 sent of 3 (one unreadable): 3 > 2, so "2 of 3 photos", counted from the story even when some
        // pages have since dropped out (only one photo is still kept here).
        let fewer = DayStoryPages(story: Self.story(photoIDs: [Self.a, Self.b], totalPhotos: 3),
                                  photoTimes: [Self.a: Self.t])
        #expect(fewer.countNote == "2 of 3 photos")
    }

    @Test(arguments: [(2, 2), (3, 2)])
    func noCountNoteWhenNothingWasLeftOut(sent: Int, total: Int) {
        // total == sent (2 of 2) and a record claiming fewer photos than it sent (3 of 2) both read as complete.
        let ids = [Self.a, Self.b, Self.c].prefix(sent)
        let pages = DayStoryPages(story: Self.story(photoIDs: Array(ids), totalPhotos: total), photoTimes: [:])
        #expect(pages.countNote == nil)
    }
}

@Suite struct DiaryPhotoIDTests {
    static let uuid = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")

    @Test func captureAndLibraryIDsParse() throws {
        let uuid = try #require(Self.uuid)
        #expect(DiaryPhotoID("capture:00000000-0000-0000-0000-00000000000A") == .capture(uuid))
        #expect(DiaryPhotoID("library:00000000-0000-0000-0000-00000000000A") == .library(uuid))
        #expect(DiaryPhotoID("library:\(uuid.uuidString.lowercased())") == .library(uuid))
    }

    @Test(arguments: ["walk:00000000-0000-0000-0000-00000000000A", "library:not-a-uuid", "library:", "capture",
                      "00000000-0000-0000-0000-00000000000A", "", "Library:00000000-0000-0000-0000-00000000000A"])
    func otherIDsDoNotParse(id: String) {
        #expect(DiaryPhotoID(id) == nil)
    }
}

@Suite struct DiaryDayKeyDateTests {
    static let oslo = TimeZone(identifier: "Europe/Oslo") ?? .gmt
    static let utc = TimeZone(identifier: "UTC") ?? .gmt

    static func iso(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    @Test func startOfDayInTheGivenTimeZone() throws {
        // Oslo in winter is UTC+1: midnight 15 Jan local is 23:00 UTC on 14 Jan.
        #expect(Diary.startOfDay(dayKey: "2026-01-15", timeZone: Self.oslo) == (try Self.iso("2026-01-14T23:00:00Z")))
        // 25 Oct 2026 is the DST change, at 03:00 local, so midnight is still UTC+2: 22:00 UTC on 24 Oct.
        #expect(Diary.startOfDay(dayKey: "2026-10-25", timeZone: Self.oslo) == (try Self.iso("2026-10-24T22:00:00Z")))
        // UTC: midnight is 00:00 UTC.
        #expect(Diary.startOfDay(dayKey: "2026-10-28", timeZone: Self.utc) == (try Self.iso("2026-10-28T00:00:00Z")))
    }

    @Test func roundTripsWithDayKey() throws {
        let start = try #require(Diary.startOfDay(dayKey: "2024-02-29", timeZone: Self.oslo))
        #expect(Diary.dayKey(start, timeZone: Self.oslo) == "2024-02-29")
    }

    @Test(arguments: ["2026-02-30", "2025-02-29", "2026-13-01", "2026-00-10", "2026-10-28T", "26-10-28",
                      "2026-1-28", "2026/10/28", "", "yyyy-MM-dd", "+026-10-28"])
    func invalidKeysGiveNil(key: String) {
        #expect(Diary.startOfDay(dayKey: key, timeZone: Self.utc) == nil)
    }
}
