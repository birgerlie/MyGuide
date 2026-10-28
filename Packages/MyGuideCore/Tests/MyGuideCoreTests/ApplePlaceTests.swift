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

    @Test func foodComesAfterEveryOtherCategory() {
        // A restaurant 10 m away and a bakery 15 m away rank after a museum 100 m and a park 120 m away.
        let places = [Self.place("Restaurant", metresNorth: 10, category: "restaurant"),
                      Self.place("Museum", metresNorth: 100),
                      Self.place("Bakery", metresNorth: 15, category: "bakery"),
                      Self.place("Park", metresNorth: 120, category: "park")]
        #expect(ApplePlaces.select(places, from: Self.here, knownNames: []).map(\.name)
                == ["Museum", "Park", "Restaurant", "Bakery"])
    }

    @Test func foodIsCappedAtTwoNearestFirst() {
        // Four cafés at 40, 10, 30, 20 m and one park at 50 m: the park, then the two nearest cafés (10 m, 20 m).
        let cafes = [40.0, 10, 30, 20].map { Self.place("C\(Int($0))", metresNorth: $0, category: "café") }
        let places = cafes + [Self.place("Park", metresNorth: 50, category: "park")]
        #expect(ApplePlaces.foodLimit == 2)
        #expect(ApplePlaces.select(places, from: Self.here, knownNames: []).map(\.name) == ["Park", "C10", "C20"])
    }

    @Test func foodOnlyStillGivesTwo() {
        let places = (1...5).map { Self.place("F\($0)", metresNorth: Double($0) * 10, category: "market") }
        #expect(ApplePlaces.select(places, from: Self.here, knownNames: []).map(\.name) == ["F1", "F2"])
    }

    @Test func totalStaysAtTheLimitWithFood() {
        // Seven others (100…700 m) and three food places (1…3 m): 7 others + min(2, 8 − 7 = 1) food = 8.
        let others = (1...7).map { Self.place("O\($0)", metresNorth: Double($0) * 100, category: "landmark") }
        let food = (1...3).map { Self.place("F\($0)", metresNorth: Double($0), category: "winery") }
        let result = ApplePlaces.select(food + others, from: Self.here, knownNames: [])
        #expect(result.map(\.name) == (1...7).map { "O\($0)" } + ["F1"])
        // Ten others: 8 others + min(2, 8 − 8 = 0) food = 8, no food at all.
        let ten = (1...10).map { Self.place("O\($0)", metresNorth: Double($0) * 100, category: "park") }
        #expect(ApplePlaces.select(food + ten, from: Self.here, knownNames: []).map(\.name) == (1...8).map { "O\($0)" })
    }

    @Test func everyFoodWordCountsAsFoodWhateverItsCaseOrAccent() {
        // Each of these is food, so with two parks farther away only the two nearest food places follow the parks.
        for word in ["bakery", "restaurant", "café", "cafe", "CAFÉ", "brewery", "winery", "market"] {
            let places = (1...3).map { Self.place("F\($0)", metresNorth: Double($0), category: word) }
                + [Self.place("P1", metresNorth: 100, category: "park"), Self.place("P2", metresNorth: 200, category: "park")]
            #expect(ApplePlaces.select(places, from: Self.here, knownNames: []).map(\.name) == ["P1", "P2", "F1", "F2"],
                    "\(word)")
        }
        // Other categories keep the plain nearest-first order.
        let other = [Self.place("X", metresNorth: 1, category: "theater"), Self.place("Y", metresNorth: 2, category: "music venue")]
        #expect(ApplePlaces.select(other, from: Self.here, knownNames: []).map(\.name) == ["X", "Y"])
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
