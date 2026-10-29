import Foundation
import Testing
@testable import MyGuideCore

@Suite struct TourAreaTests {
    static let mpd = Coordinate.metresPerDegree
    let rome = Coordinate(latitude: 41.8986, longitude: 12.4769)

    // MARK: - Loop radius (spec 4: min(2500, 1.3 × seconds / 2.5))

    @Test func loopRadiusFollowsTheDuration() {
        // 30 min: 1.3 × 1800 / 2.5 = 2340 / 2.5 = 936 m.
        #expect(TourArea.loop(from: rome, minutes: 30) == .loop(centre: rome, radius: 936))
        // 60 min: 1.3 × 3600 / 2.5 = 4680 / 2.5 = 1872 m.
        #expect(TourArea.loop(from: rome, minutes: 60) == .loop(centre: rome, radius: 1872))
        // 45 min: 1.3 × 2700 / 2.5 = 3510 / 2.5 = 1404 m.
        guard case .loop(_, let r45) = TourArea.loop(from: rome, minutes: 45) else { Issue.record("not a loop"); return }
        #expect(abs(r45 - 1404) < 1e-9)
    }

    @Test func loopRadiusIsCappedAt2500() {
        // 180 min: 1.3 × 10 800 / 2.5 = 14 040 / 2.5 = 5616 → min(2500, 5616) = 2500 m.
        #expect(TourArea.loop(from: rome, minutes: 180) == .loop(centre: rome, radius: 2500))
        // 90 min: 1.3 × 5400 / 2.5 = 7020 / 2.5 = 2808 → 2500 m.
        #expect(TourArea.loop(from: rome, minutes: 90) == .loop(centre: rome, radius: 2500))
        // The cap starts at 2500 × 2.5 / 1.3 = 4807.7 s ≈ 80.1 min: 80 min is 1.3 × 4800 / 2.5 = 2496 m, under it.
        guard case .loop(_, let r80) = TourArea.loop(from: rome, minutes: 80) else { Issue.record("not a loop"); return }
        #expect(abs(r80 - 2496) < 1e-9)
    }

    @Test func loopRadiusIsNeverNegative() {
        // 0 min: 1.3 × 0 / 2.5 = 0 m; −10 min is clamped to the same 0 m instead of a negative radius.
        #expect(TourArea.loop(from: rome, minutes: 0) == .loop(centre: rome, radius: 0))
        #expect(TourArea.loop(from: rome, minutes: -10) == .loop(centre: rome, radius: 0))
    }

    // MARK: - Corridor (spec 4: bbox of the line, padded by 30 % of its length)

    @Test func corridorPaddingIsThirtyPercentOfTheLength() {
        let a = Coordinate.at(), b = Coordinate.at(east: 1000)
        guard case .corridor(let from, let to, let padding) = TourArea.corridor(from: a, to: b) else {
            Issue.record("not a corridor"); return
        }
        #expect(from == a && to == b)
        // Length 1000 m on the equator → padding 0.3 × 1000 = 300 m.
        #expect(abs(padding - 300) < 1e-6)
    }

    @Test func corridorBoundingBoxOnTheEquator() {
        let box = TourArea.corridor(from: .at(east: 1000), to: .at()).boundingBox
        // Padding 300 m. On the equator cos(0) = 1, so 300 m is 300 / 111 194.93 = 0.002698° both ways:
        // south −0.002698, north +0.002698, west −0.002698, east (1000 + 300) / 111 194.93 = 0.011691°.
        #expect(abs(box.south - (-300 / Self.mpd)) < 1e-9)
        #expect(abs(box.north - 300 / Self.mpd) < 1e-9)
        #expect(abs(box.west - (-300 / Self.mpd)) < 1e-9)
        #expect(abs(box.east - 1300 / Self.mpd) < 1e-9)
    }

    @Test func corridorBoundingBoxWidensLongitudeByLatitude() {
        // A 1000 m north–south line along 10° E, ending at 60° N (meridian arc: exactly 1000 m by haversine).
        let a = Coordinate(latitude: 60 - 1000 / Self.mpd, longitude: 10), b = Coordinate(latitude: 60, longitude: 10)
        let box = TourArea.corridor(from: a, to: b).boundingBox
        // Padding 300 m. Latitude: 300 / 111 194.93 = 0.002698° below a and above b.
        #expect(abs(box.south - (60 - 1300 / Self.mpd)) < 1e-9)
        #expect(abs(box.north - (60 + 300 / Self.mpd)) < 1e-9)
        // Longitude at the line's highest latitude, 60°: cos 60° = 0.5, so 300 / (111 194.93 × 0.5) = 0.005396°.
        #expect(abs(box.west - (10 - 600 / Self.mpd)) < 1e-9)
        #expect(abs(box.east - (10 + 600 / Self.mpd)) < 1e-9)
        // And that is 300 m on the ground at 60° N (great circle vs parallel differs by far less than 1 cm here).
        #expect(abs(GeoMath.distance(b, Coordinate(latitude: 60, longitude: box.east)) - 300) < 0.01)
    }

