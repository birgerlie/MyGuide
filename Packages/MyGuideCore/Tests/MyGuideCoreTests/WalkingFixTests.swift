import Foundation
import Testing
@testable import MyGuideCore

@Suite struct WalkingFixTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func freshUpToFifteenSeconds() {
        // Age = now − timestamp: 0 s and 15 s are fresh (≤ 15), 15.001 s and 600 s are stale.
        #expect(WalkingFix.isFresh(Self.now, now: Self.now))
        #expect(WalkingFix.isFresh(Self.now.addingTimeInterval(-15), now: Self.now))
        #expect(!WalkingFix.isFresh(Self.now.addingTimeInterval(-15.001), now: Self.now))
        #expect(!WalkingFix.isFresh(Self.now.addingTimeInterval(-600), now: Self.now))
    }
    @Test func aTimestampAheadOfTheClockCountsAsFresh() {
        // Age = −5 s ≤ 15: the fix is not old, the clocks disagree.
        #expect(WalkingFix.isFresh(Self.now.addingTimeInterval(5), now: Self.now))
    }
    @Test func usableAccuracyIsZeroToFiftyMetres() {
        // 0 and 50 are inside 0...50; 50.01 is above it, −1 is CoreLocation's "invalid".
        #expect(WalkingFix.isUsable(accuracy: 0))
        #expect(WalkingFix.isUsable(accuracy: 50))
        #expect(!WalkingFix.isUsable(accuracy: 50.01))
        #expect(!WalkingFix.isUsable(accuracy: -1))
        #expect(!WalkingFix.isUsable(accuracy: .nan))
        #expect(!WalkingFix.isUsable(accuracy: .infinity))
    }
    @Test func routeFixIsMovingAndAccurate() {
        // Moving: speed ≥ 0.5 m/s (0.5 and 1.4, a walking pace, pass; 0.49 and CoreLocation's unknown −1 do not).
        // Accurate: 0…20 m (0 and 20 pass; 20.01 and the invalid −1 do not).
        #expect(WalkingFix.isRouteFix(speed: 0.5, accuracy: 20))
        #expect(WalkingFix.isRouteFix(speed: 1.4, accuracy: 0))
        #expect(!WalkingFix.isRouteFix(speed: 0.49, accuracy: 5))
        #expect(!WalkingFix.isRouteFix(speed: -1, accuracy: 5))
        #expect(!WalkingFix.isRouteFix(speed: 1.4, accuracy: 20.01))
        #expect(!WalkingFix.isRouteFix(speed: 1.4, accuracy: -1))
    }
    @Test func routeFixRejectsNonFiniteValues() {
        #expect(!WalkingFix.isRouteFix(speed: .nan, accuracy: 5))
        #expect(!WalkingFix.isRouteFix(speed: .infinity, accuracy: 5))
        #expect(!WalkingFix.isRouteFix(speed: 1.4, accuracy: .nan))
        #expect(!WalkingFix.isRouteFix(speed: 1.4, accuracy: .infinity))
    }
}
