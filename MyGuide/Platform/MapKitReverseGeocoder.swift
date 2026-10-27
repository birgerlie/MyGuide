import CoreLocation
import MapKit
import MyGuideCore

enum ReverseGeocodingFailure: Error, Equatable {
    /// MapKit rejected the location (`MKReverseGeocodingRequest(location:)` returned nil).
    case invalidLocation
    /// MapKit answered with no map items.
    case noResult
}

/// `ReverseGeocoding` via the iOS 26 `MKReverseGeocodingRequest`.
struct MapKitReverseGeocoder: ReverseGeocoding {
    func address(for coordinate: Coordinate) async throws -> Address {
        try await Self.lookup(coordinate)
    }

    /// MapKit objects are not Sendable; keep them on the main actor and hand back only the Sendable `Address`.
    @MainActor
    private static func lookup(_ coordinate: Coordinate) async throws -> Address {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else {
            throw ReverseGeocodingFailure.invalidLocation
        }
        // Not cancelled on task cancellation: the request is not Sendable and answers quickly;
        // GroundingService checks for cancellation after all sources return.
        let items = try await request.mapItems
        guard let item = items.first else { throw ReverseGeocodingFailure.noResult }
        return Address(line: nonEmpty(item.address?.shortAddress),
                       city: nonEmpty(item.addressRepresentations?.cityName),
                       country: nonEmpty(item.addressRepresentations?.regionName))
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
