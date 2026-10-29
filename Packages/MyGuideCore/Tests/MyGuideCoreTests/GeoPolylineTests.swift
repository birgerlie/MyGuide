import Foundation
import Testing
@testable import MyGuideCore

@Suite struct GeoPolylineTests {
    /// On the equator a degree of latitude and of longitude are both R × π / 180 = 111 194.93 m, and the projection
    /// is exact, so offsets in metres are easy to place by hand.
    static let metresPerDegree = 6_371_000.0 * .pi / 180

    static func point(north: Double, east: Double = 0) -> Coordinate {
        Coordinate(latitude: north / metresPerDegree, longitude: east / metresPerDegree)
    }

    @Test func shortPathsAreUnchanged() {
        #expect(GeoPolyline.simplified([], tolerance: 3).isEmpty)
        let one = [Self.point(north: 0)]
        #expect(GeoPolyline.simplified(one, tolerance: 3) == one)
        let two = [Self.point(north: 0), Self.point(north: 100)]
        #expect(GeoPolyline.simplified(two, tolerance: 3) == two)
    }

    @Test func collinearPointsCollapseToTheEnds() {
        let line = (0...3).map { Self.point(north: Double($0) * 100) }
        #expect(GeoPolyline.simplified(line, tolerance: 3) == [line[0], line[3]])
    }

    @Test func aBendBeyondTheToleranceIsKept() {
        // 0 → (100 N, 10 E) → 200 N: the middle point is 10 m from the line 0–200 N, > 3 m → kept.
        let path = [Self.point(north: 0), Self.point(north: 100, east: 10), Self.point(north: 200)]
        #expect(GeoPolyline.simplified(path, tolerance: 3) == path)
    }

    @Test func aWobbleWithinTheToleranceIsDropped() {
        // The middle point is 2 m from the line, ≤ 3 m → dropped.
        let path = [Self.point(north: 0), Self.point(north: 100, east: 2), Self.point(north: 200)]
        #expect(GeoPolyline.simplified(path, tolerance: 3) == [path[0], path[2]])
    }

    @Test func onlyTheFarPointOfSeveralIsKept() {
        // 0, (50 N, 1 E), (100 N, 20 E), (150 N, 1 E), 200 N. Against 0–200 N the farthest is (100, 20 E) at 20 m:
        // kept. Then (50, 1 E) against 0–(100, 20 E): the line runs 20 E per 100 N, so at 50 N it is 10 E; the point
        // is 9 m west of it, perpendicular 9 × 100 / √(100² + 20²) = 900 / 101.98 = 8.83 m > 3 → kept. Likewise
        // (150, 1 E) against (100, 20 E)–200 N: the line is at 10 E at 150 N, 9 m off → 8.83 m → kept.
        let path = [Self.point(north: 0), Self.point(north: 50, east: 1), Self.point(north: 100, east: 20),
                    Self.point(north: 150, east: 1), Self.point(north: 200)]
        #expect(GeoPolyline.simplified(path, tolerance: 3) == path)
        // With a 10 m tolerance the two 8.83 m points go, the 20 m point stays.
        #expect(GeoPolyline.simplified(path, tolerance: 10) == [path[0], path[2], path[4]])
    }

    @Test func aDetourBeyondTheSegmentEndIsMeasuredToTheEnd() {
        // 0 → 100 N → 300 N, then back to 200 N: the point 300 N lies on the line 0–200 N extended, 100 m past its
        // end. Its distance to the segment is 100 m (to the end), not 0 (to the infinite line) → kept.
        let path = [Self.point(north: 0), Self.point(north: 300), Self.point(north: 200)]
        #expect(GeoPolyline.simplified(path, tolerance: 3) == path)
    }

    @Test func aClosedLoopKeepsItsShape() {
        // A square of 100 m that ends where it starts: the ends coincide, so distances are to that point.
        let square = [Self.point(north: 0), Self.point(north: 100), Self.point(north: 100, east: 100),
                      Self.point(north: 0, east: 100), Self.point(north: 0)]
        #expect(GeoPolyline.simplified(square, tolerance: 3) == square)
    }

    @Test func aToleranceThatIsNotPositiveChangesNothing() {
        let line = (0...3).map { Self.point(north: Double($0) * 100) }
        #expect(GeoPolyline.simplified(line, tolerance: 0) == line)
        #expect(GeoPolyline.simplified(line, tolerance: -1) == line)
        #expect(GeoPolyline.simplified(line, tolerance: .nan) == line)
    }
}
