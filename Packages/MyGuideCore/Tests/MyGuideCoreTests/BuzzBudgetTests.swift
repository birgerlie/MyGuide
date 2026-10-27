import Foundation
import Testing
@testable import MyGuideCore

@Suite struct BuzzBudgetTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    @Test func refillsAtTheSetRate() {
        // 20/h → one buzz per 3600/20 = 180 s. Start 1; spend → 0; +90 s → 0.5; +180 s → 1.0
        var b = BuzzBudget(perHour: 20, now: Self.t0)
        #expect(b.available(at: Self.t0) == 1)
        let first = b.spend(at: Self.t0)
        #expect(first)
        #expect(abs(b.available(at: Self.t0 + 90) - 0.5) < 1e-9)
        #expect(!b.canSpend(at: Self.t0 + 90))
        #expect(b.canSpend(at: Self.t0 + 180))
        let early = b.spend(at: Self.t0 + 90)
        #expect(!early)
        #expect(abs(b.available(at: Self.t0 + 90) - 0.5) < 1e-9)
    }
    @Test func capsAtThree() {
        // 20/h, idle 1 h after spending: 3600/180 = 20 buzzes accrued, capped at 3
        var b = BuzzBudget(perHour: 20, now: Self.t0)
        _ = b.spend(at: Self.t0)
        #expect(b.available(at: Self.t0 + 3600) == 3)
    }
    @Test func otherRates() {
        // 60/h → 60 s each: from 0, +150 s → 2.5.   5/h → 720 s each: from 0, +720 s → 1.0
        var fast = BuzzBudget(perHour: 60, now: Self.t0); _ = fast.spend(at: Self.t0)
        #expect(abs(fast.available(at: Self.t0 + 150) - 2.5) < 1e-9)
        var slow = BuzzBudget(perHour: 5, now: Self.t0); _ = slow.spend(at: Self.t0)
        #expect(abs(slow.available(at: Self.t0 + 719) - 719.0 / 720) < 1e-9)
        #expect(slow.canSpend(at: Self.t0 + 720))
    }
    @Test func clampsTheRate() {
        #expect(BuzzBudget(perHour: 0, now: Self.t0).perHour == 5)
        #expect(BuzzBudget(perHour: 4, now: Self.t0).perHour == 5)
        #expect(BuzzBudget(perHour: 61, now: Self.t0).perHour == 60)
        #expect(BuzzBudget(perHour: -3, now: Self.t0).perHour == 5)
    }
    @Test func rateChangeAccruesAtTheOldRateFirst() {
        // 20/h, spent at t0; at t0+90 (0.5 accrued) switch to 60/h; at t0+120: 0.5 + 30/60 = 1.0
        var b = BuzzBudget(perHour: 20, now: Self.t0); _ = b.spend(at: Self.t0)
        b.setPerHour(60, at: Self.t0 + 90)
        #expect(abs(b.available(at: Self.t0 + 120) - 1.0) < 1e-9)
    }
    @Test func clockGoingBackwardsAccruesNothing() {
        var b = BuzzBudget(perHour: 20, now: Self.t0); _ = b.spend(at: Self.t0)
        #expect(b.available(at: Self.t0 - 600) == 0)
        #expect(abs(b.available(at: Self.t0 + 90) - 0.5) < 1e-9)
    }

    // Edge and error cases.
    @Test func startsWithExactlyOneBuzz() {
        // Start 1; first spend succeeds → 0; second spend at the same instant has nothing to take.
        var b = BuzzBudget(perHour: 20, now: Self.t0)
        let first = b.spend(at: Self.t0)
        #expect(first)
        let second = b.spend(at: Self.t0)
        #expect(!second)
        #expect(b.available(at: Self.t0) == 0)
    }
    @Test func failedSpendLeavesStateUnchanged() {
        // 20/h, spent at t0 → 0. Failed spend at t0+90 (0.5 accrued, not spendable) must change nothing.
        // At t0+180 the total accrued is 180/180 = 1.0; a failed spend that subtracted anyway would show 0.5.
        var b = BuzzBudget(perHour: 20, now: Self.t0); _ = b.spend(at: Self.t0)
        let before = b
        let failed = b.spend(at: Self.t0 + 90)
        #expect(!failed)
        #expect(b == before)
        #expect(abs(b.available(at: Self.t0 + 180) - 1.0) < 1e-9)
    }
    @Test func spendingFromCapDropsToTwo() {
        // 20/h, idle 1 h from 1 → capped at 3. Spend 1 → 2 left, no more than cap.
        var b = BuzzBudget(perHour: 20, now: Self.t0)
        #expect(b.available(at: Self.t0 + 3600) == 3)
        let spent = b.spend(at: Self.t0 + 3600)
        #expect(spent)
        #expect(b.available(at: Self.t0 + 3600) == 2)
    }
    @Test func setPerHourClampsToRange() {
        // Out-of-range values clamp; in-range values stick.
        var b = BuzzBudget(perHour: 20, now: Self.t0)
        b.setPerHour(0, at: Self.t0)
        #expect(b.perHour == 5)
        b.setPerHour(100, at: Self.t0)
        #expect(b.perHour == 60)
        b.setPerHour(9, at: Self.t0)
        #expect(b.perHour == 9)
    }
    @Test func backwardsRateChangeDoesNotMoveAccrualPoint() {
        // 20/h, spent at t0 → 0. setPerHour(60) at t0-600 accrues nothing and must not move
        // the accrual point back. At t0+90 at 60/h: 90 * 60 / 3600 = 1.5 (not capped at 3 from a t0-600 origin).
        var b = BuzzBudget(perHour: 20, now: Self.t0); _ = b.spend(at: Self.t0)
        b.setPerHour(60, at: Self.t0 - 600)
        #expect(abs(b.available(at: Self.t0 + 90) - 1.5) < 1e-9)
    }
    @Test func rateChangeNeverExceedsCapacity() {
        // 20/h, idle 1 h from 1 → capped at 3 at t0+3600. Switch to 5/h: stays at 3, no overflow.
        var b = BuzzBudget(perHour: 20, now: Self.t0)
        b.setPerHour(5, at: Self.t0 + 3600)
        #expect(b.available(at: Self.t0 + 3600) == 3)
        #expect(b.available(at: Self.t0 + 7200) == 3)
    }
    @Test func boundaryExactlyOneBuzzAtNineRate() {
        // 9/h → 3600/9 = 400 s each. Spend at t0 → 0. At t0+399: 399/400 < 1, not spendable.
        // At t0+400: exactly 1.0, spendable.
        var b = BuzzBudget(perHour: 9, now: Self.t0); _ = b.spend(at: Self.t0)
        #expect(!b.canSpend(at: Self.t0 + 399))
        #expect(b.canSpend(at: Self.t0 + 400))
    }
}
