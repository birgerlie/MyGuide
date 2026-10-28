import Foundation

/// A place that might be what the photo shows.
public struct Candidate: Sendable, Equatable, Codable, Identifiable {
    /// "osm:node/1" or "wiki:en/123".
    public var id: String
    public var name: String
    public var coordinate: Coordinate
    /// OSM-style "key=value" describing what the place is, or "wikipedia" for places known only from a Wikipedia article.
    public var kind: String
    public var summary: String?
    /// Language-prefixed article title, e.g. "de:Michaelertor".
    public var wikipediaTitle: String?
    public var wikidata: String?
    /// The whitelisted OSM tags (`OverpassClient.keptTagKeys`); nil for Wikipedia-only candidates and for
    /// groundings stored before tags existed.
    public var tags: [String: String]?

    public init(id: String, name: String, coordinate: Coordinate, kind: String,
                summary: String? = nil, wikipediaTitle: String? = nil, wikidata: String? = nil,
                tags: [String: String]? = nil) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.kind = kind
        self.summary = summary
        self.wikipediaTitle = wikipediaTitle
        self.wikidata = wikidata
        self.tags = tags
    }
}

public enum GroundingFetchError: Error, Equatable {
    case http(Int)
    case malformed
    /// Overpass answered 200 but reported a server-side failure (timeout, out of memory).
    case overpassRuntime(String)
    /// MediaWiki answered 200 but reported an API error (e.g. "toobig"); the associated value is its code.
    case apiError(String)
}

/// A candidate with its position relative to the capture point.
public struct RankedCandidate: Sendable, Equatable, Codable {
    public var candidate: Candidate
    /// Metres from the capture point.
    public var distance: Double
    /// Degrees clockwise from north, 0..<360.
    public var bearing: Double
    /// Whether the candidate lies in the camera's field of view; nil when there is no usable heading.
    public var inView: Bool?

    public init(candidate: Candidate, distance: Double, bearing: Double, inView: Bool?) {
        self.candidate = candidate
        self.distance = distance
        self.bearing = bearing
        self.inView = inView
    }
}

public struct Address: Sendable, Equatable, Codable {
    public var line: String?
    /// Neighbourhood or suburb; absent in addresses persisted before it existed.
    public var district: String?
    public var city: String?
    public var country: String?

    public init(line: String? = nil, district: String? = nil, city: String? = nil, country: String? = nil) {
        self.line = line
        self.district = district
        self.city = city
        self.country = country
    }

    /// The non-nil parts joined with ", ".
    public var display: String {
        [line, district, city, country].compactMap { $0 }.joined(separator: ", ")
    }
}

public enum GroundingSource: String, Sendable, Codable {
    case openStreetMap, wikipedia, geocoder
}

public struct Grounding: Sendable, Equatable, Codable {
    public var candidates: [RankedCandidate]
    public var address: Address?
    public var failedSources: [GroundingSource]

    public init(candidates: [RankedCandidate], address: Address?, failedSources: [GroundingSource]) {
        self.candidates = candidates
        self.address = address
        self.failedSources = failedSources
    }
}

public protocol ReverseGeocoding: Sendable {
    func address(for: Coordinate) async throws -> Address
}
