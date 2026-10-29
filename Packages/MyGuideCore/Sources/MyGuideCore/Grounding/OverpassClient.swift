import Foundation
import os

/// Fetches named historic places and buildings near a point from OpenStreetMap via Overpass.
public struct OverpassClient: Sendable {
    /// The main Overpass server, then two others, each tried once in this order when the one before fails (spec 13.6,
    /// 18).
    static let endpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
        URL(string: "https://maps.mail.ru/osm/tools/overpass/api/interpreter")!,
    ]
    static let userAgent = "MyGuide/0.1 (https://github.com/birgerlie/MyGuide)"

    private static let excludedAmenities: Set<String> = [
        "restaurant", "cafe", "bar", "pub", "fast_food", "ice_cream", "biergarten",
    ]

    /// The only OSM tag keys kept on a candidate; `PlaceTiers` classifies from these.
    static let keptTagKeys: Set<String> = [
        "historic", "tourism", "amenity", "building", "memorial", "man_made", "railway", "public_transport",
        "place", "office", "castle_type", "bridge", "highway", "heritage",
        // Facts for the guide prompt; they never change a place's tier.
        "start_date", "architect", "building:architecture", "inscription", "description", "artist_name",
        "name:etymology", "wikidata", "heritage:operator", "memorial:type", "material",
    ]

    private static let log = Logger(subsystem: "io.github.birgerlie.MyGuide", category: "overpass")

    private let http: HTTPClient

    public init(http: HTTPClient) {
        self.http = http
    }

    static func query(around: Coordinate, radius: Int) -> String {
        // String(format:) with %f uses the POSIX decimal point regardless of the user's locale.
        let a = "around:\(radius),\(String(format: "%.6f", around.latitude)),\(String(format: "%.6f", around.longitude))"
        return """
        [out:json][timeout:10];
        (
          nwr(\(a))["historic"]["name"];
          nwr(\(a))["tourism"~"^(attraction|museum|artwork|viewpoint|gallery)$"]["name"];
          nwr(\(a))["amenity"="place_of_worship"]["name"];
          nwr(\(a))["building"]["name"]["wikidata"];
          nwr(\(a))["wikipedia"]["name"];
        );
        out center tags 500;
        """
    }

    /// The request timeout (seconds) of the walking query, and of the tour query, whose server timeout is 25 s.
    static let walkingTimeout: TimeInterval = 12
    static let tourTimeout: TimeInterval = 30

    /// The tour query's caps: ways and relations (the buildings: churches, castles, museums) are printed first, up
    /// to `tourAreaCap`, then nodes up to `tourNodeCap`. A dense centre's many small nodes (statues, memorials) can
    /// then never crowd the buildings out of the result, and the two caps together keep the old single cap of 2000.
    public static let tourAreaCap = 800
    public static let tourNodeCap = 1200

    /// Memorial kinds too small for a tour stop; the tour query leaves them out on the server (`PlaceTiers` never
    /// makes them top or good either). Stolpersteine alone run to hundreds in a city centre.
    static let minorMemorials = "plaque|stolperstein|stolperschwelle"

    /// The tour query: a box (Overpass order: south, west, north, east) is far bigger than walking mode's 500 m, so
    /// only the kinds of places that can become tour stops are asked for, without minor memorials, with a longer
    /// server timeout. The set is printed in two parts, ways and relations first (`tourAreaCap`), then nodes
    /// (`tourNodeCap`); `out center tags` gives a node its own position and a way or relation its centre.
    static func tourQuery(boundingBox box: (south: Double, west: Double, north: Double, east: Double)) -> String {
        // String(format:) with %f uses the POSIX decimal point regardless of the user's locale.
        let b = [box.south, box.west, box.north, box.east].map { String(format: "%.6f", $0) }.joined(separator: ",")
        return """
        [out:json][timeout:25];
        (
          nwr(\(b))["historic"]["name"]["memorial"!~"^(\(minorMemorials))$"];
          nwr(\(b))["tourism"~"^(museum|attraction|gallery)$"]["name"];
          nwr(\(b))["amenity"="place_of_worship"]["name"];
          nwr(\(b))["building"~"^(cathedral|palace|castle)$"]["name"];
        )->.a;
        (way.a; rel.a;);
        out center tags \(tourAreaCap);
        node.a;
        out center tags \(tourNodeCap);
        """
    }

    /// The places from the first endpoint; when it fails (HTTP error, timeout, malformed answer, runtime remark) the
    /// same query goes once to the next, in order, and when every one fails the first error is thrown. Each failure is
    /// logged with its endpoint and error. Cancellation (also `URLError.cancelled`, or a cancelled task) is thrown at
    /// once and never retried.
    public func places(around: Coordinate, radius: Int, language: StoryLanguage) async throws -> [Candidate] {
        do {
            return try await placesReportingEndpoints(around: around, radius: radius, language: language)
        } catch let failure as OverpassFailure {
            throw failure.first
        }
    }

    /// `places(around:radius:language:)`, but when every endpoint fails it throws an `OverpassFailure` with the first
    /// error and one short line per endpoint tried, for the walk log. Cancellation is thrown as it is.
    public func placesReportingEndpoints(around: Coordinate, radius: Int,
                                         language: StoryLanguage) async throws -> [Candidate] {
        try await placesReportingEndpoints(query: Self.query(around: around, radius: radius), timeout: Self.walkingTimeout,
                                           language: language).candidates
    }

    /// The tour places inside a box (`tourQuery`, 30 s request timeout), with the same endpoint fallback, logging and
    /// errors as `placesReportingEndpoints(around:radius:language:)`. `capped` is true when the answer holds as many
    /// ways and relations as `tourAreaCap`, or as many nodes as `tourNodeCap`: the server may have left places out.
    /// It is logged.
    public func tourPlacesReportingEndpoints(in box: (south: Double, west: Double, north: Double, east: Double),
                                             language: StoryLanguage) async throws -> TourOverpassPlaces {
        let answer = try await placesReportingEndpoints(query: Self.tourQuery(boundingBox: box), timeout: Self.tourTimeout,
                                                        language: language)
        let capped = answer.areaCount >= Self.tourAreaCap || answer.nodeCount >= Self.tourNodeCap
        if capped {
            Self.log.notice("tour query hit a cap: \(answer.areaCount, privacy: .public) ways and relations of \(Self.tourAreaCap, privacy: .public), \(answer.nodeCount, privacy: .public) nodes of \(Self.tourNodeCap, privacy: .public)")
        }
        return TourOverpassPlaces(candidates: answer.candidates, capped: capped)
    }

    /// One answer: its candidates, in the server's order, and how many elements of each kind it held (before any
    /// was filtered out), so a cap hit can be told.
    struct Answer {
        var candidates: [Candidate]
        /// Ways and relations.
        var areaCount: Int
        var nodeCount: Int
    }

    private func placesReportingEndpoints(query: String, timeout: TimeInterval,
                                          language: StoryLanguage) async throws -> Answer {
        var firstError: Error?
        var endpointErrors: [String] = []
        for endpoint in Self.endpoints {
            do {
                return try await places(from: endpoint, query: query, timeout: timeout, language: language)
            } catch {
                if Self.isCancellation(error) { throw error }
                let host = endpoint.host() ?? endpoint.absoluteString
                Self.log.error("\(host, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                if firstError == nil { firstError = error }
                endpointErrors.append("\(host): \(OverpassFailure.shortText(error))")
                if Task.isCancelled { break }
            }
        }
        // `endpoints` is never empty, so the loop either returned or recorded an error before it ended.
        throw OverpassFailure(first: firstError ?? GroundingFetchError.malformed, endpointErrors: endpointErrors)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? URLError, error.code == .cancelled { return true }
        return false
    }

    private func places(from endpoint: URL, query: String, timeout: TimeInterval,
                        language: StoryLanguage) async throws -> Answer {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        request.httpBody = Data("data=\(encoded)".utf8)

        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else { throw GroundingFetchError.http(response.statusCode) }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw GroundingFetchError.malformed }
        // Overpass reports timeouts and out-of-memory as HTTP 200 with a remark, possibly with partial elements.
        if let remark = decoded.remark, remark.hasPrefix("runtime error") { throw GroundingFetchError.overpassRuntime(remark) }
        let elements = decoded.elements.compactMap(\.value)
        // Elements that did not decode (no type or id) are not counted; Overpass always sends both.
        let nodeCount = elements.filter { $0.type == "node" }.count
        return Answer(candidates: elements.compactMap { Self.candidate(from: $0, language: language) },
                      areaCount: elements.count - nodeCount, nodeCount: nodeCount)
    }

    private static func candidate(from element: Element, language: StoryLanguage) -> Candidate? {
        let tags = element.tags ?? [:]
        if tags["shop"] != nil { return nil }
        if let amenity = tags["amenity"], excludedAmenities.contains(amenity) { return nil }
        guard let name = localName(tags, language: language) else { return nil }
        let coordinate: Coordinate
        if let lat = element.lat, let lon = element.lon {
            coordinate = Coordinate(latitude: lat, longitude: lon)
        } else if let center = element.center {
            coordinate = Coordinate(latitude: center.lat, longitude: center.lon)
        } else {
            return nil
        }
        return Candidate(
            id: "osm:\(element.type)/\(element.id)",
            name: name,
            coordinate: coordinate,
            kind: kind(tags),
            summary: nil,
            wikipediaTitle: tags["wikipedia"],
            wikidata: tags["wikidata"],
            tags: tags.filter { keptTagKeys.contains($0.key) }
        )
    }

    private static func localName(_ tags: [String: String], language: StoryLanguage) -> String? {
        let keys: [String]
        switch language {
        case .english: keys = ["name:en", "name"]
        case .norwegian: keys = ["name:nb", "name:no", "name"]
        }
        return keys.lazy.compactMap { tags[$0] }.first { !$0.isEmpty }
    }

    private static func kind(_ tags: [String: String]) -> String {
        if let v = tags["historic"] { return "historic=\(v)" }
        if let v = tags["tourism"] { return "tourism=\(v)" }
        if tags["amenity"] == "place_of_worship" { return "amenity=place_of_worship" }
        if let v = tags["building"] { return "building=\(v)" }
        // Matched only through a wikipedia tag; same kind as Wikipedia candidates.
        return "wikipedia"
    }

    private struct Response: Decodable {
        var elements: [Lossy<Element>]
        var remark: String?
    }

    /// One bad element must not discard the rest.
    private struct Lossy<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private struct Element: Decodable {
        var type: String
        var id: Int64
        var lat: Double?
        var lon: Double?
        var center: Center?
        var tags: [String: String]?
    }

    private struct Center: Decodable {
        var lat: Double
        var lon: Double
    }
}

