import Foundation
import Testing
@testable import MyGuideCore

@Suite struct AutoOffTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func limits() {
        // 4 h = 14 400 s: 14 399 → nil, 14 400 → timeLimit
        #expect(AutoOff.reason(startedAt: Self.t0, now: Self.t0 + 14_399, batteryLevel: 0.8) == nil)
        #expect(AutoOff.reason(startedAt: Self.t0, now: Self.t0 + 14_400, batteryLevel: 0.8) == .timeLimit)
        // battery: 0.15 → nil, 0.149 → lowBattery, −1 (unknown) → nil
        #expect(AutoOff.reason(startedAt: Self.t0, now: Self.t0, batteryLevel: 0.15) == nil)
        #expect(AutoOff.reason(startedAt: Self.t0, now: Self.t0, batteryLevel: 0.149) == .lowBattery)
        #expect(AutoOff.reason(startedAt: Self.t0, now: Self.t0, batteryLevel: -1) == nil)
        #expect(AutoOff.message(.timeLimit) == "Walking mode turned off after 4 hours.")
        #expect(AutoOff.message(.lowBattery) == "Walking mode turned off: battery below 15%.")
    }

    @Test func timeLimitWinsWhenBothApply() {
        #expect(AutoOff.reason(startedAt: Self.t0, now: Self.t0 + 20_000, batteryLevel: 0.05) == .timeLimit)
    }

    @Test func emptyBatteryAndClockGoingBackwards() {
        #expect(AutoOff.reason(startedAt: Self.t0, now: Self.t0, batteryLevel: 0) == .lowBattery)
        #expect(AutoOff.reason(startedAt: Self.t0, now: Self.t0 - 10, batteryLevel: 1) == nil)
    }
}
