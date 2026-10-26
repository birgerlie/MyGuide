import Testing
import Foundation
@testable import MyGuideCore

@Suite struct GeoMathTests {
    let origin = Coordinate(latitude: 0, longitude: 0)

    @Test func bearingCardinals() {
        // θ = atan2(sinΔλ·cosφ2, cosφ1·sinφ2 − sinφ1·cosφ2·cosΔλ)
        // (0,0)->(0,1):  atan2(sin1°, 0)   = 90°
        // (0,0)->(1,0):  atan2(0, sin1°)   = 0°
        // (0,0)->(-1,0): atan2(0, −sin1°)  = 180°
        // (0,0)->(0,-1): atan2(−sin1°, 0)  = −90° → 270°
        #expect(abs(GeoMath.bearing(from: origin, to: .init(latitude: 0, longitude: 1)) - 90) < 1e-9)
        #expect(abs(GeoMath.bearing(from: origin, to: .init(latitude: 1, longitude: 0)) - 0) < 1e-9)
        #expect(abs(GeoMath.bearing(from: origin, to: .init(latitude: -1, longitude: 0)) - 180) < 1e-9)
        #expect(abs(GeoMath.bearing(from: origin, to: .init(latitude: 0, longitude: -1)) - 270) < 1e-9)
    }
    @Test func distanceHaversine() {
        // Equator, Δλ=1°: d = R·π/180 = 6_371_000·0.0174532925 = 111_194.93 m
        #expect(abs(GeoMath.distance(origin, .init(latitude: 0, longitude: 1)) - 111_194.93) < 0.5)
        // Lat 60°, Δλ=1°: sin(c/2) = cos60°·sin(0.5°) = 0.5·0.00872654 = 0.00436327
        // c = 2·asin(0.00436327) = 0.00872657 rad; d = 0.00872657·6_371_000 = 55_596.97 m
        #expect(abs(GeoMath.distance(.init(latitude: 60, longitude: 0), .init(latitude: 60, longitude: 1)) - 55_596.97) < 1)
        #expect(GeoMath.distance(origin, origin) == 0)
    }
    @Test func angularDifferenceWraps() {
        // |350−10| = 340 → 360−340 = 20; symmetric; opposite = 180
        #expect(GeoMath.angularDifference(350, 10) == 20)
        #expect(GeoMath.angularDifference(10, 350) == 20)
        #expect(GeoMath.angularDifference(90, 270) == 180)
        #expect(GeoMath.angularDifference(0, 0) == 0)
    }
}
