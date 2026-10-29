import CoreLocation
import MapKit
import MyGuideCore

/// Walking routes for tours (spec 5): one `MKDirections` walking request per leg, at most 25 per tour, each given 10 s.
enum TourRouter {
    /// Global constraint: at most 25 `MKDirections` requests per tour.
    static let maxRequests = 25
    static let requestTimeout: Duration = .seconds(10)

    /// Checks `plan` against walking routes and trims it to its budget (`TourRouting.fit`). Legs that fail, time out or
    /// fall past the request cap are straight lines, and the tour is then marked approximate.
    static func fit(_ plan: TourPlan) async -> RoutedTour {
        await TourRouting.fit(plan, maxRequests: maxRequests) { from, to in await leg(from: from, to: to) }
    }

    /// The walking route from `from` to `to`: MapKit's travel time and distance and the polyline's coordinates. Nil on a
    /// MapKit error, an answer without a route, after 10 s, or when the caller is cancelled.
    static func leg(from: Coordinate, to: Coordinate) async -> RoutedLeg? {
        await Deadline.value(within: requestTimeout) { await route(from, to) }
    }

    /// MapKit objects are not Sendable; keep them on the main actor and hand back only the Sendable `RoutedLeg`.
    @MainActor
    private static func route(_ from: Coordinate, _ to: Coordinate) async -> RoutedLeg? {
        let request = MKDirections.Request()
        request.source = mapItem(from)
        request.destination = mapItem(to)
        request.transportType = .walking
        request.requestsAlternateRoutes = false
        // Not cancelled on task cancellation: the directions object is not Sendable. `Deadline` stops waiting for it
        // on cancellation or after the timeout, and drops a late answer. A MapKit error (offline, throttled, no route)
        // makes the leg a straight one in `TourRouting`, so its detail is not needed here.
        guard let response = try? await MKDirections(request: request).calculate(),
              let route = response.routes.first else { return nil }
        return RoutedLeg(seconds: route.expectedTravelTime, metres: route.distance,
                         path: coordinates(of: route.polyline), approximate: false)
    }

    @MainActor
    private static func mapItem(_ coordinate: Coordinate) -> MKMapItem {
        MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
    }

    @MainActor
    private static func coordinates(of polyline: MKPolyline) -> [Coordinate] {
        let count = polyline.pointCount
        guard count > 0 else { return [] }
        var points = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        polyline.getCoordinates(&points, range: NSRange(location: 0, length: count))
        return points.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
    }
}
