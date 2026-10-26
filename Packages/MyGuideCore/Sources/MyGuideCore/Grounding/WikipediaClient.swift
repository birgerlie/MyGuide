import Foundation

/// Fetches nearby Wikipedia articles (geosearch) with short summaries, in the story language where available.
public struct WikipediaClient: Sendable {
    static let summaryLimit = 600
    /// Below this many story-language results, English articles are added.
    private static let fallbackThreshold = 3

    private let http: HTTPClient

    public init(http: HTTPClient) {
        self.http = http
    }

    static func url(lang: String, around: Coordinate, radius: Int) -> URL {
        // String(format:) with %f uses the POSIX decimal point regardless of the user's locale.
        let coord = "\(String(format: "%.6f", around.latitude))%7C\(String(format: "%.6f", around.longitude))"
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(lang).wikipedia.org"
        components.path = "/w/api.php"
        components.percentEncodedQuery = [
            "action=query", "format=json", "formatversion=2", "generator=geosearch",
            "ggscoord=\(coord)", "ggsradius=\(radius)", "ggslimit=20",
            "prop=coordinates%7Cextracts%7Cpageprops",
            "exintro=1", "explaintext=1", "exsentences=4", "exlimit=20",
            "ppprop=wikibase_item", "colimit=20",
        ].joined(separator: "&")
        return components.url!
    }

    public func articles(around: Coordinate, radius: Int, language: StoryLanguage) async throws -> [Candidate] {
        let primary = try await fetch(code: language.wikipediaCode, around: around, radius: radius)
        guard language != .english, primary.count < Self.fallbackThreshold else { return primary }

        // A failed English fallback must not discard the story-language results.
        guard let english = try? await fetch(code: StoryLanguage.english.wikipediaCode, around: around, radius: radius) else {
            return primary
        }
        let known = Set(primary.compactMap(\.wikidata))
        return primary + english.filter { candidate in
            candidate.wikidata.map { !known.contains($0) } ?? true
        }
    }

    private func fetch(code: String, around: Coordinate, radius: Int) async throws -> [Candidate] {
        var request = URLRequest(url: Self.url(lang: code, around: around, radius: radius))
        request.timeoutInterval = 10
        request.setValue(OverpassClient.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else { throw GroundingFetchError.http(response.statusCode) }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw GroundingFetchError.malformed }
        // MediaWiki omits "query" (or "pages") when nothing is found: zero results, not an error.
        let pages = decoded.query?.pages ?? []
        return pages.compactMap { $0.value.flatMap { Self.candidate(from: $0, code: code) } }
    }

    private static func candidate(from page: Page, code: String) -> Candidate? {
        guard let coordinate = page.coordinates?.first else { return nil }
        let extract = page.extract?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = extract.flatMap { $0.isEmpty ? nil : TextTrim.truncate($0, maxCharacters: summaryLimit) }
        return Candidate(
            id: "wiki:\(code)/\(page.pageid)",
            name: page.title,
            coordinate: Coordinate(latitude: coordinate.lat, longitude: coordinate.lon),
            kind: "wikipedia",
            summary: summary,
            wikipediaTitle: "\(code):\(page.title)",
            wikidata: page.pageprops?.wikibase_item
        )
    }

    private struct Response: Decodable {
        var query: Query?
    }

    private struct Query: Decodable {
        var pages: [Lossy<Page>]?
    }

    /// One bad page must not discard the rest.
    private struct Lossy<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private struct Page: Decodable {
        var pageid: Int
        var title: String
        var extract: String?
        var coordinates: [Coord]?
        var pageprops: Props?
    }

    private struct Coord: Decodable {
        var lat: Double
        var lon: Double
    }

    private struct Props: Decodable {
        var wikibase_item: String?
    }
}

public enum TextTrim {
    /// Cuts at the last whitespace at or before `maxCharacters` and appends `…`; hard-cuts when there is none.
    public static func truncate(_ s: String, maxCharacters: Int) -> String {
        guard s.count > maxCharacters else { return s }
        let window = s.prefix(maxCharacters + 1)
        if let space = window.lastIndex(where: \.isWhitespace), space > window.startIndex {
            let head = s[..<space].trimmingCharacters(in: .whitespacesAndNewlines)
            if !head.isEmpty { return head + "…" }
        }
        return String(s.prefix(maxCharacters)) + "…"
    }
}
