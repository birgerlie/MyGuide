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

    /// `exlimit` stays 20: the API maximum for intro extracts (pages beyond it come back without a summary).
    static func url(lang: String, around: Coordinate, radius: Int, limit: Int = 20) -> URL {
        // String(format:) with %f uses the POSIX decimal point regardless of the user's locale.
        let coord = "\(String(format: "%.6f", around.latitude))%7C\(String(format: "%.6f", around.longitude))"
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(lang).wikipedia.org"
        components.path = "/w/api.php"
        components.percentEncodedQuery = [
            "action=query", "format=json", "formatversion=2", "generator=geosearch",
            "ggscoord=\(coord)", "ggsradius=\(radius)", "ggslimit=\(limit)",
            "prop=coordinates%7Cextracts%7Cpageprops",
            "exintro=1", "explaintext=1", "exsentences=4", "exlimit=20",
            "ppprop=wikibase_item", "colimit=\(limit)",
        ].joined(separator: "&")
        return components.url!
    }

    public func articles(around: Coordinate, radius: Int, language: StoryLanguage, limit: Int = 20) async throws -> [Candidate] {
        guard language != .english else {
            return try await fetch(code: language.wikipediaCode, around: around, radius: radius, limit: limit)
        }
        // The English fallback starts alongside the primary so a thin story-language result costs no extra
        // round trip. Its outcome is captured, not thrown: a failed fallback must not discard the primary results.
        // If the primary throws, or has enough results, the fallback is cancelled when this scope exits.
        async let fallback = Self.outcome { try await fetch(code: StoryLanguage.english.wikipediaCode, around: around, radius: radius, limit: limit) }
        let primary = try await fetch(code: language.wikipediaCode, around: around, radius: radius, limit: limit)
        guard primary.count < Self.fallbackThreshold else { return primary }

        let english: [Candidate]
        switch await fallback {
        case .success(let candidates):
            english = candidates
        case .failure(let error) where error is CancellationError:
            // Cancellation is the exception: it must propagate.
            throw CancellationError()
        case .failure:
            return primary
        }
        let known = Set(primary.compactMap(\.wikidata))
        return primary + english.filter { candidate in
            candidate.wikidata.map { !known.contains($0) } ?? true
        }
    }

    private static func outcome<T: Sendable>(_ work: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    private func fetch(code: String, around: Coordinate, radius: Int, limit: Int) async throws -> [Candidate] {
        var request = URLRequest(url: Self.url(lang: code, around: around, radius: radius, limit: limit))
        request.timeoutInterval = 10
        request.setValue(OverpassClient.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else { throw GroundingFetchError.http(response.statusCode) }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw GroundingFetchError.malformed }
        // MediaWiki reports API errors as HTTP 200 with a top-level "error" object and no "query".
        if let error = decoded.error { throw GroundingFetchError.apiError(error.code ?? "unknown") }
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
        var error: APIError?
    }

    private struct APIError: Decodable {
        var code: String?
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
        let maxCharacters = max(0, maxCharacters)
        guard s.count > maxCharacters else { return s }
        let window = s.prefix(maxCharacters + 1)
        if let space = window.lastIndex(where: \.isWhitespace), space > window.startIndex {
            let head = s[..<space].trimmingCharacters(in: .whitespacesAndNewlines)
            if !head.isEmpty { return head + "…" }
        }
        return String(s.prefix(maxCharacters)) + "…"
    }
}
