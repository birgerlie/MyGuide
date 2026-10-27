import Foundation

/// Fetches named historic places and buildings near a point from OpenStreetMap via Overpass.
public struct OverpassClient: Sendable {
    static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    static let userAgent = "MyGuide/0.1 (https://github.com/birgerlie/MyGuide)"

    private static let excludedAmenities: Set<String> = [
        "restaurant", "cafe", "bar", "pub", "fast_food", "ice_cream", "biergarten",
    ]

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

    public func places(around: Coordinate, radius: Int, language: StoryLanguage) async throws -> [Candidate] {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = Self.query(around: around, radius: radius).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        request.httpBody = Data("data=\(encoded)".utf8)

        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else { throw GroundingFetchError.http(response.statusCode) }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw GroundingFetchError.malformed }
        // Overpass reports timeouts and out-of-memory as HTTP 200 with a remark, possibly with partial elements.
        if let remark = decoded.remark, remark.hasPrefix("runtime error") { throw GroundingFetchError.overpassRuntime(remark) }
        return decoded.elements.compactMap { $0.value.flatMap { Self.candidate(from: $0, language: language) } }
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
            wikidata: tags["wikidata"]
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