/// The tour query's places (`OverpassClient.tourPlacesReportingEndpoints`), and whether the answer reached one of
/// its caps, so places may be missing.
public struct TourOverpassPlaces: Sendable, Equatable {
    public var candidates: [Candidate]
    public var capped: Bool

    public init(candidates: [Candidate], capped: Bool) {
        self.candidates = candidates
        self.capped = capped
    }
}

/// Every Overpass endpoint failed. `first` is the first endpoint's error (what `OverpassClient.places` throws);
/// `endpointErrors` has one short line per endpoint tried, in order, e.g. "overpass-api.de: timed out".
public struct OverpassFailure: Error, CustomStringConvertible {
    public var first: any Error
    public var endpointErrors: [String]

    public init(first: any Error, endpointErrors: [String]) {
        self.first = first
        self.endpointErrors = endpointErrors
    }

    public var description: String { endpointErrors.joined(separator: "; ") }

    /// Longest `shortText` taken from an unknown error's description.
    static let maxShortTextLength = 80

    /// A few words for a walk log line: "timed out", "HTTP 504", "malformed answer", a runtime remark cut to
    /// `maxShortTextLength`, "URLError -1009"; else the error's description cut to `maxShortTextLength`.
    public static func shortText(_ error: any Error) -> String {
        if let e = error as? GroundingFetchError {
            switch e {
            case .http(let status): return "HTTP \(status)"
            case .malformed: return "malformed answer"
            case .overpassRuntime(let remark): return String(remark.prefix(maxShortTextLength))
            case .apiError(let code): return "API error \(code)"
            }
        }
        if let e = error as? URLError {
            switch e.code {
            case .timedOut: return "timed out"
            case .notConnectedToInternet: return "offline"
            case .networkConnectionLost: return "connection lost"
            case .cannotFindHost: return "host not found"
            case .cannotConnectToHost: return "cannot connect"
            case .dnsLookupFailed: return "DNS lookup failed"
            case .secureConnectionFailed: return "TLS failed"
            default: return "URLError \(e.code.rawValue)"
            }
        }
        return String(String(describing: error).prefix(maxShortTextLength))
    }
}
