import Testing
@testable import MyGuideCore

struct MapFocusTests {
    @Test func placeEastOfTheOwnerWidensTheEastWestSpan() {
        // Δlon 0.01° at 59.91°N: 0.01 · 111 320 · cos 59.91° = 1113.2 · 0.50136 ≈ 558.1 m; · 1.6 ≈ 893.0 m.
        // Δlat 0 → 0 · 1.6 = 0 → the 600 m floor.
        let f = MapFocus.frame(owner: Coordinate(latitude: 59.91, longitude: 10.75),
                               place: Coordinate(latitude: 59.91, longitude: 10.76))
        #expect(abs(f.centre.latitude - 59.91) < 1e-9 && abs(f.centre.longitude - 10.755) < 1e-9)
        #expect(abs(f.eastWestMetres - 893.0) < 1)
        #expect(f.northSouthMetres == 600)
    }

    @Test func placeNorthOfTheOwnerWidensTheNorthSouthSpan() {
        // Δlat 0.006°: 0.006 · 111 320 = 667.92 m; · 1.6 = 1068.67 m. Δlon 0 → the 600 m floor.
        let f = MapFocus.frame(owner: Coordinate(latitude: 41.8925, longitude: 12.4853),
                               place: Coordinate(latitude: 41.8985, longitude: 12.4853))
        #expect(abs(f.centre.latitude - 41.8955) < 1e-9)
        #expect(abs(f.northSouthMetres - 1068.67) < 0.1)
        #expect(f.eastWestMetres == 600)
    }

    @Test func aCloseCallNeverZoomsInPastTheOwnerFraming() {
        // Δlat 0.003°: 333.96 m · 1.6 = 534.3 m < 600 → 600 (boundary just under the floor).
        let close = MapFocus.frame(owner: Coordinate(latitude: 41.8925, longitude: 12.4853),
                                   place: Coordinate(latitude: 41.8955, longitude: 12.4853))
        #expect(close.northSouthMetres == 600 && close.eastWestMetres == 600)
        // The same spot as the owner: both floors, centred on it.
        let same = MapFocus.frame(owner: Coordinate(latitude: 1, longitude: 2), place: Coordinate(latitude: 1, longitude: 2))
        #expect(same == MapFocus.Frame(centre: Coordinate(latitude: 1, longitude: 2), northSouthMetres: 600, eastWestMetres: 600))
    }

    @Test func withoutTheOwnerThePlaceIsFramedAlone() {
        let place = Coordinate(latitude: 59.91, longitude: 10.76)
        #expect(MapFocus.frame(owner: nil, place: place)
                == MapFocus.Frame(centre: place, northSouthMetres: 600, eastWestMetres: 600))
    }
}
