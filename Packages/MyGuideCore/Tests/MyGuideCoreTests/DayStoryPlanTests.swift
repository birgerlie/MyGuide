import Foundation
import Testing
@testable import MyGuideCore

@Suite struct DayStoryPlanTests {
    static let oslo = TimeZone(identifier: "Europe/Oslo") ?? .gmt
    /// 1793185200 = 2026-10-28 11:00 UTC = 12:00 in Oslo (CET, UTC+1 after 25 October).
    static let noon = Date(timeIntervalSince1970: 1_793_185_200)

    static func event(_ id: String, _ kind: DiaryEntry.Kind = .buzz, at seconds: TimeInterval,
                      coordinate: Coordinate? = nil, title: String = "Title", place: String? = nil,
                      sentence: String? = nil) -> DiaryEntry {
        DiaryEntry(id: id, kind: kind, time: noon + seconds, title: title, placeName: place, coordinate: coordinate,
                   firstSentence: sentence, city: nil, hasPhoto: kind == .photoStory)
    }

    static func library(_ id: String, at seconds: TimeInterval, coordinate: Coordinate? = nil) -> DiaryEntry {
        DiaryEntry(id: "library:\(id)", kind: .libraryPhoto, time: noon + seconds, title: "", placeName: nil,
                   coordinate: coordinate, firstSentence: nil, city: nil, hasPhoto: true)
    }

    static func photo(at seconds: TimeInterval, coordinate: Coordinate? = nil) -> DayStoryPhoto {
        DayStoryPhoto(id: "library:p", time: noon + seconds, coordinate: coordinate, storyTitle: nil)
    }

    /// The day's date is midnight in Oslo: noon − 12 h = 1793142000.
    static func day(_ entries: [DiaryEntry]) -> DiaryDay {
        DiaryDay(id: "2026-10-28", date: noon - 43_200, city: "Oslo",
                 entries: entries.sorted { ($0.time, $0.id) < ($1.time, $1.id) })
    }

    // MARK: - Matching

    @Test func matchPicksSmallestGapWithinWindow() {
        let photo = Self.photo(at: 0)
        // Gaps 300 s and 120 s: the smaller wins, whatever the list order.
        let before = Self.event("walk:a", at: -300)
        let after = Self.event("walk:b", at: 120)
        #expect(DayStoryPlan.match(photo, events: [before, after]) == after)
        #expect(DayStoryPlan.match(photo, events: [after, before]) == after)
        // Boundaries: 600 s either side is inside the window, 601 s is outside.
        #expect(DayStoryPlan.match(photo, events: [Self.event("walk:c", at: 600)])?.id == "walk:c")
        #expect(DayStoryPlan.match(photo, events: [Self.event("walk:d", at: -600)])?.id == "walk:d")
        #expect(DayStoryPlan.match(photo, events: [Self.event("walk:e", at: 601)]) == nil)
        #expect(DayStoryPlan.match(photo, events: [Self.event("walk:f", at: -601)]) == nil)
        #expect(DayStoryPlan.match(photo, events: []) == nil)
        // Equal gaps: the earlier event.
        let early = Self.event("walk:g", at: -120)
        let late = Self.event("walk:h", at: 120)
        #expect(DayStoryPlan.match(photo, events: [late, early]) == early)
        #expect(DayStoryPlan.match(photo, events: [early, late]) == early)
    }

    @Test func matchRequiresDistanceWhenBothHavePositions() {
        let photo = Self.photo(at: 0, coordinate: .at())
        // `.at(north: d)` is d metres from `.at()` by haversine (150 m computes as 150.00000000000003, one ulp over,
        // which the match's micrometre slack absorbs): 150 m is inside, 151 m outside.
        #expect(DayStoryPlan.match(photo, events: [Self.event("walk:a", at: 0, coordinate: .at(north: 150))])?.id == "walk:a")
        #expect(DayStoryPlan.match(photo, events: [Self.event("walk:b", at: 0, coordinate: .at(north: 151))]) == nil)
        // The nearer-in-time event is too far away; the later one within 150 m wins.
        let tooFar = Self.event("walk:c", at: 60, coordinate: .at(east: 151))
        let close = Self.event("walk:d", at: 300, coordinate: .at(east: 100))
        #expect(DayStoryPlan.match(photo, events: [tooFar, close]) == close)
    }

