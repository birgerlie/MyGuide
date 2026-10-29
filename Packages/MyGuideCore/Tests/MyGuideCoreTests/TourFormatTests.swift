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
        #expect(TourFormat.distance(.infinity, language: .english) == "0 m")
        // Capped at 1e7 m: 1e7 / 100 = 100 000 tenths → 10 000,0 km.
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
    // MARK: - During a tour

    @Test func approachDistanceInFiftyMetreSteps() {
        // 312 / 50 = 6.24 → 6 → 300 m; 326 / 50 = 6.52 → 7 → 350 m; 974 / 50 = 19.48 → 19 → 950 m.
        #expect(TourFormat.approachDistance(312, language: .norwegian) == "300 m")
        #expect(TourFormat.approachDistance(326, language: .english) == "350 m")
        #expect(TourFormat.approachDistance(974, language: .norwegian) == "950 m")
        // 20 / 50 = 0.4 → 0, but a positive distance shows at least 50 m.
        #expect(TourFormat.approachDistance(20, language: .norwegian) == "50 m")
        // 975 / 50 = 19.5 → 20 → 1000 m, so kilometres: 975 / 100 = 9.75 → 10 tenths → 1,0 km (where `distance` still
        // says 980 m: its 10 m steps reach 1000 m only from 995 m).
        #expect(TourFormat.approachDistance(975, language: .norwegian) == "1,0 km")
        // 1530 / 100 = 15.3 → 15 tenths → 1.5 km.
        #expect(TourFormat.approachDistance(1530, language: .english) == "1.5 km")
        #expect(TourFormat.approachDistance(0, language: .english) == "0 m")
        #expect(TourFormat.approachDistance(-5, language: .english) == "0 m")
        #expect(TourFormat.approachDistance(.nan, language: .english) == "0 m")
        #expect(TourFormat.approachDistance(.infinity, language: .english) == "0 m")
    }

    @Test func nextStopLine() {
        // 312 m → 300 m, as above.
        #expect(TourFormat.nextStop("Pantheon", metres: 312, language: .norwegian) == "Neste: Pantheon · 300 m")
        #expect(TourFormat.nextStop("Pantheon", metres: 312, language: .english) == "Next: Pantheon · 300 m")
        // No position: the name alone.
        #expect(TourFormat.nextStop("Pantheon", metres: nil, language: .norwegian) == "Neste: Pantheon")
        #expect(TourFormat.nextStop("Pantheon", metres: nil, language: .english) == "Next: Pantheon")
    }

    @Test func progressLine() {
        #expect(TourFormat.progress(done: 2, total: 6, language: .norwegian) == "2 av 6")
        #expect(TourFormat.progress(done: 2, total: 6, language: .english) == "2 of 6")
        #expect(TourFormat.progress(done: -1, total: -3, language: .english) == "0 of 0")
    }

    @Test func finishedLine() {
        // 5460 s / 60 = 91 min = 1 t 31 min (the spec's example).
        #expect(TourFormat.finished(stops: 6, seconds: 5460, language: .norwegian)
            == "Turen er ferdig · 6 stopp · 1 t 31 min")
        #expect(TourFormat.finished(stops: 6, seconds: 5460, language: .english)
            == "Tour finished · 6 stops · 1 h 31 min")
        // 1500 s / 60 = 25 min.
        #expect(TourFormat.finished(stops: 1, seconds: 1500, language: .english) == "Tour finished · 1 stop · 25 min")
        // No stop visited: said as it is. 1500 s = 25 min.
        #expect(TourFormat.finished(stops: 0, seconds: 1500, language: .norwegian)
            == "Turen er avsluttet · ingen stopp besøkt · 25 min")
        #expect(TourFormat.finished(stops: 0, seconds: 1500, language: .english) == "Tour ended · no stops visited · 25 min")
    }

    @Test func approachSteps() {
        // 312 / 50 = 6.24 → 6; 326 / 50 = 6.52 → 7; 20 / 50 = 0.4 → 0 → at least 1.
        #expect(TourFormat.approachStep(312) == 6)
        #expect(TourFormat.approachStep(326) == 7)
        #expect(TourFormat.approachStep(20) == 1)
        // 1530 / 50 = 30.6 → 31.
        #expect(TourFormat.approachStep(1530) == 31)
        #expect(TourFormat.approachStep(0) == nil)
        #expect(TourFormat.approachStep(-1) == nil)
        #expect(TourFormat.approachStep(.nan) == nil)
        // Capped at 1e7 m: 1e7 / 50 = 200 000.
        #expect(TourFormat.approachStep(1e12) == 200_000)
    }
}
