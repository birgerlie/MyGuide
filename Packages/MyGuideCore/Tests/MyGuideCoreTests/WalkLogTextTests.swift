import Foundation
import Testing
@testable import MyGuideCore

@Suite struct WalkLogTextTests {
    @Test func fetchedLine() {
        let kind = WalkLogEvent.Kind.fetched(count: 34, top: 3, good: 12, wikiOnly: 19, places: [])
        #expect(WalkLogText.line(kind) == "Fetched 34 places (3 top, 12 good)")
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
        #expect(WalkLogText.line(.stopped(.user)) == "Stopped: user")
        #expect(WalkLogText.line(.paused(.motion, at: nil)) == "Paused (motion)")
        // Hand: 312 / 60 = 5.2, floor 5.
        #expect(WalkLogText.line(.resumed(.gps, pausedSeconds: 312)) == "Resumed (gps) after 5 min")
        // Hand: 59 / 60 = 0.98, floor 0.
        #expect(WalkLogText.line(.resumed(.motion, pausedSeconds: 59)) == "Resumed (motion) after 0 min")
    }

    @Test func everyKindHasANonEmptyLine() {
        for kind in WalkLogEventTests.everyKind {
            #expect(!WalkLogText.line(kind).isEmpty, "\(kind)")
        }
    }
}