    @Test func degenerateCorridorIsThePointItself() {
        let p = Coordinate.at(north: 50, east: 50)
        let area = TourArea.corridor(from: p, to: p)
        // Length 0 → padding 0 → the box is the point.
        let box = area.boundingBox
        #expect(box.south == p.latitude && box.north == p.latitude && box.west == p.longitude && box.east == p.longitude)
        #expect(area.contains(p))
        #expect(!area.contains(.at(north: 51, east: 50)))
    }

    @Test func loopBoundingBoxEnclosesTheCircle() {
        let box = TourArea.loop(centre: .at(), radius: 936).boundingBox
        // 936 / 111 194.93 = 0.008418° each way on the equator.
        #expect(abs(box.south + 936 / Self.mpd) < 1e-9 && abs(box.north - 936 / Self.mpd) < 1e-9)
        #expect(abs(box.west + 936 / Self.mpd) < 1e-9 && abs(box.east - 936 / Self.mpd) < 1e-9)
    }

    // MARK: - contains

    @Test func loopContainsByDistanceFromTheCentre() {
        let area = TourArea.loop(centre: .at(), radius: 936)
        #expect(area.contains(.at()))
        #expect(area.contains(.at(north: 935)))
        #expect(!area.contains(.at(north: 937)))
        // A box corner is outside the circle: √(900² + 900²) = 1272.8 m > 936 m, though it lies in the bounding box.
        #expect(!area.contains(.at(north: 900, east: 900)))
        #expect(area.contains(.at(north: -600, east: 600)))   // √(600² + 600²) = 848.5 m ≤ 936 m
    }

    @Test func corridorContainsByTheBoundingBox() {
        let area = TourArea.corridor(from: .at(), to: .at(east: 1000))
        // The box is −300…1300 m east and −300…300 m north.
        #expect(area.contains(.at(north: 299, east: -299)))
        #expect(area.contains(.at(north: -299, east: 1299)))
        #expect(area.contains(.at(east: 500)))
        #expect(!area.contains(.at(north: 301, east: 500)))
        #expect(!area.contains(.at(north: 0, east: 1301)))
        #expect(!area.contains(.at(north: 0, east: -301)))
    }

    // MARK: - Wikipedia geosearch tiles (≤ 4 tiles, radius ≤ 10 000 m)

    @Test func loopIsOneTileWithItsOwnRadius() {
        // 30 min → 936 m; the circle itself is the tile, not the box around it.
        #expect(TourArea.loop(from: rome, minutes: 30).wikipediaTiles == [GeosearchTile(centre: rome, radius: 936)])
        // 180 min → 2500 m.
        #expect(TourArea.loop(from: rome, minutes: 180).wikipediaTiles == [GeosearchTile(centre: rome, radius: 2500)])
    }

    @Test func shortCorridorIsOneTileReachingTheBoxCorners() throws {
        // Line 0 → 10 000 m east; padding 3000 m; box −3000…13 000 m east, −3000…3000 m north (16 km × 6 km).
        // One tile at the centre (5000 m east): half diagonal √(8000² + 3000²) = √73 000 000 = 8544.0 m ≤ 10 000 m.
        let tiles = TourArea.corridor(from: .at(), to: .at(east: 10_000)).wikipediaTiles
        let tile = try #require(tiles.count == 1 ? tiles.first : nil)
        #expect(abs(tile.centre.latitude) < 1e-12)
        #expect(abs(tile.centre.longitude - 5000 / Self.mpd) < 1e-9)
        // Rounded up to whole metres; the sphere differs from the plane by centimetres here.
        #expect((8544...8545).contains(tile.radius))
    }

    @Test func mediumCorridorSplitsAlongItsLongSide() throws {
        // Line 0 → 15 000 m east; padding 4500 m; box −4500…19 500 m east, ±4500 m north (24 km × 9 km).
        // 1 tile: √(12 000² + 4500²) = 12 816 m > 10 000. 2 along the long side, 12 km × 9 km each:
        // √(6000² + 4500²) = 7500 m ≤ 10 000 → 2 tiles at 1500 m and 13 500 m east.
        let tiles = TourArea.corridor(from: .at(), to: .at(east: 15_000)).wikipediaTiles
        #expect(tiles.count == 2)
        #expect(tiles.map { ($0.centre.longitude * Self.mpd).rounded() } == [1500, 13_500])
        #expect(tiles.allSatisfy { abs($0.centre.latitude) < 1e-12 && (7500...7501).contains($0.radius) })
    }

    @Test func longCorridorUsesFourTilesCappedAt10Km() {
        // Line 0 → 30 000 m east; padding 9000 m; box −9000…39 000 m east, ±9000 m north (48 km × 18 km).
        // Half diagonals: 1×1 √(24² + 9²) = 25.6 km; 2×1 √(12² + 9²) = 15.0; 3×1 √(8² + 9²) = 12.04;
        // 4×1 √(6² + 9²) = 10.82; 2×2 √(12² + 4.5²) = 12.8; 1×2 √(24² + 4.5²) = 24.4 km. None fits 10 km, so the
        // smallest, 4×1, at −3000, 9000, 21 000 and 33 000 m east, each capped at 10 000 m.
        let tiles = TourArea.corridor(from: .at(), to: .at(east: 30_000)).wikipediaTiles
        #expect(tiles.map { ($0.centre.longitude * Self.mpd).rounded() } == [-3000, 9000, 21_000, 33_000])
        #expect(tiles.allSatisfy { abs($0.centre.latitude) < 1e-12 && $0.radius == 10_000 })
    }

