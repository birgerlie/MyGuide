import Foundation
import Testing
@testable import MyGuideCore

@Suite struct CompassPointTests {
    static let all: [CompassPoint] = [.north, .northEast, .east, .southEast, .south, .southWest, .west, .northWest]

    @Test func everyPointInEveryForm() {
        #expect(CompassPoint.allCases == Self.all)
        // The prompt word is today's English word, unchanged: the model reads it.
        #expect(Self.all.map(\.promptWord) == [
            "north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west",
        ])
        #expect(Self.all.map { $0.words(.english) } == [
            "north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west",
        ])
        #expect(Self.all.map { $0.words(.norwegian) } == [
            "nord", "nordøst", "øst", "sørøst", "sør", "sørvest", "vest", "nordvest",
        ])
        #expect(Self.all.map(\.abbreviation) == ["N", "NE", "E", "SE", "S", "SW", "W", "NW"])
    }

    @Test func sectorCentres() {
        // Centre of sector i is i · 45: 0 north, 45 north-east, …, 315 north-west.
        for (i, point) in Self.all.enumerated() {
            #expect(CompassPoint(degrees: Double(i) * 45) == point, "\(i * 45)")
        }
    }

    @Test func sectorEdges() {
        // index = Int((wrapped + 22.5) / 45) % 8.
        // 22.4 → 44.9 / 45 = 0.998 → 0 north; 22.5 → 45 / 45 = 1 → north-east (the lower edge belongs to the sector).
        #expect(CompassPoint(degrees: 22.4) == .north)
        #expect(CompassPoint(degrees: 22.5) == .northEast)
        // 337.4 → 359.9 / 45 = 7.998 → 7 north-west; 337.5 → 360 / 45 = 8 → 8 % 8 = 0 north.
        #expect(CompassPoint(degrees: 337.4) == .northWest)
        #expect(CompassPoint(degrees: 337.5) == .north)
        // 157.5 → 180 / 45 = 4 → south; 157.4 → 179.9 / 45 = 3.998 → 3 south-east.
        #expect(CompassPoint(degrees: 157.5) == .south)
        #expect(CompassPoint(degrees: 157.4) == .southEast)
    }

    @Test func anyAngleIsWrappedFirst() {
        // −10 → 350 → 372.5 / 45 = 8.28 → 8 % 8 = 0 north. 360 → 0 → north.
        #expect(CompassPoint(degrees: -10) == .north)
        #expect(CompassPoint(degrees: 360) == .north)
        // −90 → 270 → 292.5 / 45 = 6.5 → 6 west. 405 → 45 → north-east.
        #expect(CompassPoint(degrees: -90) == .west)
        #expect(CompassPoint(degrees: 405) == .northEast)
    }

    @Test func notFiniteIsNorth() {
        // Today's callers turn a non-finite bearing into 0 before asking; the type does the same instead of trapping.
        #expect(CompassPoint(degrees: .nan) == .north)
        #expect(CompassPoint(degrees: .infinity) == .north)
        #expect(CompassPoint(degrees: -.infinity) == .north)
    }

    @Test func fieldOfViewAndCaptureHUDUseIt() {
        for degrees in [-10.0, 0, 22.4, 22.5, 200, 337.5, 360] {
            #expect(FieldOfView.compassPoint(degrees) == CompassPoint(degrees: degrees).promptWord, "\(degrees)")
        }
    }
}

@Suite struct GeoMathWrapTests {
    @Test func signedOffsetIsInMinus180To180() {
        // r = (to − from) % 360, then > 180 → −360, ≤ −180 → +360.
        // 1 − 359 = −358 → +360 = 2. 350 − 10 = 340 → −360 = −20.
        #expect(GeoMath.signedOffset(from: 359, to: 1) == 2)
        #expect(GeoMath.signedOffset(from: 10, to: 350) == -20)
        // 180 stays 180; 0 − 180 = −180 → +360 = 180, so −180 never comes out.
        #expect(GeoMath.signedOffset(from: 0, to: 180) == 180)
        #expect(GeoMath.signedOffset(from: 180, to: 0) == 180)
        #expect(GeoMath.signedOffset(from: 0, to: -180) == 180)
        // 540 % 360 = 180 → 180; −540 % 360 = −180 → 180; 30 − (−720) = 750 % 360 = 30.
        #expect(GeoMath.signedOffset(from: 0, to: 540) == 180)
        #expect(GeoMath.signedOffset(from: 0, to: -540) == 180)
        #expect(GeoMath.signedOffset(from: -720, to: 30) == 30)
        // Just past 180: 180.5 → −179.5. Just past −180: −180.5 → 179.5.
        #expect(GeoMath.signedOffset(from: 0, to: 180.5) == -179.5)
        #expect(GeoMath.signedOffset(from: 0, to: -180.5) == 179.5)
        #expect(GeoMath.signedOffset(from: 0, to: .nan).isNaN)
    }

    @Test func placeSelectorOffsetIsTheSame() {
        for (heading, bearing) in [(359.0, 1.0), (10, 350), (0, 180), (180, 0), (90, 90), (-30, 400)] {
            #expect(PlaceSelector.offset(heading: heading, bearing: bearing)
                    == GeoMath.signedOffset(from: heading, to: bearing), "\(heading) → \(bearing)")
        }
    }

    @Test func normalizedDegreesIsIn0To360() {
        // (d % 360 + 360) % 360: −10 → 350; 360 → 0; −360 → −0 + 360 = 360 → 0; 720.5 → 0.5; 0 → 0.
        #expect(GeoMath.normalizedDegrees(-10) == 350)
        #expect(GeoMath.normalizedDegrees(360) == 0)
        #expect(GeoMath.normalizedDegrees(-360) == 0)
        #expect(GeoMath.normalizedDegrees(720.5) == 0.5)
        #expect(GeoMath.normalizedDegrees(0) == 0)
        #expect(GeoMath.normalizedDegrees(359.5) == 359.5)
    }
}
