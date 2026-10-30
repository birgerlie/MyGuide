import Foundation
import Testing
@testable import MyGuideCore

@Suite struct WalkLogEventTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000.25)
    static let c = Coordinate(latitude: 59.912346, longitude: 10.750001)
    static let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    static let settings = NotificationSettingsSnapshot(authorization: "authorized", alert: "enabled", sound: "enabled",
                                                       lockScreen: "enabled", notificationCenter: "enabled", timeSensitive: "disabled")

    static var everyKind: [WalkLogEvent.Kind] {
        [
            .started(WalkLogStart(appVersion: "1.2", build: "34", location: .whenInUse, notifications: .allowed,
                                  liveActivities: true, motion: .authorized, perHour: 6, battery: 0.5)),
            .started(WalkLogStart(appVersion: "1.2", build: "34", location: .denied, notifications: .notDetermined,
                                  liveActivities: false, motion: .unavailable, perHour: 3, battery: nil, source: .watch)),
            .stopped(.pausedTooLong, source: nil),
            .stopped(.user, source: .phone),
            .app(foreground: true),
            .app(foreground: false),
            .fix(WalkLogFix(coordinate: c, accuracy: 12, speed: 1.4, course: 90, paused: false, dropped: nil)),
            .fix(WalkLogFix(coordinate: c, accuracy: -1, speed: nil, course: nil, paused: true, dropped: .invalid)),
            .gps(found: true),
            .gps(found: false),
            .fetchStarted(c),
            .fetched(count: 2, top: 1, good: 1, wikiOnly: 0, places: [
                WalkLogPlace(id: "osm:node/1", name: "Akershus festning", tier: .top, coordinate: c),
                WalkLogPlace(id: "wiki:en/2", name: "Rådhuset", tier: .good, coordinate: c),
            ], osmFailed: false),
            .fetched(count: 0, top: 0, good: 0, wikiOnly: 0, places: [], osmFailed: true),
            .fetched(count: 0, top: 0, good: 0, wikiOnly: 0, places: [], osmFailed: true,
                     osmErrors: ["overpass-api.de: timed out", "overpass.kumi.systems: HTTP 504"]),
            .fetched(count: 0, top: 0, good: 0, wikiOnly: 0, places: [], osmFailed: true, osmErrors: ["slow"],
                     facts: 12, dropped: ["Jesuittordenen", "École française de Rome"], factsFailed: 1),
            .fetched(count: 1, top: 1, good: 0, wikiOnly: 0, places: [
                WalkLogPlace(id: "wiki:it/1", name: "Il Gesù", tier: .top, coordinate: c),
            ], osmFailed: false, stale: true),
            .fetchFailed(error: "timeout \"x\""),
            .fetchFailed(error: "http(500)", osmErrors: ["overpass-api.de: HTTP 500"]),
            .quiet(.busy, due: [DuePlace(id: "osm:node/1", name: "Akershus festning", tier: .top, distance: 52, excluded: true)]),
            .quiet(.noneDue, due: []),
            .buzz(WalkLogBuzz(id: id, placeID: "osm:node/1", name: "Akershus festning", tier: .top, distance: 53, override: true, detail: "ahead")),
            .notified(id: id, kind: .buzz, settings: settings),
            .notified(id: nil, kind: .autoOff, settings: settings),
            .notifyFailed(id: nil, kind: .stop, error: "denied"),
            .notifyFailed(id: id, kind: .more, error: "denied"),
            .busy(true),
            .storyPreparing(id: id),
            .storyReady(id: id, seconds: 3.4),
            .storyFailed(id: id, seconds: 12.5, error: "cancelled"),
            .stopDetected(c),
            .stopStory(outcome: .told, title: "A bench", error: nil),
            .stopStory(outcome: .failed, title: nil, error: "boom"),
            .stopShown(via: .liveActivity),
            .motion(.walking, confidence: .high),
            .paused(.motion, at: c, source: nil),
            .paused(.gps, at: nil, source: nil),
            .paused(.manual, at: c, source: .watch),
            .resumed(.gps, pausedSeconds: 181.5, source: nil),
            .resumed(.manual, pausedSeconds: 12, source: .phone),
            .failure(context: "memory", error: "disk full"),
            .shown(placeID: "wiki:it/1", name: "Il Gesù", reason: .heading),
            .shown(placeID: "osm:node/1", name: "Akershus festning", reason: .tap),
            .shown(placeID: "osm:node/1", name: "Akershus festning", reason: .buzz),
            .shown(placeID: nil, name: nil, reason: .cleared),
        ]
    }

    static func json(_ event: WalkLogEvent) -> [String: Any] {
        (try! JSONSerialization.jsonObject(with: WalkLogCodec.line(event))) as! [String: Any]
    }

    @Test func roundTripEveryKind() {
        for kind in Self.everyKind {
            let event = WalkLogEvent(at: Self.t0, kind: kind)
            #expect(WalkLogCodec.event(from: WalkLogCodec.line(event)) == event, "\(kind)")
        }
    }

    @Test func everyCaseIsCovered() {
        // 24 cases in Kind; the list above has 44 events (some cases several times: 2 started, 2 stopped, 2 app,
        // 2 fix, 2 gps, 1 fetchStarted, 5 fetched, 2 fetchFailed, 2 quiet, 1 buzz, 2 notified, 2 notifyFailed, 1 busy,
        // 3 story, 1 stopDetected, 2 stopStory, 1 stopShown, 1 motion, 3 paused, 2 resumed, 1 failure, 4 shown = 44).
        // Distinct event names must be all 24.
        let names = Set(Self.everyKind.map { Self.json(WalkLogEvent(at: Self.t0, kind: $0))["e"] as! String })
        #expect(Self.everyKind.count == 44)
        #expect(names.count == 24)
    }

    @Test func oldLinesWithoutSourceDecode() {
        let lines = [
            #"{"e":"started","t":"2026-01-01T10:00:00.000Z","appVersion":"1","build":"2","location":"always","notifications":"allowed","liveActivities":true,"motion":"authorized","perHour":6,"battery":0.5}"#,
            #"{"e":"stopped","t":"2026-01-01T10:00:00.000Z","reason":"user"}"#,
            #"{"e":"paused","t":"2026-01-01T10:00:00.000Z","reason":"motion","lat":59.9,"lon":10.7}"#,
            #"{"e":"resumed","t":"2026-01-01T10:00:00.000Z","reason":"motion","pausedSeconds":181.5}"#,
        ]
        let kinds = lines.compactMap { WalkLogCodec.event(from: Data($0.utf8))?.kind }
        #expect(kinds.count == 4)
        guard kinds.count == 4 else { return }
        guard case .started(let start) = kinds[0] else { Issue.record("not started"); return }
        #expect(start.source == nil)
        #expect(kinds[1] == .stopped(.user, source: nil))
        #expect(kinds[2] == .paused(.motion, at: Coordinate(latitude: 59.9, longitude: 10.7), source: nil))
        #expect(kinds[3] == .resumed(.motion, pausedSeconds: 181.5, source: nil))
    }

    @Test func manualReasonAndSourceRoundTrip() {
        let kinds: [WalkLogEvent.Kind] = [
            .paused(.manual, at: Self.c, source: .watch), .resumed(.manual, pausedSeconds: 3.5, source: .phone),
            .stopped(.user, source: .watch),
        ]
        for kind in kinds {
            let event = WalkLogEvent(at: Self.t0, kind: kind)
            #expect(WalkLogCodec.event(from: WalkLogCodec.line(event)) == event, "\(kind)")
        }
        let o = Self.json(WalkLogEvent(at: Self.t0, kind: .paused(.manual, at: nil, source: .watch)))
        #expect(o["reason"] as? String == "manual")
        #expect(o["source"] as? String == "watch")
    }

    @Test func sourceOmittedWhenNil() {
        let nilSource: [WalkLogEvent.Kind] = [
            .stopped(.user, source: nil), .paused(.motion, at: nil, source: nil), .resumed(.gps, pausedSeconds: 1, source: nil),
            .started(WalkLogStart(appVersion: "1", build: "2", location: .always, notifications: .allowed, liveActivities: true,
                                  motion: .authorized, perHour: 6, battery: nil)),
        ]
        for kind in nilSource {
            #expect(Self.json(WalkLogEvent(at: Self.t0, kind: kind))["source"] == nil, "\(kind)")
        }
    }

    @Test func rounding() throws {
        // Hand: 59.91234567 * 1e6 = 59912345.67 -> rounded 59912346 -> / 1e6 = 59.912346 (half away from zero).
        let fix = WalkLogFix(coordinate: Coordinate(latitude: 59.91234567, longitude: 10.7500004), accuracy: 52.6,
                             speed: nil, course: nil, paused: false, dropped: nil)
        let o = Self.json(WalkLogEvent(at: Self.t0, kind: .fix(fix)))
        #expect(o["lat"] as? Double == 59.912346)
        // Hand: 10.7500004 * 1e6 = 10750000.4 -> 10750000 -> 10.75.
        #expect(o["lon"] as? Double == 10.75)
        // Hand: accuracy 52.6 rounds to 53.
        #expect(o["accuracy"] as? Double == 53)
        let q = Self.json(WalkLogEvent(at: Self.t0, kind: .quiet(.busy, due: [DuePlace(id: "a", name: "A", tier: .top, distance: 52.6, excluded: false)])))
        let due = try #require((q["due"] as? [[String: Any]])?.first)
        // Hand: distance 52.6 rounds to 53.
        #expect(due["distance"] as? Double == 53)
        // Hand: 3.04 * 10 = 30.4 -> 30 -> 3.0 ; 3.06 * 10 = 30.6 -> 31 -> 3.1.
        #expect(Self.json(WalkLogEvent(at: Self.t0, kind: .storyReady(id: Self.id, seconds: 3.04)))["seconds"] as? Double == 3.0)
        #expect(Self.json(WalkLogEvent(at: Self.t0, kind: .storyReady(id: Self.id, seconds: 3.06)))["seconds"] as? Double == 3.1)
        // Hand: 181.55 would be a tie; 181.52 * 10 = 1815.2 -> 1815 -> 181.5.
        #expect(Self.json(WalkLogEvent(at: Self.t0, kind: .resumed(.motion, pausedSeconds: 181.52, source: nil)))["pausedSeconds"] as? Double == 181.5)
    }

    @Test func roundedValueIsWrittenAsShortDecimal() {
        let line = String(decoding: WalkLogCodec.line(WalkLogEvent(at: Self.t0, kind: .fetchStarted(Coordinate(latitude: 59.91234567, longitude: 10.75)))), as: UTF8.self)
        #expect(line.contains("\"lat\":59.912346"))
        #expect(!line.contains("59.9123460"))
    }

    @Test func fixJSONShape() {
        let fix = WalkLogFix(coordinate: Self.c, accuracy: 5, speed: nil, course: 12, paused: false, dropped: nil)
        let data = WalkLogCodec.line(WalkLogEvent(at: Self.t0, kind: .fix(fix)))
        #expect(data.last == 0x0A)
        let o = Self.json(WalkLogEvent(at: Self.t0, kind: .fix(fix)))
        #expect(Set(o.keys) == ["accuracy", "course", "e", "lat", "lon", "paused", "speed", "t"])
        #expect(o["e"] as? String == "fix")
        #expect(o["speed"] is NSNull)
        // Hand: exactly one newline, at the end.
        #expect(data.filter { $0 == 0x0A }.count == 1)
        var dropped = fix
        dropped.dropped = .stale
        #expect(Self.json(WalkLogEvent(at: Self.t0, kind: .fix(dropped)))["dropped"] as? String == "stale")
    }

    @Test func keysAreSorted() {
        let line = String(decoding: WalkLogCodec.line(WalkLogEvent(at: Self.t0, kind: .fetchStarted(Self.c))), as: UTF8.self)
        // Sorted: e, lat, lon, t.
        #expect(line == "{\"e\":\"fetchStarted\",\"lat\":59.912346,\"lon\":10.750001,\"t\":\"1970-01-12T13:46:40.250Z\"}\n")
    }

    @Test func slashesAreNotEscaped() {
        let line = String(decoding: WalkLogCodec.line(WalkLogEvent(at: Self.t0, kind: .storyFailed(id: Self.id, seconds: 1, error: "a/b"))), as: UTF8.self)
        #expect(line.contains("a/b"))
    }

    @Test func timestampIsUTCWithFraction() {
        // Hand: 1 000 000 s = 11 d (950 400 s) + 49 600 s = 13 h (46 800) + 2 800 s = 46 m (2 760) + 40 s,
        // so 1970-01-12 13:46:40; .25 s -> ".250".
        #expect(Self.json(WalkLogEvent(at: Self.t0, kind: .busy(true)))["t"] as? String == "1970-01-12T13:46:40.250Z")
    }

    @Test func errorTextCutAt300() {
        struct Long: Error, CustomStringConvertible { var description: String { String(repeating: "x", count: 400) } }
        // Hand: 400 characters cut to the first 300.
        #expect(WalkLogEvent.errorText(Long()).count == 300)
        struct Short: Error, CustomStringConvertible { var description: String { "short" } }
        #expect(WalkLogEvent.errorText(Short()) == "short")
    }

    @Test func fetchedCountsAndCap() throws {
        let around = Coordinate(latitude: 59.9, longitude: 10.7)
        func place(_ i: Int, _ tier: PlaceTier) -> WalkingPlace {
            // i * 0.0001 degrees of latitude is about 11 m per step: distance increases with i.
            WalkingPlace(candidate: Candidate(id: "p\(i)", name: "P\(i)",
                                              coordinate: Coordinate(latitude: 59.9 + Double(i) * 0.0001, longitude: 10.7),
                                              kind: "x"), tier: tier)
        }
        // 160 places at increasing distance: indices 0..9 top, 10..109 good, 110..159 wikiOnly; fed in reverse order.
        var places: [WalkingPlace] = []
        for i in 0..<160 { places.append(place(i, i < 10 ? .top : (i < 110 ? .good : .wikiOnly))) }
        let kind = WalkLogEvent.fetched(places.reversed(), around: around, osmFailed: false)
        guard case .fetched(let count, let top, let good, let wikiOnly, let listed, let osmFailed, _, _, _, _, _) = kind else { Issue.record("not fetched"); return }
        #expect(!osmFailed)
        #expect(count == 160)
        #expect(top == 10)
        #expect(good == 100)
        #expect(wikiOnly == 50)
        // Hand: 10 top + 100 good + 40 wikiOnly = 150; 10 wikiOnly (the farthest) are dropped.
        #expect(listed.count == 150)
        #expect(listed.prefix(10).allSatisfy { $0.tier == .top })
        #expect(listed[10..<110].allSatisfy { $0.tier == .good })
        #expect(listed[110...].allSatisfy { $0.tier == .wikiOnly })
        #expect(listed.first?.id == "p0")
        #expect(listed.last?.id == "p149")
    }

    @Test func fetchedEventCarriesOSMFailedAndOldLinesDecode() throws {
        let failed = WalkLogEvent.fetched([], around: Self.c, osmFailed: true)
        #expect(failed == .fetched(count: 0, top: 0, good: 0, wikiOnly: 0, places: [], osmFailed: true))
        let o = Self.json(WalkLogEvent(at: Self.t0, kind: failed))
        #expect(o["osmFailed"] as? Bool == true)
        let ok = Self.json(WalkLogEvent(at: Self.t0, kind: WalkLogEvent.fetched([], around: Self.c, osmFailed: false)))
        #expect(ok["osmFailed"] as? Bool == false)
        // A line written before osmFailed existed reads as no failure.
        let old = #"{"e":"fetched","t":"2026-01-01T10:00:00.000Z","count":1,"top":1,"good":0,"wikiOnly":0,"places":[{"id":"osm:node/1","name":"A","tier":1,"lat":59.9,"lon":10.7}]}"#
        let kind = try #require(WalkLogCodec.event(from: Data(old.utf8))?.kind)
        #expect(kind == .fetched(count: 1, top: 1, good: 0, wikiOnly: 0, places: [
            WalkLogPlace(id: "osm:node/1", name: "A", tier: .top, coordinate: Coordinate(latitude: 59.9, longitude: 10.7)),
        ], osmFailed: false))
        // A present but unreadable value makes the line unreadable, like every other field.
        let bad = #"{"e":"fetched","t":"2026-01-01T10:00:00.000Z","count":0,"top":0,"good":0,"wikiOnly":0,"places":[],"osmFailed":"yes"}"#
        #expect(WalkLogCodec.event(from: Data(bad.utf8)) == nil)
    }

    @Test func factsAndDroppedAreWrittenOnlyWhenPresentAndOldLinesDecode() throws {
        let place = WalkingPlace(candidate: Candidate(id: "wiki:it/1", name: "Il Gesù", coordinate: Self.c,
                                                      kind: "wikipedia"), tier: .top)
        let kind = WalkLogEvent.fetched([place], around: Self.c, osmFailed: true, osmErrors: ["slow"], facts: 3,
                                        dropped: ["Jesuittordenen"], factsFailed: 2)
        let o = Self.json(WalkLogEvent(at: Self.t0, kind: kind))
        #expect(o["facts"] as? Int == 3)
        #expect(o["dropped"] as? [String] == ["Jesuittordenen"])
        #expect(o["factsFailed"] as? Int == 2)
        let line = WalkLogCodec.line(WalkLogEvent(at: Self.t0, kind: kind))
        #expect(WalkLogCodec.event(from: line)?.kind == kind)
        // Nothing to say: the fields are left out, so the line looks as before.
        let plain = Self.json(WalkLogEvent(at: Self.t0, kind: WalkLogEvent.fetched([place], around: Self.c, osmFailed: false)))
        #expect(plain["facts"] == nil && plain["dropped"] == nil && plain["factsFailed"] == nil)
        // A line written before the fields existed reads with 0 / [] / 0.
        let old = #"{"e":"fetched","t":"2026-01-01T10:00:00.000Z","count":0,"top":0,"good":0,"wikiOnly":0,"places":[],"osmFailed":false}"#
        guard case .fetched(_, _, _, _, _, _, _, let facts, let dropped, let factsFailed, _)?
                = WalkLogCodec.event(from: Data(old.utf8))?.kind else { Issue.record("not fetched"); return }
        #expect(facts == 0 && dropped.isEmpty && factsFailed == 0)
        // Present but unreadable: the line is unreadable, like every other field.
        let prefix = #"{"e":"fetched","t":"2026-01-01T10:00:00.000Z","count":0,"top":0,"good":0,"wikiOnly":0,"places":[],"osmFailed":false,"#
        for bad in [#""facts":"3"}"#, #""facts":1.5}"#, #""dropped":"Jesuittordenen"}"#, #""dropped":[1]}"#,
                    #""factsFailed":"x"}"#] {
            #expect(WalkLogCodec.event(from: Data((prefix + bad).utf8)) == nil, "\(bad)")
        }
    }

    @Test func staleIsWrittenOnlyWhenTrueAndOldLinesDecode() throws {
        let place = WalkingPlace(candidate: Candidate(id: "wiki:it/1", name: "Il Gesù", coordinate: Self.c,
                                                      kind: "wikipedia"), tier: .top)
        let kind = WalkLogEvent.fetched([place], around: Self.c, osmFailed: false, stale: true)
        let o = Self.json(WalkLogEvent(at: Self.t0, kind: kind))
        #expect(o["stale"] as? Bool == true)
        #expect(WalkLogCodec.event(from: WalkLogCodec.line(WalkLogEvent(at: Self.t0, kind: kind)))?.kind == kind)
        // A fresh list: the field is left out, so the line looks as before.
        let fresh = Self.json(WalkLogEvent(at: Self.t0, kind: WalkLogEvent.fetched([place], around: Self.c,
                                                                                   osmFailed: false)))
        #expect(fresh["stale"] == nil)
        // A line written before the field existed reads as fresh.
        let old = #"{"e":"fetched","t":"2026-01-01T10:00:00.000Z","count":0,"top":0,"good":0,"wikiOnly":0,"places":[],"osmFailed":false}"#
        guard case .fetched(_, _, _, _, _, _, _, _, _, _, let stale)? = WalkLogCodec.event(from: Data(old.utf8))?.kind
        else { Issue.record("not fetched"); return }
        #expect(!stale)
        // An explicit false (hand-written) reads as fresh; a present non-Bool makes the line unreadable.
        let prefix = #"{"e":"fetched","t":"2026-01-01T10:00:00.000Z","count":0,"top":0,"good":0,"wikiOnly":0,"places":[],"osmFailed":false,"#
        #expect(WalkLogCodec.event(from: Data((prefix + #""stale":false}"#).utf8))?.kind
                == .fetched(count: 0, top: 0, good: 0, wikiOnly: 0, places: [], osmFailed: false))
        for bad in [#""stale":"yes"}"#, #""stale":[true]}"#] {
            #expect(WalkLogCodec.event(from: Data((prefix + bad).utf8)) == nil, "\(bad)")
        }
    }

    @Test func shownFieldsAndRoundTrip() throws {
        let tap = Self.json(WalkLogEvent(at: Self.t0, kind: .shown(placeID: "osm:node/1", name: "Akershus festning",
                                                                   reason: .tap)))
        #expect(tap["e"] as? String == "shown")
        #expect(tap["placeID"] as? String == "osm:node/1")
        #expect(tap["name"] as? String == "Akershus festning")
        #expect(tap["reason"] as? String == "tap")
        // Cleared: id and name are null, as `stopStory` writes its missing title.
        let cleared = Self.json(WalkLogEvent(at: Self.t0, kind: .shown(placeID: nil, name: nil, reason: .cleared)))
        #expect(cleared["placeID"] is NSNull && cleared["name"] is NSNull)
        #expect(cleared["reason"] as? String == "cleared")
        #expect(ShownReason.allCases.map(\.rawValue) == ["heading", "tap", "buzz", "cleared"])
        // Absent id and name read as nil.
        let absent = #"{"e":"shown","t":"2026-01-01T10:00:00.000Z","reason":"cleared"}"#
        #expect(WalkLogCodec.event(from: Data(absent.utf8))?.kind == .shown(placeID: nil, name: nil, reason: .cleared))
        // No reason, an unknown reason, or an id or name that is not text: unreadable.
        for bad in [#"{"e":"shown","t":"2026-01-01T10:00:00.000Z","placeID":"a","name":"A"}"#,
                    #"{"e":"shown","t":"2026-01-01T10:00:00.000Z","placeID":"a","name":"A","reason":"swipe"}"#,
                    #"{"e":"shown","t":"2026-01-01T10:00:00.000Z","placeID":1,"name":"A","reason":"tap"}"#,
                    #"{"e":"shown","t":"2026-01-01T10:00:00.000Z","placeID":"a","name":["A"],"reason":"tap"}"#] {
            #expect(WalkLogCodec.event(from: Data(bad.utf8)) == nil, "\(bad)")
        }
    }

    @Test func osmErrorsAreWrittenOnlyWhenPresentAndOldLinesDecode() throws {
        let errors = ["overpass-api.de: timed out", "maps.mail.ru: HTTP 504"]
        let failed = Self.json(WalkLogEvent(at: Self.t0, kind: WalkLogEvent.fetched([], around: Self.c, osmFailed: true,
                                                                                    osmErrors: errors)))
        #expect(failed["osmErrors"] as? [String] == errors)
        let plain = Self.json(WalkLogEvent(at: Self.t0, kind: WalkLogEvent.fetched([], around: Self.c, osmFailed: false)))
        #expect(plain["osmErrors"] == nil)
        let failedFetch = Self.json(WalkLogEvent(at: Self.t0, kind: .fetchFailed(error: "x", osmErrors: errors)))
        #expect(failedFetch["osmErrors"] as? [String] == errors)
        #expect(Self.json(WalkLogEvent(at: Self.t0, kind: .fetchFailed(error: "x")))["osmErrors"] == nil)
        // Lines written before osmErrors existed.
        let oldFailed = #"{"e":"fetchFailed","t":"2026-01-01T10:00:00.000Z","error":"timeout"}"#
        #expect(WalkLogCodec.event(from: Data(oldFailed.utf8))?.kind == .fetchFailed(error: "timeout", osmErrors: []))
        let oldFetched = #"{"e":"fetched","t":"2026-01-01T10:00:00.000Z","count":0,"top":0,"good":0,"wikiOnly":0,"places":[],"osmFailed":true}"#
        #expect(WalkLogCodec.event(from: Data(oldFetched.utf8))?.kind
                == .fetched(count: 0, top: 0, good: 0, wikiOnly: 0, places: [], osmFailed: true, osmErrors: []))
        // Present but not an array of strings: unreadable, like every other field.
        for bad in [#"{"e":"fetchFailed","t":"2026-01-01T10:00:00.000Z","error":"x","osmErrors":"timed out"}"#,
                    #"{"e":"fetchFailed","t":"2026-01-01T10:00:00.000Z","error":"x","osmErrors":[1]}"#,
                    #"{"e":"fetched","t":"2026-01-01T10:00:00.000Z","count":0,"top":0,"good":0,"wikiOnly":0,"places":[],"osmFailed":true,"osmErrors":{}}"#] {
            #expect(WalkLogCodec.event(from: Data(bad.utf8)) == nil, "\(bad)")
        }
    }

    @Test func fetchFailedFromAnError() {
        // A plain error: its text, no endpoint lines.
        #expect(WalkLogEvent.fetchFailed(GroundingFetchError.http(502)) == .fetchFailed(error: "http(502)", osmErrors: []))
        // An OverpassFailure: the first error's text and its endpoint lines.
        let failure = OverpassFailure(first: GroundingFetchError.http(502), endpointErrors: ["overpass-api.de: HTTP 502"])
        #expect(WalkLogEvent.fetchFailed(failure) == .fetchFailed(error: "http(502)", osmErrors: ["overpass-api.de: HTTP 502"]))
        #expect(WalkLogEvent.errorText(failure) == "http(502)")
    }

    @Test func unknownEventIsUnreadable() {
        #expect(WalkLogCodec.event(from: Data(#"{"t":"1970-01-12T13:46:40.250Z","e":"nope"}"#.utf8)) == nil)
        #expect(WalkLogCodec.event(from: Data(#"{"t":"1970-01-12T13:46:40.250Z","e":"busy"}"#.utf8)) == nil)
        #expect(WalkLogCodec.event(from: Data(#"{"e":"busy","busy":true}"#.utf8)) == nil)
        #expect(WalkLogCodec.event(from: Data("not json".utf8)) == nil)
    }

    @Test func buzzFromEngineBuzz() {
        let candidate = Candidate(id: "osm:node/1", name: "Fort", coordinate: Self.c, kind: "historic=fort")
        let buzz = Buzz(id: Self.id, place: WalkingPlace(candidate: candidate, tier: .top), distance: 52.6, bearing: 10,
                        title: "Fort", detail: "ahead", usedOverride: true)
        #expect(WalkLogBuzz(buzz) == WalkLogBuzz(id: Self.id, placeID: "osm:node/1", name: "Fort", tier: .top,
                                                 distance: 52.6, override: true, detail: "ahead"))
    }
}

