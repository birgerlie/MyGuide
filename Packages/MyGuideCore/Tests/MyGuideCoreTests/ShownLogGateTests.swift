import Foundation
import Testing
@testable import MyGuideCore

@Suite struct ShownLogGateTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    static func shown(_ id: String?, _ reason: ShownReason) -> WalkLogEvent.Kind {
        .shown(placeID: id, name: id.map { "Name \($0)" }, reason: reason)
    }

    /// Notes a selection `seconds` after t0.
    static func note(_ gate: inout ShownLogGate, _ id: String?, _ cause: ShownReason = .heading, holding: Bool = false,
                     at seconds: TimeInterval) -> WalkLogEvent.Kind? {
        gate.note(placeID: id, name: id.map { "Name \($0)" }, cause: cause, holding: holding,
                  now: t0.addingTimeInterval(seconds))
    }

    @Test func confirmationIsFiveSeconds() {
        #expect(ShownLogGate.clearedConfirmation == 5)
    }

    @Test func automaticSelectionIsWrittenOncePerPlace() {
        var g = ShownLogGate()
        #expect(Self.note(&g, "a", at: 0) == Self.shown("a", .heading))
        #expect(Self.note(&g, "a", at: 0.1) == nil)
        #expect(Self.note(&g, "b", at: 1) == Self.shown("b", .heading))
        #expect(Self.note(&g, "a", at: 2) == Self.shown("a", .heading))
    }

    @Test func tapAndBuzzAreWrittenWithTheirReason() {
        var g = ShownLogGate()
        #expect(Self.note(&g, "a", at: 0) == Self.shown("a", .heading))
        // Tapping the place the heading already picked: same place, new reason → written.
        #expect(Self.note(&g, "a", .tap, holding: true, at: 1) == Self.shown("a", .tap))
        // Tapping it again: same place and reason → nothing.
        #expect(Self.note(&g, "a", .tap, holding: true, at: 2) == nil)
        // The held place on automatic updates stays `tap`: nothing new.
        #expect(Self.note(&g, "a", holding: true, at: 3) == nil)
        // A buzz selects b (not held).
        #expect(Self.note(&g, "b", .buzz, at: 4) == Self.shown("b", .buzz))
        // Automatic updates keep b: nothing, though the cause is now heading.
        #expect(Self.note(&g, "b", at: 5) == nil)
        // A buzz of b again (a later buzz of the same place): same reason → nothing.
        #expect(Self.note(&g, "b", .buzz, at: 6) == nil)
        // Tapping b: new reason → written.
        #expect(Self.note(&g, "b", .tap, holding: true, at: 7) == Self.shown("b", .tap))
    }

    @Test func aHeldPlaceIsATapNotAHeading() {
        var g = ShownLogGate()
        // A newly selected place while the selector holds it (the held tap coming back) is `tap`.
        #expect(Self.note(&g, "a", holding: true, at: 0) == Self.shown("a", .tap))
    }

    @Test func clearedIsWrittenAfterFiveSecondsWithoutAPlace() {
        var g = ShownLogGate()
        #expect(Self.note(&g, "a", at: 0) == Self.shown("a", .heading))
        // No place from t0 + 10: 4.9 s later (t0 + 14.9) 4.9 < 5 → nothing; at t0 + 15, 5 ≥ 5 → cleared.
        #expect(Self.note(&g, nil, at: 10) == nil)
        #expect(Self.note(&g, nil, at: 14.9) == nil)
        #expect(Self.note(&g, nil, at: 15) == Self.shown(nil, .cleared))
        // Written once.
        #expect(Self.note(&g, nil, at: 16) == nil)
        #expect(Self.note(&g, nil, at: 30) == nil)
        // The place coming back after the cleared line is written again.
        #expect(Self.note(&g, "a", at: 31) == Self.shown("a", .heading))
    }

    @Test func aBlipShorterThanFiveSecondsWritesNothing() {
        var g = ShownLogGate()
        #expect(Self.note(&g, "a", at: 0) == Self.shown("a", .heading))
        // Gone at t0 + 10, back at t0 + 14.9 (4.9 s < 5): nothing at all.
        #expect(Self.note(&g, nil, at: 10) == nil)
        #expect(Self.note(&g, "a", at: 14.9) == nil)
        // The wait restarts with the next loss: gone at t0 + 20, still gone at t0 + 24.9 → nothing; t0 + 25 → cleared.
        #expect(Self.note(&g, nil, at: 20) == nil)
        #expect(Self.note(&g, nil, at: 24.9) == nil)
        #expect(Self.note(&g, nil, at: 25) == Self.shown(nil, .cleared))
    }

    @Test func aBlipEndingOnAnotherPlaceWritesThatPlaceOnly() {
        var g = ShownLogGate()
        _ = Self.note(&g, "a", at: 0)
        #expect(Self.note(&g, nil, at: 1) == nil)
        #expect(Self.note(&g, "b", at: 3) == Self.shown("b", .heading))
        // The loss was cancelled: none pending.
        #expect(Self.note(&g, nil, at: 7) == nil)
        #expect(Self.note(&g, nil, at: 11.9) == nil)
        #expect(Self.note(&g, nil, at: 12) == Self.shown(nil, .cleared))
    }

    @Test func aHeldTapAfterAConfirmedClearIsATap() {
        var g = ShownLogGate()
        #expect(Self.note(&g, "a", .tap, holding: true, at: 0) == Self.shown("a", .tap))
        // A poor fix for 6 s (the selector keeps holding a): cleared at 5 s.
        _ = Self.note(&g, nil, holding: true, at: 1)
        #expect(Self.note(&g, nil, holding: true, at: 6) == Self.shown(nil, .cleared))
        // The fix recovers and the held a is selected by the automatic update: still the owner's tap.
        #expect(Self.note(&g, "a", holding: true, at: 7) == Self.shown("a", .tap))
    }

    @Test func aHeldTapAfterABlipWritesNothing() {
        var g = ShownLogGate()
        _ = Self.note(&g, "a", .tap, holding: true, at: 0)
        #expect(Self.note(&g, nil, holding: true, at: 1) == nil)
        #expect(Self.note(&g, "a", holding: true, at: 3) == nil)
    }

    @Test func nothingIsClearedBeforeAPlaceWasWritten() {
        var g = ShownLogGate()
        #expect(Self.note(&g, nil, at: 0) == nil)
        #expect(Self.note(&g, nil, at: 10) == nil)
        #expect(Self.note(&g, nil, at: 100) == nil)
    }

    @Test func hidingTheMapRestartsThePendingClear() {
        var g = ShownLogGate()
        _ = Self.note(&g, "a", at: 0)
        #expect(Self.note(&g, nil, at: 1) == nil)
        g.mapHidden()
        // Shown again with no place at t0 + 6: the wait starts there, not at t0 + 1. 6 + 4.9 → nothing, 6 + 5 → cleared.
        #expect(Self.note(&g, nil, at: 6) == nil)
        #expect(Self.note(&g, nil, at: 10.9) == nil)
        #expect(Self.note(&g, nil, at: 11) == Self.shown(nil, .cleared))
    }

    @Test func clockSetBackRestartsTheWait() {
        var g = ShownLogGate()
        _ = Self.note(&g, "a", at: 0)
        _ = Self.note(&g, nil, at: 100)
        // Now t0 + 50, before the wait's start: restarts at t0 + 50; t0 + 54.9 nothing, t0 + 55 cleared.
        #expect(Self.note(&g, nil, at: 50) == nil)
        #expect(Self.note(&g, nil, at: 54.9) == nil)
        #expect(Self.note(&g, nil, at: 55) == Self.shown(nil, .cleared))
    }

    @Test func clearedAsACauseCountsAsHeading() {
        var g = ShownLogGate()
        #expect(Self.note(&g, "a", .cleared, at: 0) == Self.shown("a", .heading))
        #expect(Self.note(&g, "a", .cleared, holding: true, at: 1) == nil)
    }
}