    @Test func northSouthCorridorSplitsAlongLatitude() {
        // Line 0 → 15 000 m north: the same 9 km × 24 km box turned, so 2 tiles at 1500 m and 13 500 m north.
        let tiles = TourArea.corridor(from: .at(), to: .at(north: 15_000)).wikipediaTiles
        #expect(tiles.map { ($0.centre.latitude * Self.mpd).rounded() } == [1500, 13_500])
        #expect(tiles.allSatisfy { abs($0.centre.longitude) < 1e-12 && (7500...7501).contains($0.radius) })
    }

    @Test func hugeLoopFallsBackToAGrid() {
        // Radius 12 000 m (only by building the case directly): the box is 24 km × 24 km.
        // 1×1 √(12² + 12²) = 16.97 km; 2×1 √(6² + 12²) = 13.4; 3×1 √(4² + 12²) = 12.6; 4×1 √(3² + 12²) = 12.4;
        // 2×2 √(6² + 6²) = 8.49 km ≤ 10 km → 4 tiles at (±6000, ±6000) m, south-west first, then by row.
        let tiles = TourArea.loop(centre: .at(), radius: 12_000).wikipediaTiles
        let metres = tiles.map { [($0.centre.latitude * Self.mpd).rounded(), ($0.centre.longitude * Self.mpd).rounded()] }
        #expect(metres == [[-6000, -6000], [-6000, 6000], [6000, -6000], [6000, 6000]])
        #expect(tiles.allSatisfy { (8485...8486).contains($0.radius) })
    }

    // MARK: - Overpass bounding box query

    @Test func overpassBoundingBoxQueryIsExact() {
        // Six decimals, rounded: 12.4812346 → 12.481235.
        let box = (south: 41.89, west: 12.47, north: 41.9, east: 12.4812346)
        #expect(OverpassClient.query(boundingBox: box) == """
        [out:json][timeout:10];
        (
          nwr(41.890000,12.470000,41.900000,12.481235)["historic"]["name"];
          nwr(41.890000,12.470000,41.900000,12.481235)["tourism"~"^(attraction|museum|artwork|viewpoint|gallery)$"]["name"];
          nwr(41.890000,12.470000,41.900000,12.481235)["amenity"="place_of_worship"]["name"];
          nwr(41.890000,12.470000,41.900000,12.481235)["building"]["name"]["wikidata"];
          nwr(41.890000,12.470000,41.900000,12.481235)["wikipedia"]["name"];
        );
        out center tags 500;
        """)
    }

    @Test func overpassBoundingBoxRequestUsesTheEndpointsInOrder() async throws {
        let http = StubHTTPClient { request in
            request.url?.host == "overpass-api.de" ? (504, Data()) : (200, Data(#"{"elements":[]}"#.utf8))
        }
        let box = (south: 41.89, west: 12.47, north: 41.9, east: 12.48)
        _ = try await OverpassClient(http: http).placesReportingEndpoints(in: box, language: .english)
        #expect(http.requests.map(\.url) == Array(OverpassClient.endpoints.prefix(2)))
        let body = String(decoding: http.requests[1].httpBody ?? Data(), as: UTF8.self).removingPercentEncoding ?? ""
        #expect(body.contains("nwr(41.890000,12.470000,41.900000,12.480000)[\"historic\"][\"name\"];"))
        #expect(http.requests.allSatisfy { $0.httpMethod == "POST" && $0.timeoutInterval == 12 })
    }

    // MARK: - Wikipedia geosearch limits

    @Test func wikipediaURLClampsToTheGeosearchMaximums() {
        let url = WikipediaClient.url(lang: "en", around: .init(latitude: 0, longitude: 0), radius: 25_000, limit: 900)
            .absoluteString
        #expect(url.contains("ggsradius=10000&ggslimit=500"))
        #expect(url.contains("colimit=500") && url.contains("exlimit=20"))
        // At the maximums nothing changes.
        let max = WikipediaClient.url(lang: "en", around: .init(latitude: 0, longitude: 0), radius: 10_000, limit: 500)
            .absoluteString
        #expect(max.contains("ggsradius=10000&ggslimit=500"))
        // Below the 10 m minimum (a corridor whose ends coincide has a 0 m tile): 10 m.
        let zero = WikipediaClient.url(lang: "en", around: .init(latitude: 0, longitude: 0), radius: 0).absoluteString
        #expect(zero.contains("ggsradius=10&ggslimit=20"))
        #expect(WikipediaClient.url(lang: "en", around: .init(latitude: 0, longitude: 0), radius: 10).absoluteString
            .contains("ggsradius=10&"))
    }
}
