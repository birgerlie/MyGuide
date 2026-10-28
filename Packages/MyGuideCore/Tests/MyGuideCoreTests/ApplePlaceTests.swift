import Testing
import Foundation
@testable import MyGuideCore

@Suite struct ApplePlaceTests {
    static let here = Coordinate(latitude: 59.9, longitude: 10.7)

    /// A place `metresNorth` north of `here`.
    static func place(_ name: String, metresNorth: Double = 0, category: String = "museum") -> ApplePlace {
        let dLat = metresNorth / GeoMath.earthRadius * 180 / .pi
        return ApplePlace(name: name, category: category,
                          coordinate: Coordinate(latitude: here.latitude + dLat, longitude: here.longitude))
    }

    struct StubSearch: PointsOfInterestSearching {
        let body: @Sendable () async throws -> [ApplePlace]
        func places(around: Coordinate, radius: Double) async throws -> [ApplePlace] { try await body() }
    }
    struct Boom: Error {}

    // MARK: select

    @Test func sortsNearestFirst() {
        let far = Self.place("Far", metresNorth: 100)
        let near = Self.place("Near", metresNorth: 10)
        let mid = Self.place("Mid", metresNorth: 50)
        #expect(ApplePlaces.select([far, near, mid], from: Self.here, knownNames: []).map(\.name) == ["Near", "Mid", "Far"])
    }

    @Test func capsAtLimitKeepingTheNearest() {
        // Place i is i * 10 m north (i = 1...10); the two farthest (90 m, 100 m) are cut, leaving 10...80 m.
        let places = (1...10).reversed().map { Self.place("P\($0)", metresNorth: Double($0) * 10) }
        let result = ApplePlaces.select(places, from: Self.here, knownNames: [])
        #expect(ApplePlaces.limit == 8)
        #expect(result.map(\.name) == (1...8).map { "P\($0)" })
    }

    @Test func fewerThanLimitAreAllKept() {
        let places = [Self.place("A", metresNorth: 5), Self.place("B", metresNorth: 6)]
        #expect(ApplePlaces.select(places, from: Self.here, knownNames: []).count == 2)
    }

    @Test func emptyInputGivesEmpty() {
        #expect(ApplePlaces.select([], from: Self.here, knownNames: ["x"]).isEmpty)
    }

    @Test func equalDistancesKeepInputOrder() {
        let places = ["C", "A", "B", "D"].map { Self.place($0, metresNorth: 20) }
        #expect(ApplePlaces.select(places, from: Self.here, knownNames: []).map(\.name) == ["C", "A", "B", "D"])
    }

    @Test func dropsKnownNamesIgnoringCase() {
        let places = [Self.place("Oslo domkirke", metresNorth: 10), Self.place("Other", metresNorth: 20)]
        #expect(ApplePlaces.select(places, from: Self.here, knownNames: ["OSLO DOMKIRKE"]).map(\.name) == ["Other"])
    }

    @Test func dropsKnownNamesIgnoringDiacritics() {
        let places = [Self.place("Café Ål", metresNorth: 10), Self.place("Other", metresNorth: 20)]
        #expect(ApplePlaces.select(places, from: Self.here, knownNames: ["cafe al"]).map(\.name) == ["Other"])
    }

    @Test func dropsKnownNamesIgnoringSurroundingWhitespace() {
        let places = [Self.place("  Tower \n", metresNorth: 10), Self.place("Other", metresNorth: 20)]
        #expect(ApplePlaces.select(places, from: Self.here, knownNames: ["tower  "]).map(\.name) == ["Other"])
    }

    @Test func dropsBeforeCapping() {
        // Eleven places; the nearest two are known, so the cap applies to the remaining nine and keeps 8.
        let places = (1...11).map { Self.place("P\($0)", metresNorth: Double($0) * 10) }
        let result = ApplePlaces.select(places, from: Self.here, knownNames: ["p1", "p2"])
        #expect(result.map(\.name) == (3...10).map { "P\($0)" })
    }

    @Test func blankNamesNeverMatchBlankKnownNames() {
        let places = [Self.place("   ", metresNorth: 10), Self.place("", metresNorth: 20)]
        #expect(ApplePlaces.select(places, from: Self.here, knownNames: ["", "  ", "\n"]).count == 2)
    }

    @Test func nonMatchingNamesAreKept() {
        let places = [Self.place("Oslo domkirke", metresNorth: 10)]
        #expect(ApplePlaces.select(places, from: Self.here, knownNames: ["Oslo domkirke kirkegård"]).count == 1)
    }

    // MARK: fetch

    @Test func fetchWithoutSearcherIsNil() async throws {
        #expect(try await ApplePlaces.fetch(nil, around: Self.here, radius: 150) == nil)
    }

    @Test func fetchReturnsThePlaces() async throws {
        let expected = [Self.place("A", metresNorth: 5)]
        let search = StubSearch { expected }
        #expect(try await ApplePlaces.fetch(search, around: Self.here, radius: 150) == expected)
    }

    @Test func fetchPassesAroundAndRadius() async throws {
        final class Box: @unchecked Sendable { var seen: (Coordinate, Double)? }
        struct Recorder: PointsOfInterestSearching {
            let box: Box
            func places(around: Coordinate, radius: Double) async throws -> [ApplePlace] {
                box.seen = (around, radius); return []
            }
        }
        let box = Box()
        _ = try await ApplePlaces.fetch(Recorder(box: box), around: Self.here, radius: 250)
        #expect(box.seen?.0 == Self.here)
        #expect(box.seen?.1 == 250)
    }

    @Test func fetchThrowingSearchIsNil() async throws {
        let search = StubSearch { throw Boom() }
        #expect(try await ApplePlaces.fetch(search, around: Self.here, radius: 150) == nil)
    }

    @Test func fetchTimeoutIsNil() async throws {
        let search = StubSearch { try await Task.sleep(for: .seconds(30)); return [] }
        let started = ContinuousClock.now
        let result = try await ApplePlaces.fetch(search, around: Self.here, radius: 150, timeout: .milliseconds(50))
        #expect(result == nil)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func fetchCancellationPropagates() async {
        let search = StubSearch { try await Task.sleep(for: .seconds(30)); return [] }
        let task = Task { try await ApplePlaces.fetch(search, around: Self.here, radius: 150) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func fetchCancellationFromSearcherErrorPropagates() async {
        let search = StubSearch { throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            _ = try await ApplePlaces.fetch(search, around: Self.here, radius: 150)
        }
    }

    // MARK: type

    @Test func defaults() {
        #expect(ApplePlaces.walkingRadius == 150)
        #expect(ApplePlaces.photoRadius == 250)
        #expect(ApplePlaces.timeout == .seconds(8))
    }

    @Test func codableRoundTrip() throws {
        let p = Self.place("Café Ål", metresNorth: 12, category: "café")
        let back = try JSONDecoder().decode(ApplePlace.self, from: JSONEncoder().encode(p))
        #expect(back == p)
    }
}
