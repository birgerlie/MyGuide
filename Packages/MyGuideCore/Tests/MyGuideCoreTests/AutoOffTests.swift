import Foundation
import Testing
@testable import MyGuideCore

@Suite struct AutoOffTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func limits() {
        // 4 h = 14 400 s: 14 399 → nil, 14 400 → timeLimit
        #expect(AutoOff.reason(activeTime: 14_399, pausedFor: nil, batteryLevel: 0.8) == nil)
        #expect(AutoOff.reason(activeTime: 14_400, pausedFor: nil, batteryLevel: 0.8) == .timeLimit)
        // 1 h = 3 600 s: 3 599 → nil, 3 600 → pausedTooLong
        #expect(AutoOff.reason(activeTime: 0, pausedFor: 3_599, batteryLevel: 0.8) == nil)
        #expect(AutoOff.reason(activeTime: 0, pausedFor: 3_600, batteryLevel: 0.8) == .pausedTooLong)
        // battery: 0.15 → nil, 0.149 → lowBattery, −1 (unknown) → nil, 0 → lowBattery
        #expect(AutoOff.reason(activeTime: 0, pausedFor: nil, batteryLevel: 0.15) == nil)
        #expect(AutoOff.reason(activeTime: 0, pausedFor: nil, batteryLevel: 0.149) == .lowBattery)
        #expect(AutoOff.reason(activeTime: 0, pausedFor: nil, batteryLevel: -1) == nil)
        #expect(AutoOff.reason(activeTime: 0, pausedFor: nil, batteryLevel: 0) == .lowBattery)
    }

    @Test func order() {
        #expect(AutoOff.reason(activeTime: 14_400, pausedFor: 3_600, batteryLevel: 0.05) == .timeLimit)
        #expect(AutoOff.reason(activeTime: 100, pausedFor: 3_600, batteryLevel: 0.05) == .pausedTooLong)
        #expect(AutoOff.reason(activeTime: 100, pausedFor: 10, batteryLevel: 0.05) == .lowBattery)
    }

    @Test func activeTimeSubtractsFinishedAndCurrentPauses() {
        // Hand: now − start = 5 000; finished pauses 1 000; current pause since t0+4 500 → 5 000 − 4 500 = 500.
        // 5 000 − 1 000 − 500 = 3 500.
        #expect(AutoOff.activeTime(startedAt: Self.t0, now: Self.t0 + 5_000, pausedTotal: 1_000, pausedSince: Self.t0 + 4_500) == 3_500)
        // Hand: no current pause → 5 000 − 1 000 = 4 000.
        #expect(AutoOff.activeTime(startedAt: Self.t0, now: Self.t0 + 5_000, pausedTotal: 1_000, pausedSince: nil) == 4_000)
    }

    @Test func activeTimeNeverNegative() {
        // Hand: clock backwards, now − start = −10 → clamped to 0.
        #expect(AutoOff.activeTime(startedAt: Self.t0, now: Self.t0 - 10, pausedTotal: 0, pausedSince: nil) == 0)
    }

    @Test func messages() {
        #expect(AutoOff.message(.timeLimit) == "Walking mode turned off after 4 hours.")
        #expect(AutoOff.message(.lowBattery) == "Walking mode turned off: battery below 15%.")
        #expect(AutoOff.message(.pausedTooLong) == "Walking mode turned off after an hour without walking.")
    }

    @Test func messagesInBothStoryLanguages() {
        #expect(AutoOff.message(.timeLimit, language: .norwegian) == "Gåmodus slo seg av etter 4 timer.")
        #expect(AutoOff.message(.lowBattery, language: .norwegian) == "Gåmodus slo seg av: batteriet er under 15 %.")
        #expect(AutoOff.message(.pausedTooLong, language: .norwegian)
                == "Gåmodus slo seg av etter en time uten at du gikk.")
        // English is the existing message, word for word.
        for reason in [AutoOffReason.timeLimit, .lowBattery, .pausedTooLong] {
            #expect(AutoOff.message(reason, language: .english) == AutoOff.message(reason))
        }
    }
}
