import Foundation
import Testing
@testable import MyGuideCore

@Suite struct TourFormatTests {
    // MARK: - Duration

    @Test func durationUnderAnHour() {
        // 2700 s / 60 = 45 min.
        #expect(TourFormat.duration(2700, language: .norwegian) == "45 min")
        // 1789 s / 60 = 29.82 → 30 min; 1769 s / 60 = 29.48 → 29 min.
        #expect(TourFormat.duration(1789, language: .english) == "30 min")
        #expect(TourFormat.duration(1769, language: .english) == "29 min")
    }

    @Test func durationWithHours() {
        // 5100 s / 60 = 85 min = 1 h 25 min (the spec's example).
        #expect(TourFormat.duration(5100, language: .norwegian) == "1 t 25 min")
        #expect(TourFormat.duration(5100, language: .english) == "1 h 25 min")
        // 3600 s = 60 min exactly → whole hour, no «0 min».
        #expect(TourFormat.duration(3600, language: .norwegian) == "1 t")
        // 3570 s / 60 = 59.5 → rounds away from zero to 60 → «1 h».
        #expect(TourFormat.duration(3570, language: .english) == "1 h")
        // 10 860 s / 60 = 181 min = 3 h 1 min.
        #expect(TourFormat.duration(10_860, language: .norwegian) == "3 t 1 min")
    }

    @Test func durationBoundaries() {
        // 20 s / 60 = 0.33 → would round to 0; a positive time shows at least 1 min.
        #expect(TourFormat.duration(20, language: .norwegian) == "1 min")
        #expect(TourFormat.duration(0, language: .norwegian) == "0 min")
        #expect(TourFormat.duration(-60, language: .english) == "0 min")
        #expect(TourFormat.duration(.nan, language: .english) == "0 min")
        #expect(TourFormat.duration(.infinity, language: .english) == "0 min")
        // Capped at 1e7 s: 1e7 / 60 = 166 666.67 → 166 667 min = 2777 h 47 min (2777 × 60 = 166 620; 166 667 − 166 620 = 47).
        #expect(TourFormat.duration(1e12, language: .english) == "2777 h 47 min")
    }

    // MARK: - Distance

    @Test func distanceUnderAKilometre() {
        // 847 m / 10 = 84.7 → 85 → 850 m; 5 m / 10 = 0.5 → 1 → 10 m; 994 m → 99.4 → 99 → 990 m.
        #expect(TourFormat.distance(847, language: .norwegian) == "850 m")
        #expect(TourFormat.distance(5, language: .norwegian) == "10 m")
        #expect(TourFormat.distance(994, language: .english) == "990 m")
    }

    @Test func distanceInKilometres() {
        // 5234 m / 100 = 52.34 → 52 tenths → 5,2 km / 5.2 km.
        #expect(TourFormat.distance(5234, language: .norwegian) == "5,2 km")
        #expect(TourFormat.distance(5234, language: .english) == "5.2 km")
        // 995 m / 10 = 99.5 → 100 → 1000 m, so kilometres: 995 / 100 = 9.95 → 10 tenths → 1,0 km.
        #expect(TourFormat.distance(995, language: .norwegian) == "1,0 km")
        // 12 345 m / 100 = 123.45 → 123 tenths → 12,3 km.
        #expect(TourFormat.distance(12_345, language: .norwegian) == "12,3 km")
        // 2050 m / 100 = 20.5 → 21 tenths → 2.1 km.
        #expect(TourFormat.distance(2050, language: .english) == "2.1 km")
    }

    @Test func distanceBoundaries() {
        #expect(TourFormat.distance(0, language: .norwegian) == "0 m")
        // 4 m / 10 = 0.4 → 0 → «0 m».
        #expect(TourFormat.distance(4, language: .norwegian) == "0 m")
        #expect(TourFormat.distance(-10, language: .english) == "0 m")
        #expect(TourFormat.distance(.nan, language: .english) == "0 m")
        // Capped at 1e7 m: 1e7 / 100 = 100 000 tenths → 10 000,0 km.
        #expect(TourFormat.distance(.infinity, language: .english) == "0 m")
        #expect(TourFormat.distance(1e15, language: .norwegian) == "10000,0 km")
    }

    // MARK: - Stops and totals

    @Test func stopCounts() {
        #expect(TourFormat.stops(6, language: .norwegian) == "6 stopp")
        #expect(TourFormat.stops(1, language: .norwegian) == "1 stopp")
        #expect(TourFormat.stops(1, language: .english) == "1 stop")
        #expect(TourFormat.stops(0, language: .english) == "0 stops")
        #expect(TourFormat.stops(-2, language: .english) == "0 stops")
    }

    @Test func totalsJoinTheParts() {
        // The spec's example: 5100 s = 1 t 25 min; 5200 m = 52 tenths = 5,2 km; 6 stopp.
        #expect(TourFormat.totals(seconds: 5100, metres: 5200, stops: 6, language: .norwegian)
            == "1 t 25 min · 5,2 km · 6 stopp")
        // 1800 s = 30 min; 2449 m / 100 = 24.49 → 24 tenths = 2.4 km.
        #expect(TourFormat.totals(seconds: 1800, metres: 2449, stops: 1, language: .english) == "30 min · 2.4 km · 1 stop")
    }
}
