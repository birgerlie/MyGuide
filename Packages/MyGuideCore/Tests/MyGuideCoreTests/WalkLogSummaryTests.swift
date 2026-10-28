import Foundation
import Testing
@testable import MyGuideCore

@Suite struct WalkLogSummaryTests {
    static let t0 = Date(timeIntervalSince1970: 2_000_000)

    static func fix(_ north: Double, acc: Double = 5, paused: Bool = false, dropped: FixDrop? = nil, at: Double = 0) -> WalkLogEvent {
        WalkLogEvent(at: t0.addingTimeInterval(at), kind: .fix(WalkLogFix(
            coordinate: .at(north: north), accuracy: acc, speed: nil, course: nil, paused: paused, dropped: dropped)))
    }

    static func ev(_ kind: WalkLogEvent.Kind, at: Double = 0) -> WalkLogEvent { WalkLogEvent(at: t0.addingTimeInterval(at), kind: kind) }

    static func place(_ id: String, name: String = "P", tier: PlaceTier = .good, north: Double = 0) -> WalkLogPlace {
        WalkLogPlace(id: id, name: name, tier: tier, coordinate: .at(north: north))
    }

    static func fetched(_ places: [WalkLogPlace]) -> WalkLogEvent.Kind {
        .fetched(count: places.count, top: 0, good: places.count, wikiOnly: 0, places: places)
    }

    @Test func distanceSkipsPausedAndPoorFixes() {
        let events = [Self.fix(0), Self.fix(10), Self.fix(30), Self.fix(1_000, paused: true), Self.fix(1_010), Self.fix(1_020)]
        let summary = WalkLogSummary(events: events, unreadable: 0)
        // Hand: segment 1 = 10 + 20 = 30; the paused fix ends it and is not counted; segment 2 = 10 -> 40 in total.
        #expect(abs(summary.distance - 40) < 0.01)
        let path = WalkLogMapData(events: events).path
        // Hand: [0,10,30] and [1010,1020] -> 2 segments of 3 and 2 points.
        #expect(path.count == 2)
        #expect(path.map(\.count) == [3, 2])
    }

    @Test func poorFixSkippedNotSplitting() {
        let events = [Self.fix(0, acc: 5), Self.fix(10, acc: 80), Self.fix(20, acc: 5)]
        // Hand: the 80 m fix is skipped, so 0 -> 20 = 20 m in one segment.
        #expect(abs(WalkLogSummary(events: events, unreadable: 0).distance - 20) < 0.01)
        #expect(WalkLogMapData(events: events).path.count == 1)
    }

    @Test func accuracyBoundaryFiftyCounts() {
        let events = [Self.fix(0, acc: 50), Self.fix(10, acc: 50.5), Self.fix(20, acc: 50)]
        // Hand: 50 counts, 50.5 does not: 0 -> 20 = 20 m, 2 points on the path.
        #expect(abs(WalkLogSummary(events: events, unreadable: 0).distance - 20) < 0.01)
        #expect(WalkLogMapData(events: events).path.first?.count == 2)
    }

    @Test func droppedFixesAreSkipped() {
        let events = [Self.fix(0), Self.fix(500, dropped: .stale), Self.fix(10, dropped: nil)]
        // Hand: the stale fix at 500 is ignored: 0 -> 10 = 10 m.
        #expect(abs(WalkLogSummary(events: events, unreadable: 0).distance - 10) < 0.01)
    }

    @Test func pausedEventEndsSegment() {
        let events = [Self.fix(0), Self.fix(10), Self.ev(.paused(.motion, at: .at(north: 10), source: nil)),
                      Self.ev(.resumed(.motion, pausedSeconds: 300, source: nil)), Self.fix(500), Self.fix(520)]
        let summary = WalkLogSummary(events: events, unreadable: 0)
        // Hand: 10 in the first segment, 20 in the second, nothing for the 490 m gap -> 30.
        #expect(abs(summary.distance - 30) < 0.01)
        #expect(WalkLogMapData(events: events).path.count == 2)
        #expect(summary.pauses == 1)
    }

    @Test func pausedThenPausedCountsOnce() {
        // Review Focus 4. Hand: paused(motion), paused(manual) with no resumed between is one pause: pauses = 1.
        // Path: fixes 0, 10 (10 m) | pause | fixes 500, 520 (20 m) after the resume = 30 m in 2 segments; the second
        // paused must not close an (empty) segment, so the count stays 2. A later paused after the resume is a second pause.
        let events = [Self.fix(0), Self.fix(10), Self.ev(.paused(.motion, at: .at(north: 10), source: nil)),
                      Self.ev(.paused(.manual, at: .at(north: 11), source: .phone)),
                      Self.ev(.resumed(.manual, pausedSeconds: 300, source: .phone)), Self.fix(500), Self.fix(520)]
        let summary = WalkLogSummary(events: events, unreadable: 0)
        #expect(summary.pauses == 1)
        #expect(abs(summary.distance - 30) < 0.01)
        let map = WalkLogMapData(events: events)
        #expect(map.path.count == 2)
        #expect(map.pauses == [.at(north: 10)])
        let again = events + [Self.ev(.paused(.motion, at: nil, source: nil))]
        #expect(WalkLogSummary(events: again, unreadable: 0).pauses == 2)
    }

