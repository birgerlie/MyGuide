import Foundation
import Testing
@testable import MyGuideCore

@Suite struct WalkLogTextTests {
    @Test func fetchedLine() {
        let kind = WalkLogEvent.Kind.fetched(count: 34, top: 3, good: 12, wikiOnly: 19, places: [], osmFailed: false)
        #expect(WalkLogText.line(kind) == "Fetched 34 places (3 top, 12 good)")
        let failed = WalkLogEvent.Kind.fetched(count: 15, top: 0, good: 0, wikiOnly: 15, places: [], osmFailed: true)
        #expect(WalkLogText.line(failed) == "Fetched 15 places (0 top, 0 good) · OpenStreetMap failed")
        let withErrors = WalkLogEvent.Kind.fetched(count: 15, top: 0, good: 0, wikiOnly: 15, places: [], osmFailed: true,
                                                   osmErrors: ["overpass-api.de: timed out", "maps.mail.ru: HTTP 504"])
        #expect(WalkLogText.line(withErrors)
                == "Fetched 15 places (0 top, 0 good) · OpenStreetMap failed (overpass-api.de: timed out; maps.mail.ru: HTTP 504)")
        let dropped = WalkLogEvent.Kind.fetched(count: 5, top: 3, good: 2, wikiOnly: 0, places: [], osmFailed: true,
                                                osmErrors: ["slow"], facts: 8, dropped: ["Jesuittordenen", "Liberatores"])
        #expect(WalkLogText.line(dropped)
                == "Fetched 5 places (3 top, 2 good) · OpenStreetMap failed (slow) · dropped Jesuittordenen, Liberatores")
    }

    @Test func fetchFailedLine() {
        #expect(WalkLogText.line(.fetchFailed(error: "http(500)")) == "Fetch failed: http(500)")
        #expect(WalkLogText.line(.fetchFailed(error: "http(500)", osmErrors: ["overpass-api.de: HTTP 500"]))
                == "Fetch failed: http(500) (overpass-api.de: HTTP 500)")
    }

    @Test func quietLines() {
        let due = DuePlace(id: "a", name: "Akershus festning", tier: .top, distance: 52, excluded: false)
        #expect(WalkLogText.line(.quiet(.busy, due: [due])) == "Quiet: busy · Akershus festning 52 m")
        let second = DuePlace(id: "b", name: "Rådhuset", tier: .good, distance: 52.6, excluded: false)
        // Hand: 52.6 rounds to 53.
        #expect(WalkLogText.line(.quiet(.busy, due: [due, second])) == "Quiet: busy · Akershus festning 52 m, Rådhuset 53 m")
        #expect(WalkLogText.line(.quiet(.noneDue, due: [])) == "Quiet: noneDue")
    }

    @Test func buzzLines() {
        var buzz = WalkLogBuzz(id: UUID(), placeID: "a", name: "Akershus festning", tier: .top, distance: 53.4, override: false, detail: "")
        // Hand: 53.4 rounds to 53.
        #expect(WalkLogText.line(.buzz(buzz)) == "Buzz: Akershus festning · 53 m")
        buzz.override = true
        #expect(WalkLogText.line(.buzz(buzz)) == "Buzz: Akershus festning · 53 m (override)")
    }

    @Test func stoppedAndPausedLines() {
        #expect(WalkLogText.line(.stopped(.user, source: nil)) == "Stopped: user")
        #expect(WalkLogText.line(.paused(.motion, at: nil, source: nil)) == "Paused (motion)")
        // Hand: 312 / 60 = 5.2, floor 5.
        #expect(WalkLogText.line(.resumed(.gps, pausedSeconds: 312, source: nil)) == "Resumed (gps) after 5 min")
        // Hand: 59 / 60 = 0.98, floor 0.
        #expect(WalkLogText.line(.resumed(.motion, pausedSeconds: 59, source: nil)) == "Resumed (motion) after 0 min")
    }

    @Test func manualAndSourceLines() {
        #expect(WalkLogText.line(.paused(.manual, at: nil, source: nil)) == "Paused (manual)")
        #expect(WalkLogText.line(.paused(.manual, at: nil, source: .watch)) == "Paused (manual, watch)")
        // Hand: 125 / 60 = 2.08, floor 2.
        #expect(WalkLogText.line(.resumed(.manual, pausedSeconds: 125, source: .phone)) == "Resumed (manual, phone) after 2 min")
        #expect(WalkLogText.line(.stopped(.user, source: .watch)) == "Stopped: user (watch)")
    }

    @Test func everyKindHasANonEmptyLine() {
        for kind in WalkLogEventTests.everyKind {
            #expect(!WalkLogText.line(kind).isEmpty, "\(kind)")
        }
    }

    @Test func nonFiniteAndHugeNumbersDoNotCrash() {
        for value in [1e30, -1e30, Double.nan, Double.infinity] {
            let buzz = WalkLogBuzz(id: UUID(), placeID: "a", name: "A", tier: .top, distance: value, override: false, detail: "")
            #expect(!WalkLogText.line(.buzz(buzz)).isEmpty)
            let due = DuePlace(id: "a", name: "A", tier: .top, distance: value, excluded: false)
            #expect(!WalkLogText.line(.quiet(.busy, due: [due])).isEmpty)
            #expect(!WalkLogText.line(.resumed(.gps, pausedSeconds: value, source: nil)).isEmpty)
            let fix = WalkLogFix(coordinate: .at(), accuracy: value, speed: nil, course: nil, paused: false, dropped: nil)
            #expect(!WalkLogText.line(.fix(fix)).isEmpty)
        }
        let nan = DuePlace(id: "a", name: "A", tier: .top, distance: .nan, excluded: false)
        #expect(WalkLogText.line(.quiet(.busy, due: [nan])) == "Quiet: busy · A ? m")
    }

    @Test func fixLineShowsPausedAndDroppedFlags() {
        let fix = WalkLogFix(coordinate: .at(), accuracy: 12.4, speed: nil, course: nil, paused: true, dropped: .stale)
        // Hand: 12.4 rounds to 12.
        #expect(WalkLogText.line(.fix(fix)) == "Fix ±12 m (paused, dropped stale)")
        let plain = WalkLogFix(coordinate: .at(), accuracy: 12.6, speed: nil, course: nil, paused: false, dropped: nil)
        // Hand: 12.6 rounds to 13.
        #expect(WalkLogText.line(.fix(plain)) == "Fix ±13 m")
    }
}
