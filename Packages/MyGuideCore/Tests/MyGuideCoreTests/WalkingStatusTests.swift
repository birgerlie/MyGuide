import Foundation
import Testing
@testable import MyGuideCore

@Suite struct WalkingStatusTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func text() {
        #expect(WalkingStatus.text(isOn: false, lastFixAt: Self.t0, buzzCount: 3, now: Self.t0) == nil)
        #expect(WalkingStatus.text(isOn: true, lastFixAt: nil, buzzCount: 0, now: Self.t0) == "Walking · waiting for GPS")
        // Review Focus 1: 120 s is still fresh, 121 s is stale
        #expect(WalkingStatus.text(isOn: true, lastFixAt: Self.t0, buzzCount: 1, now: Self.t0 + 120) == "Walking · 1 buzz")
        #expect(WalkingStatus.text(isOn: true, lastFixAt: Self.t0, buzzCount: 1, now: Self.t0 + 121) == "Walking · waiting for GPS")
        #expect(WalkingStatus.text(isOn: true, lastFixAt: Self.t0, buzzCount: 0, now: Self.t0) == "Walking · 0 buzzes")
        #expect(WalkingStatus.text(isOn: true, lastFixAt: Self.t0, buzzCount: 7, now: Self.t0) == "Walking · 7 buzzes")
    }

    @Test func aFixFromTheFutureIsFresh() {
        // A clock that stepped back makes the age negative (-5 s), which is not older than 120 s.
        #expect(WalkingStatus.text(isOn: true, lastFixAt: Self.t0 + 5, buzzCount: 2, now: Self.t0) == "Walking · 2 buzzes")
    }
}