    @Test func matchByTimeOnlyWithoutPosition() {
        // 10 km apart, but one side has no position: time alone decides.
        let noPosition = Self.photo(at: 0)
        let far = Self.event("walk:a", at: 30, coordinate: .at(north: 10_000))
        #expect(DayStoryPlan.match(noPosition, events: [far]) == far)
        let placed = Self.photo(at: 0, coordinate: .at())
        let unplaced = Self.event("walk:b", at: 30)
        #expect(DayStoryPlan.match(placed, events: [unplaced]) == unplaced)
        // Still bound by the window.
        #expect(DayStoryPlan.match(noPosition, events: [Self.event("walk:c", at: 601)]) == nil)
    }

    // MARK: - Cap

    static func photos(_ n: Int) -> [DayStoryPhoto] {
        (0..<n).map { DayStoryPhoto(id: "library:\($0)", time: noon + Double($0) * 60, coordinate: nil, storyTitle: nil) }
    }

    @Test func capKeepsFirstAndLastEvenlySpread() {
        // n = 30, cap = 12: index i·29/11 rounded, i = 0…11:
        // 0 → 0; 29/11 = 2.636 → 3; 58/11 = 5.273 → 5; 87/11 = 7.909 → 8; 116/11 = 10.545 → 11; 145/11 = 13.182 → 13;
        // 174/11 = 15.818 → 16; 203/11 = 18.455 → 18; 232/11 = 21.091 → 21; 261/11 = 23.727 → 24; 290/11 = 26.364 → 26;
        // 319/11 = 29 → 29.
        let thirty = Self.photos(30)
        let chosen = DayStoryPlan.choose(thirty, cap: 12)
        #expect(chosen.map(\.id) == [0, 3, 5, 8, 11, 13, 16, 18, 21, 24, 26, 29].map { "library:\($0)" })
        // n = 13, cap = 12: i·12/11 rounded: 0, 1.09 → 1, 2.18 → 2, 3.27 → 3, 4.36 → 4, 5.45 → 5, 6.55 → 7, 7.64 → 8,
        // 8.73 → 9, 9.82 → 10, 10.91 → 11, 12 → 12. Only index 6 is left out.
        let thirteen = DayStoryPlan.choose(Self.photos(13), cap: 12)
        #expect(thirteen.map(\.id) == [0, 1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12].map { "library:\($0)" })
    }

    @Test func underCapKeepsAll() {
        // 12 photos at a cap of 12: all, in order.
        #expect(DayStoryPlan.choose(Self.photos(12), cap: 12) == Self.photos(12))
        #expect(DayStoryPlan.choose(Self.photos(1), cap: 12) == Self.photos(1))
        #expect(DayStoryPlan.choose([], cap: 12).isEmpty)
    }

    // MARK: - Plan

    @Test func makeSplitsEventsAndPhotos() throws {
        let buzz = Self.event("walk:b", .buzz, at: -120, coordinate: .at(), place: "Akershus Fortress")
        let story = Self.event("capture:s", .photoStory, at: 2400, coordinate: .at(north: 5000), title: "Oslo Cathedral")
        let stop = Self.event("walk:t", .stop, at: 7200, coordinate: .at(north: 9000), title: "Stortorvet")
        let near = Self.library("near", at: 180, coordinate: .at(north: 50))
        let lonely = Self.library("lonely", at: 4200)
        let plan = DayStoryPlan.make(day: Self.day([stop, lonely, story, near, buzz]))

        #expect(plan.events == [buzz, story, stop])
        #expect(plan.photos.map(\.id) == ["library:near", "capture:s", "library:lonely"])
        // 3 photos: the photo story and two library photos.
        #expect(plan.totalPhotos == 3)
        let storyPhoto = try #require(plan.photos.first { $0.id == "capture:s" })
        #expect(storyPhoto.storyTitle == "Oslo Cathedral" && storyPhoto.coordinate == .at(north: 5000)
                && storyPhoto.time == story.time)
        #expect(plan.photos.first { $0.id == "library:near" }?.storyTitle == nil)
        // Only library photos are matched; the photo story's photo belongs to its own story.
        #expect(plan.matches == ["library:near": buzz])
    }

    @Test func makeCapsAtTwelve() {
        // 20 library photos one minute apart: 12 chosen (indices round(i·19/11)), all 20 counted.
        let entries = (0..<20).map { Self.library(String(format: "%02ld", $0), at: Double($0) * 60) }
        let plan = DayStoryPlan.make(day: Self.day(entries))
        #expect(plan.photos.count == DayStoryPlan.photoCap)
        #expect(plan.totalPhotos == 20)
        #expect(plan.photos.first?.id == "library:00" && plan.photos.last?.id == "library:19")
        #expect(plan.events.isEmpty && plan.matches.isEmpty)
    }

    @Test func specValues() {
        #expect(DayStoryPlan.matchWindow == 600)
        #expect(DayStoryPlan.matchDistance == 150)
        #expect(DayStoryPlan.photoCap == 12)
    }
}