@Suite struct WalkLogNonFiniteTests {
    @Test func nonFiniteNumbersBecomeNullInsteadOfCrashing() {
        let fix = WalkLogFix(coordinate: Coordinate(latitude: 1, longitude: 2), accuracy: .nan, speed: .infinity, course: nil, paused: false, dropped: nil)
        let o = (try! JSONSerialization.jsonObject(with: WalkLogCodec.line(WalkLogEvent(at: Date(timeIntervalSince1970: 0), kind: .fix(fix))))) as! [String: Any]
        #expect(o["accuracy"] is NSNull)
        #expect(o["speed"] is NSNull)
    }

    @Test func tourStopBuzzIsMarkedAndOldLinesReadAsNot() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!
        let stop = WalkLogBuzz(id: id, placeID: "osm:node/1", name: "Pantheon", tier: .wikiOnly, distance: 40,
                               override: false, detail: "40 m away", tourStop: true)
        let event = WalkLogEvent(at: Date(timeIntervalSince1970: 1_000_000), kind: .buzz(stop))
        let object = try #require(JSONSerialization.jsonObject(with: WalkLogCodec.line(event)) as? [String: Any])
        #expect(object["tourStop"] as? Bool == true)
        #expect(WalkLogCodec.event(from: WalkLogCodec.line(event)) == event)
        // An engine buzz writes no flag.
        var plain = stop
        plain.tourStop = false
        let plainEvent = WalkLogEvent(at: event.at, kind: .buzz(plain))
        let plainObject = try #require(JSONSerialization.jsonObject(with: WalkLogCodec.line(plainEvent)) as? [String: Any])
        #expect(plainObject["tourStop"] == nil)
        #expect(WalkLogCodec.event(from: WalkLogCodec.line(plainEvent)) == plainEvent)
        // A flag of the wrong type makes the line unreadable, as for the other fields.
        var bad = object
        bad["tourStop"] = "yes"
        #expect(WalkLogCodec.event(from: try JSONSerialization.data(withJSONObject: bad)) == nil)
        #expect(WalkLogText.line(event.kind).hasSuffix("(tour stop)"))
    }

    @Test func tourCadenceQuietLineRoundTrips() {
        let event = WalkLogEvent(at: Date(timeIntervalSince1970: 1_000_000), kind: .quiet(.tourCadence, due: []))
        #expect(WalkLogCodec.event(from: WalkLogCodec.line(event)) == event)
        #expect(QuietReason.tourCadence.rawValue == "tourCadence")
    }

    @Test func tourStopHeldQuietLineRoundTrips() {
        let event = WalkLogEvent(at: Date(timeIntervalSince1970: 1_000_000), kind: .quiet(.tourStopHeld, due: []))
        #expect(WalkLogCodec.event(from: WalkLogCodec.line(event)) == event)
        #expect(QuietReason.tourStopHeld.rawValue == "tourStopHeld")
        // Additive: the cases written by earlier builds keep their raw values and order.
        #expect(QuietReason.allCases.map(\.rawValue) == ["badAccuracy", "noneDue", "busy", "skipQuiet", "minGap",
                                                          "allExcluded", "held", "budget", "tourCadence", "tourStopHeld"])
    }
}
