import MapKit
import MyGuideCore
import Observation

/// A chosen A→B destination: what the owner picked and where it is.
struct TourDestination: Equatable, Sendable {
    var name: String
    var coordinate: Coordinate
}

/// The «Til et sted» search field's suggestions (tours spec 6): an `MKLocalSearchCompleter`, as in Apple Maps search,
/// biased to the owner's surroundings, and the lookup of a picked suggestion's position with `MKLocalSearch`.
@MainActor
@Observable
final class DestinationSearch: NSObject {
    /// One suggestion row. The completion stays on the main actor; MapKit objects are not Sendable.
    struct Suggestion: Identifiable {
        let id: Int
        let title: String
        let subtitle: String
        fileprivate let completion: MKLocalSearchCompletion
    }

    enum Status: Equatable {
        case idle
        case results
        /// MapKit found nothing for the text.
        case noResults
        /// MapKit failed (network, throttling, server).
        case failed
    }

    /// Rows shown under the field at most.
    nonisolated static let maxSuggestions = 6
    /// The completer looks within this many metres of the owner first (Apple Maps still offers places farther away).
    nonisolated static let biasSpan: CLLocationDistance = 20_000

    private(set) var suggestions: [Suggestion] = []
    private(set) var status: Status = .idle
    /// The text in the field; setting it asks the completer, and blank text clears the suggestions.
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                completer.cancel()
                suggestions = []
                status = .idle
            } else {
                completer.queryFragment = trimmed
            }
        }
    }

    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.resultTypes = [.address, .pointOfInterest]
        completer.delegate = self
    }

    /// Prefers places near `centre` from the next keystroke on.
    func bias(around centre: Coordinate) {
        completer.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: centre.latitude,
                                                                             longitude: centre.longitude),
                                              latitudinalMeters: Self.biasSpan, longitudinalMeters: Self.biasSpan)
    }

    /// Empties the field and the suggestions.
    func clear() {
        query = ""
    }

    /// The position of a picked suggestion; nil when MapKit finds no place for it, fails, or the caller is cancelled.
    func resolve(_ suggestion: Suggestion) async -> TourDestination? {
        let request = MKLocalSearch.Request(completion: suggestion.completion)
        request.resultTypes = [.address, .pointOfInterest]
        guard let response = try? await MKLocalSearch(request: request).start(), !Task.isCancelled,
              let item = response.mapItems.first else { return nil }
        let coordinate = item.location.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let name = item.name.flatMap { $0.isEmpty ? nil : $0 } ?? suggestion.title
        return TourDestination(name: name, coordinate: Coordinate(latitude: coordinate.latitude,
                                                                  longitude: coordinate.longitude))
    }

    /// Reads the completer's current results; it always matches the latest fragment, so a late callback for an
    /// older fragment cannot show stale rows.
    private func takeResults() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        suggestions = completer.results.prefix(Self.maxSuggestions).enumerated().map { index, completion in
            Suggestion(id: index, title: completion.title, subtitle: completion.subtitle, completion: completion)
        }
        status = suggestions.isEmpty ? .noResults : .results
    }

    private func takeFailure(notFound: Bool) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        suggestions = []
        status = notFound ? .noResults : .failed
    }
}

// The delegate is not documented to be called on the main thread; it only hops to the main actor and reads the
// completer there, so no MapKit object crosses threads.
extension DestinationSearch: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor [weak self] in self?.takeResults() }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        let ns = error as NSError
        let notFound = ns.domain == MKError.errorDomain && ns.code == Int(MKError.Code.placemarkNotFound.rawValue)
        Task { @MainActor [weak self] in self?.takeFailure(notFound: notFound) }
    }
}
