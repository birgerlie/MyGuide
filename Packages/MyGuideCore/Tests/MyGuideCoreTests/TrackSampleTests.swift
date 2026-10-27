import Foundation
import Testing
@testable import MyGuideCore

@Suite struct TrackSampleTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static let last = TrackSample(at: t0, coordinate: .at())

    static func sample(north: Double, after seconds: TimeInterval) -> TrackSample {
        TrackSample(at: t0 + seconds, coordinate: .at(north: north))
    }

    @Test func theFirstSampleIsAlwaysStored() {
        #expect(TrackSample.isWorthStoring(Self.sample(north: 0, after: 0), after: nil))
    }

    @Test func spacingDecides() {
        // Hand: 6 m from the last stored sample, 1 s later: 6 ≥ 5 → stored. 4 m, 1 s later: 4 < 5 and 1 < 60 → not.
        #expect(TrackSample.isWorthStoring(Self.sample(north: 6, after: 1), after: Self.last))
        #expect(!TrackSample.isWorthStoring(Self.sample(north: 4, after: 1), after: Self.last))
    }

    @Test func spacingBoundaryIsFiveMetres() {
        // Hand: `.at(north:)` is exact metres by haversine up to floating point, so test either side of 5 m:
        // 5.001 ≥ 5 → stored; 4.999 < 5 (and 10 s < 60 s) → not.
        #expect(TrackSample.isWorthStoring(Self.sample(north: 5.001, after: 10), after: Self.last))
        #expect(!TrackSample.isWorthStoring(Self.sample(north: 4.999, after: 10), after: Self.last))
    }

    @Test func standingStillStoresOneSampleAMinute() {
        // Hand: 0 m moved. 60 s later: 60 ≥ 60 → stored. 59 s later: 59 < 60 → not.
        #expect(TrackSample.isWorthStoring(Self.sample(north: 0, after: 60), after: Self.last))
        #expect(!TrackSample.isWorthStoring(Self.sample(north: 0, after: 59), after: Self.last))
    }

    @Test func aSampleFromBeforeTheLastCountsByDistanceOnly() {
        // Clock skew: −120 s is never ≥ 60 s. 2 m → not stored; 8 m → stored.
        #expect(!TrackSample.isWorthStoring(Self.sample(north: 2, after: -120), after: Self.last))
        #expect(TrackSample.isWorthStoring(Self.sample(north: 8, after: -120), after: Self.last))
    }

    @Test func oneFixASecondWhileWalkingIsThinned() {
        // 1.1 m/s for 20 s, one fix a second, starting with nothing stored. Hand: stored at 0 m (first); the next is
        // the first fix ≥ 5 m on: 5.5 m (s = 5); then ≥ 10.5 m: 11 m (s = 10); ≥ 16 m: 16.5 m (s = 15);
        // ≥ 21.5 m: 22 m (s = 20). Each is 0.5 m past the limit, far beyond floating-point error → 5 of 21 fixes.
        var stored: [TrackSample] = []
        for s in 0...20 {
            let sample = Self.sample(north: Double(s) * 1.1, after: Double(s))
            if TrackSample.isWorthStoring(sample, after: stored.last) { stored.append(sample) }
        }
        #expect(stored.map(\.at) == [0, 5, 10, 15, 20].map { Self.t0 + Double($0) })
    }
}