    @Test func endedWithoutStop() {
        #expect(WalkLogSummary(events: [Self.fix(0)], unreadable: 0).stopReason == nil)
        #expect(WalkLogSummary(events: [Self.fix(0), Self.ev(.stopped(.lowBattery, source: nil))], unreadable: 0).stopReason == .lowBattery)
    }

    @Test func countsAndPlacesDistinct() {
        let a = Self.place("a"), b = Self.place("b"), c = Self.place("c"), d = Self.place("d")
        let id = UUID()
        let events = [
            Self.ev(.fetchStarted(.at())), Self.ev(Self.fetched([a, b, c])),
            Self.ev(.fetchStarted(.at())), Self.ev(Self.fetched([c, d])),
            Self.ev(.fetchStarted(.at())), Self.ev(.fetchFailed(error: "x")),
            Self.ev(.buzz(WalkLogBuzz(id: id, placeID: "a", name: "A", tier: .top, distance: 5, override: false, detail: ""))),
            Self.ev(.notified(id: id, kind: .buzz, settings: WalkLogEventTests.settings)),
            Self.ev(.failure(context: "c", error: "e")), Self.ev(.notifyFailed(id: nil, kind: .stop, error: "e")),
            Self.ev(.storyFailed(id: id, seconds: 1, error: "e")),
            Self.ev(.paused(.gps, at: nil, source: nil)),
        ]
        let s = WalkLogSummary(events: events, unreadable: 3)
        // Hand: places 3 + 2 - 1 shared (c) = 4.
        #expect(s.places == 4)
        // Hand: 3 fetchStarted events (attempts), 2 fetched, 1 fetchFailed -> fetches 3.
        #expect(s.fetches == 3)
        #expect(s.fetchFailures == 1)
        #expect(s.buzzes == 1)
        #expect(s.notifications == 1)
        // Hand: failure + notifyFailed + storyFailed = 3; fetchFailed adds 1 more = 4.
        #expect(s.failures == 4)
        #expect(s.pauses == 1)
        #expect(s.unreadable == 3)
    }

    @Test func durationFromFirstToLast() {
        let events = [Self.ev(.gps(found: true), at: 0), Self.ev(.gps(found: false), at: 3_725.5)]
        let s = WalkLogSummary(events: events, unreadable: 0)
        // Hand: (t0 + 3725.5) - t0 = 3725.5.
        #expect(s.duration == 3_725.5)
        #expect(s.start == Self.t0)
        #expect(s.end == Self.t0.addingTimeInterval(3_725.5))
    }

    @Test func emptyLog() {
        let s = WalkLogSummary(events: [], unreadable: 2)
        #expect(s.start == nil)
        #expect(s.end == nil)
        #expect(s.duration == 0)
        #expect(s.distance == 0)
        #expect(s.stopReason == nil)
        #expect(s.unreadable == 2)
        let m = WalkLogMapData(events: [])
        #expect(m.path.isEmpty && m.places.isEmpty && m.stops.isEmpty && m.pauses.isEmpty && m.buzzedPlaceIDs.isEmpty)
    }

    @Test func stopsOnlyWhenTold() {
        let a = Coordinate.at(north: 1), b = Coordinate.at(north: 2)
        let events = [Self.ev(.stopDetected(a)), Self.ev(.stopStory(outcome: .told, title: "t", error: nil)),
                      Self.ev(.stopDetected(b)), Self.ev(.stopStory(outcome: .silent, title: nil, error: nil))]
        #expect(WalkLogMapData(events: events).stops == [a])
    }

    @Test func stopWithoutStoryIsNotAStop() {
        let events = [Self.ev(.stopDetected(.at(north: 1)))]
        #expect(WalkLogMapData(events: events).stops.isEmpty)
    }

    @Test func placesDistinctLastSeenWinsFirstSeenOrder() {
        let events = [Self.ev(Self.fetched([Self.place("a", name: "old"), Self.place("b")])),
                      Self.ev(Self.fetched([Self.place("c"), Self.place("a", name: "new")]))]
        let places = WalkLogMapData(events: events).places
        #expect(places.map(\.id) == ["a", "b", "c"])
        #expect(places.first?.name == "new")
    }

    @Test func buzzedAndPauses() {
        let id = UUID(), at = Coordinate.at(north: 7)
        let events = [Self.ev(.buzz(WalkLogBuzz(id: id, placeID: "p1", name: "A", tier: .top, distance: 5, override: false, detail: ""))),
                      Self.ev(.paused(.motion, at: at, source: nil)), Self.ev(.resumed(.motion, pausedSeconds: 1, source: nil)),
                      Self.ev(.paused(.gps, at: nil, source: nil))]
        let m = WalkLogMapData(events: events)
        #expect(m.buzzedPlaceIDs == ["p1"])
        #expect(m.pauses == [at])
    }

    @Test func durationNeverNegative() {
        // Hand: last event is 50 s before the first (clock stepped back): -50 -> clamped to 0.
        let events = [Self.ev(.gps(found: true), at: 100), Self.ev(.gps(found: false), at: 50)]
        #expect(WalkLogSummary(events: events, unreadable: 0).duration == 0)
    }

    @Test func latestDetectedStopPairsWithToldStory() {
        let a = Coordinate.at(north: 1), b = Coordinate.at(north: 2)
        let events = [Self.ev(.stopDetected(a)), Self.ev(.stopDetected(b)),
                      Self.ev(.stopStory(outcome: .told, title: "t", error: nil))]
        #expect(WalkLogMapData(events: events).stops == [b])
    }
}
