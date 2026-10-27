import Testing
import Foundation
@testable import MyGuideCore

@Suite struct LocationFixTests {
    static let now = Date(timeIntervalSinceReferenceDate: 1_000)

    private func fix(accuracy: Double = 8, latitude: Double = 48.2082, longitude: Double = 16.3738,
                     age: TimeInterval = 5) -> LocationFix? {
        LocationFix.usable(latitude: latitude, longitude: longitude, horizontalAccuracy: accuracy,
                           timestamp: Self.now.addingTimeInterval(-age), now: Self.now)
    }

    @Test func freshValidFixIsUsable() {
        #expect(fix() == LocationFix(coordinate: Coordinate(latitude: 48.2082, longitude: 16.3738), accuracy: 8))
    }

    @Test func accuracySentinels() {
        #expect(fix(accuracy: -1) == nil)       // CoreLocation: negative = invalid fix
        #expect(fix(accuracy: 0)?.accuracy == 0) // boundary: 0 is a (perfect) valid fix
        #expect(fix(accuracy: .nan) == nil)
        #expect(fix(accuracy: .infinity) == nil)
    }

    @Test func ageBoundary() {
        // now = 1000 s; timestamp 940 → age 1000 − 940 = 60 (fresh, ≤ 60);
        // timestamp 939.999 → age 60.001 (stale, > 60)
        #expect(fix(age: 60) != nil)
        #expect(fix(age: 60.001) == nil)
        #expect(fix(age: -2) != nil) // a timestamp slightly in the future (clock skew) is not stale
    }

    @Test func invalidCoordinates() {
        #expect(fix(latitude: 90.5) == nil)
        #expect(fix(longitude: -180.5) == nil)
        #expect(fix(latitude: .nan) == nil)
        #expect(fix(latitude: -90, longitude: 180) != nil) // boundaries are valid
    }
}
