import CoreLocation
import MapKit
import MyGuideCore

/// `PointsOfInterestSearching` via `MKLocalPointsOfInterestRequest`, limited to the categories of guide-voice spec 7.3.
struct MapKitPointsOfInterest: PointsOfInterestSearching {
    /// Spec 7.3's categories and the word each is listed with. "monument" is `.nationalMonument` and "market" is
    /// `.foodMarket`, the nearest MapKit has; "spring" has no MapKit category and is left out.
    private static let words: [MKPointOfInterestCategory: String] = [
        .museum: "museum", .landmark: "landmark", .castle: "castle", .fortress: "fortress",
        .nationalMonument: "monument", .park: "park", .nationalPark: "national park", .library: "library",
        .university: "university", .theater: "theater", .musicVenue: "music venue", .stadium: "stadium",
        .zoo: "zoo", .aquarium: "aquarium", .planetarium: "planetarium", .beach: "beach", .bakery: "bakery",
        .restaurant: "restaurant", .cafe: "café", .brewery: "brewery", .winery: "winery", .foodMarket: "market",
    ]

    func places(around center: Coordinate, radius: Double) async throws -> [ApplePlace] {
        try await Self.search(center, radius: radius)
    }

    /// MapKit objects are not Sendable; keep them on the main actor and hand back only Sendable `ApplePlace`s.
    /// Map items without a name, or (despite the filter) without one of our categories, are dropped.
    @MainActor
    private static func search(_ center: Coordinate, radius: Double) async throws -> [ApplePlace] {
        let request = MKLocalPointsOfInterestRequest(
            center: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude), radius: radius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: Array(words.keys))
        // Not cancelled on task cancellation: the search is not Sendable. `ApplePlaces.fetch` stops waiting for it
        // on cancellation or after its timeout.
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.compactMap { item in
            guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  let category = item.pointOfInterestCategory.flatMap({ words[$0] }) else { return nil }
            let coordinate = item.location.coordinate
            return ApplePlace(name: name, category: category,
                              coordinate: Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }
    }
}
