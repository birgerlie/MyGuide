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

    public init(id: String, name: String, coordinate: Coordinate, kind: String,
                summary: String? = nil, wikipediaTitle: String? = nil, wikidata: String? = nil) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.kind = kind
        self.summary = summary
        self.wikipediaTitle = wikipediaTitle
        self.wikidata = wikidata
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
