import Foundation
import Testing
@testable import MyGuideCore

@Suite struct TripRuleTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    @Test func rules() {
        #expect(TripRule.startsNewTrip(lastUsedAt: nil, tripCity: nil, now: Self.t0, city: nil))
        // 3 days = 259 200 s: 259 199 s later → same trip; 259 200 s → new trip
        #expect(!TripRule.startsNewTrip(lastUsedAt: Self.t0, tripCity: "Vienna", now: Self.t0 + 259_199, city: "Vienna"))
        #expect(TripRule.startsNewTrip(lastUsedAt: Self.t0, tripCity: "Vienna", now: Self.t0 + 259_200, city: "Vienna"))
        #expect(TripRule.startsNewTrip(lastUsedAt: Self.t0, tripCity: "Vienna", now: Self.t0 + 60, city: "Rome"))
        #expect(!TripRule.startsNewTrip(lastUsedAt: Self.t0, tripCity: "Wien", now: Self.t0 + 60, city: "wien"))
        #expect(!TripRule.startsNewTrip(lastUsedAt: Self.t0, tripCity: "Vienna", now: Self.t0 + 60, city: nil))
        #expect(!TripRule.startsNewTrip(lastUsedAt: Self.t0, tripCity: nil, now: Self.t0 + 60, city: "Rome"))
    }

    // MARK: - Edge cases beyond the brief

    @Test func idleGapIsThreeDays() {
        // 3 · 24 · 3600 = 259 200
        #expect(TripRule.idleGap == 3 * 24 * 3600)
    }
    @Test func noPreviousTripStartsOneWhateverTheCity() {
        #expect(TripRule.startsNewTrip(lastUsedAt: nil, tripCity: "Vienna", now: Self.t0, city: "Vienna"))
    }
    @Test func clockGoingBackwardsKeepsTheTrip() {
        // now is 60 s before lastUsedAt: an idle time of −60 s is not a gap.
        #expect(!TripRule.startsNewTrip(lastUsedAt: Self.t0, tripCity: "Vienna", now: Self.t0 - 60, city: "Vienna"))
    }
    @Test func cityComparisonIgnoresCaseDiacriticsAndSurroundingSpace() {
        #expect(!TripRule.startsNewTrip(lastUsedAt: Self.t0, tripCity: "Zürich", now: Self.t0 + 60, city: "zurich"))
        #expect(!TripRule.startsNewTrip(lastUsedAt: Self.t0, tripCity: "Roma", now: Self.t0 + 60, city: " Roma\n"))
        #expect(TripRule.startsNewTrip(lastUsedAt: Self.t0, tripCity: "Roma", now: Self.t0 + 60, city: "Rome"))
    }
    @Test func blankCityCountsAsUnknown() {
        #expect(!TripRule.startsNewTrip(lastUsedAt: Self.t0, tripCity: "Vienna", now: Self.t0 + 60, city: "  "))
        #expect(!TripRule.startsNewTrip(lastUsedAt: Self.t0, tripCity: "", now: Self.t0 + 60, city: "Rome"))
    }
    @Test func normalisedCityTrimsAndBlanksToNil() {
        #expect(TripRule.normalisedCity(" Wien ") == "Wien")
        #expect(TripRule.normalisedCity(" \t") == nil)
        #expect(TripRule.normalisedCity(nil) == nil)
    }
}
