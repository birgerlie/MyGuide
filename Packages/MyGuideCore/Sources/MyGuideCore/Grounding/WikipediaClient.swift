import Foundation

/// Fetches nearby Wikipedia articles (geosearch) with short summaries, in the story language where available.
public struct WikipediaClient: Sendable {
    static let summaryLimit = 600

    private let http: HTTPClient

    public init(http: HTTPClient) {
        self.http = http
    }

    /// The geosearch radius range (metres) and the largest result count the API allows; a bigger area takes several
    /// searches.
    public static let minGeosearchRadius = 10
    public static let maxGeosearchRadius = 10_000
    public static let maxGeosearchLimit = 500

    /// `exlimit` stays 20: the API maximum for intro extracts (pages beyond it come back without a summary).
    /// `radius` is kept within the geosearch range and `limit` at most its maximum, so no request asks for more than
    /// the API gives.
    static func url(lang: String, around: Coordinate, radius: Int, limit: Int = 20) -> URL {
        let radius = min(max(radius, minGeosearchRadius), maxGeosearchRadius), limit = min(limit, maxGeosearchLimit)
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

    /// The story-language articles, followed by the English articles whose Wikidata item is not among them. An English
    /// article without an item is left out when a story-language article has the same normalised title
    /// (`normalisedTitle`) within `twinRadius` (spec 20.6.7); otherwise it is added. Outside English the English
    /// geosearch always runs alongside, one extra request per call (spec 20.1): story-language articles often lack
    /// coordinates (Norwegian Trevi, Campo de' Fiori), so a geosearch never finds them. The story-language article wins for an item in both, with its name,
    /// summary and summary language. A failing English search leaves the story-language articles; a failing
    /// story-language search throws (and cancels the English one).
    public func articles(around: Coordinate, radius: Int, language: StoryLanguage, limit: Int = 20) async throws -> [Candidate] {
        guard language != .english else {
            return try await fetch(code: language.wikipediaCode, around: around, radius: radius, limit: limit)
        }
        // The English search starts alongside the primary, so merging it costs no extra round trip. Its outcome is
        // captured, not thrown: a failed English search must not discard the primary results. If the primary
        // throws, the English search is cancelled when this scope exits.
        async let fallback = Self.outcome { try await fetch(code: StoryLanguage.english.wikipediaCode, around: around, radius: radius, limit: limit) }
        let primary = try await fetch(code: language.wikipediaCode, around: around, radius: radius, limit: limit)

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
            if let id = candidate.wikidata, !id.isEmpty { return !known.contains(id) }
            let title = Self.normalisedTitle(candidate.name)
            return !primary.contains {
                Self.normalisedTitle($0.name) == title
                    && GeoMath.distance($0.coordinate, candidate.coordinate) <= Self.twinRadius
            }
        }
    }

    /// An English article without a Wikidata id is the twin of a story-language article with the same normalised
    /// title at most this far away (metres, inclusive; spec 20.6.7).
    public static let twinRadius = 100.0

    /// The title without regard to case, diacritics or runs of whitespace, trimmed.
    static func normalisedTitle(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
            wikidata: page.pageprops?.wikibase_item,
            summaryLanguage: summary == nil ? nil : code
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

extension WikipediaClient {
    public static let articleTextLimit = 4_000

    /// Whole-article plain-text request (no `exintro`); the text is cut locally. `title` may hold spaces and non-ASCII.
    static func articleTextURL(code: String, title: String) -> URL {
        apiURL(code: code, query: [
            "action=query", "format=json", "formatversion=2", "prop=extracts", "explaintext=1",
            "exsectionformat=plain", "redirects=1", "titles=\(encoded(title))",
        ])
    }

    /// Only unreserved characters stay literal, so "&", "+", "=" and "#" in a title cannot leak into the query.
    static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func apiURL(code: String, query: [String]) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(code).wikipedia.org"
        components.path = "/w/api.php"
        components.percentEncodedQuery = query.joined(separator: "&")
        return components.url!
    }

    /// Splits "code:Title" at the first colon. Throws GroundingFetchError.malformed for a missing prefix or title,
    /// and for a code that is not letters and hyphens only (it becomes a host name, e.g. "no", "zh-min-nan").
    static func split(wikipediaTitle: String) throws -> (code: String, title: String) {
        guard let colon = wikipediaTitle.firstIndex(of: ":") else { throw GroundingFetchError.malformed }
        let code = String(wikipediaTitle[..<colon])
        let title = String(wikipediaTitle[wikipediaTitle.index(after: colon)...])
        guard !code.isEmpty, !title.isEmpty,
              code.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") }) else { throw GroundingFetchError.malformed }
        return (code, title)
    }

    /// A GET with the shared User-Agent and a 10 s timeout; throws GroundingFetchError.http for a non-2xx status.
    func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(OverpassClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else { throw GroundingFetchError.http(response.statusCode) }
        return data
    }

    /// Plain text of the article (intro plus following sections), cut to `articleTextLimit` with TextTrim.truncate.
    /// `wikipediaTitle` is "code:Title" (Candidate.wikipediaTitle). Throws on HTTP/API/malformed errors and on a
    /// missing page; throws GroundingFetchError.malformed for a title without a "code:" prefix.
    public func articleText(wikipediaTitle: String) async throws -> String {
        let (code, title) = try Self.split(wikipediaTitle: wikipediaTitle)
        let data = try await get(Self.articleTextURL(code: code, title: title))
        guard let decoded = try? JSONDecoder().decode(ArticleResponse.self, from: data) else { throw GroundingFetchError.malformed }
        if let error = decoded.error { throw GroundingFetchError.apiError(error.code ?? "unknown") }
        guard let page = decoded.query?.pages?.first, page.missing != true,
              let text = page.extract?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { throw GroundingFetchError.malformed }
        return TextTrim.truncate(text, maxCharacters: Self.articleTextLimit)
    }
}

private struct ArticleResponse: Decodable {
    var query: Query?
    var error: APIError?

    struct APIError: Decodable { var code: String? }
    struct Query: Decodable { var pages: [Page]? }
    struct Page: Decodable {
        var missing: Bool?
        var extract: String?
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

extension WikipediaClient {
    static func pageImagesURL(code: String, title: String) -> URL {
        apiURL(code: code, query: [
            "action=query", "format=json", "formatversion=2", "prop=pageimages",
            "piprop=thumbnail%7Cname", "pithumbsize=600", "redirects=1", "titles=\(encoded(title))",
        ])
    }

    static func imageInfoURL(code: String, fileName: String) -> URL {
        apiURL(code: code, query: [
            "action=query", "format=json", "formatversion=2", "prop=imageinfo",
            "iiprop=extmetadata", "iiextmetadatafilter=Artist%7CLicenseShortName", "titles=\(encoded("File:" + fileName))",
        ])
    }

    /// Two requests on the article's own wiki: pageimages (piprop=thumbnail|name, pithumbsize=600, redirects=1),
    /// then imageinfo (iiprop=extmetadata, iiextmetadatafilter=Artist|LicenseShortName) for "File:<name>".
    /// nil when the article has no page image. Artist HTML is reduced to plain text (tags stripped, entities decoded).
    /// A missing article also gives nil. Throws on HTTP/API/malformed errors of either request (so a picture is never
    /// returned without the credit lookup having succeeded), with .malformed when the credit names neither author nor
    /// licence, for a non-https thumbnail, and for a malformed title.
    public func pageImage(wikipediaTitle: String) async throws -> PlaceImageInfo? {
        let (code, title) = try Self.split(wikipediaTitle: wikipediaTitle)

        let pageData = try await get(Self.pageImagesURL(code: code, title: title))
        guard let pages = try? JSONDecoder().decode(PageImagesResponse.self, from: pageData) else { throw GroundingFetchError.malformed }
        if let error = pages.error { throw GroundingFetchError.apiError(error.code ?? "unknown") }
        guard let page = pages.query?.pages?.first, page.missing != true,
              let source = page.thumbnail?.source, let fileName = page.pageimage, !fileName.isEmpty else { return nil }
        guard let thumbnailURL = URL(string: source), thumbnailURL.scheme == "https" else { throw GroundingFetchError.malformed }

        let infoData = try await get(Self.imageInfoURL(code: code, fileName: fileName))
        guard let info = try? JSONDecoder().decode(ImageInfoResponse.self, from: infoData) else { throw GroundingFetchError.malformed }
        if let error = info.error { throw GroundingFetchError.apiError(error.code ?? "unknown") }
        // A Commons file is reported "missing" (but "known") on the article's wiki; only the metadata matters here.
        let file = info.query?.pages?.first
        let metadata = file?.imageinfo?.first?.extmetadata
        let author = metadata?.Artist?.value.flatMap(Self.plainText(fromHTML:))
        let licence = metadata?.LicenseShortName?.value.flatMap(Self.plainText(fromHTML:))
        // A picture with no credit at all is never offered: that reply counts as malformed, not as "no image".
        guard author != nil || licence != nil else { throw GroundingFetchError.malformed }
        return PlaceImageInfo(thumbnailURL: thumbnailURL, author: author, licence: licence,
                              filePage: Self.filePage(code: code, fileName: fileName, repository: file?.imagerepository))
    }

    /// The thumbnail's bytes. Throws GroundingFetchError.http for a non-2xx status and .malformed for an empty body.
    public func imageData(_ url: URL) async throws -> Data {
        let data = try await get(url)
        guard !data.isEmpty else { throw GroundingFetchError.malformed }
        return data
    }

    /// "shared" files live on Commons, "local" ones on the article's wiki; anything else has no known page.
    static func filePage(code: String, fileName: String, repository: String?) -> URL? {
        let host: String
        switch repository {
        case "shared": host = "commons.wikimedia.org"
        case "local": host = "\(code).wikipedia.org"
        default: return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath = "/wiki/File:" + encoded(fileName.replacingOccurrences(of: " ", with: "_"))
        return components.url
    }

    /// Plain text of an HTML fragment: tags removed (line breaks and block tags become spaces), then the common
    /// named entities and numeric references decoded, whitespace collapsed. nil when nothing is left.
    static func plainText(fromHTML html: String) -> String? {
        let spaced = html.replacingOccurrences(of: #"<\s*/?\s*(br|p|div|li|tr|td|th)\b[^>]*>"#, with: " ",
                                               options: [.regularExpression, .caseInsensitive])
        let stripped = spaced.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        let decoded = decodingEntities(stripped)
        let text = decoded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
    ]

    /// Single pass, so a decoded "&" can never start a second entity ("&amp;lt;" gives "&lt;").
    private static func decodingEntities(_ s: String) -> String {
        var result = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let tail = rest[rest.index(after: amp)...]
            // Entity names and references are short; a ";" further away is not part of this one.
            if let semi = tail.prefix(10).firstIndex(of: ";"), let char = entity(String(tail[..<semi])) {
                result.append(char)
                rest = tail[tail.index(after: semi)...]
            } else {
                result.append("&")
                rest = tail
            }
        }
        return result + rest
    }

    private static func entity(_ name: String) -> String? {
        if let named = namedEntities[name] { return named }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let value: UInt32?
        if let first = digits.first, first == "x" || first == "X" {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits, radix: 10)
        }
        // Reject a sign ("&#+65;" parses with UInt32) and code points that are not scalars (surrogates, > 10FFFF).
        guard let value, digits.allSatisfy({ $0.isHexDigit || $0 == "x" || $0 == "X" }),
              let scalar = Unicode.Scalar(value) else { return nil }
        // A non-breaking space is reduced like any other space.
        return scalar == "\u{A0}" ? " " : String(Character(scalar))
    }
}

private struct PageImagesResponse: Decodable {
    var query: Query?
    var error: APIError?

    struct APIError: Decodable { var code: String? }
    struct Query: Decodable { var pages: [Page]? }
    struct Page: Decodable {
        var missing: Bool?
        var thumbnail: Thumbnail?
        var pageimage: String?
    }
    struct Thumbnail: Decodable { var source: String? }
}

private struct ImageInfoResponse: Decodable {
    var query: Query?
    var error: APIError?

    struct APIError: Decodable { var code: String? }
    struct Query: Decodable { var pages: [Page]? }
    struct Page: Decodable {
        var imagerepository: String?
        var imageinfo: [Info]?
    }
    struct Info: Decodable { var extmetadata: Metadata? }
    struct Metadata: Decodable {
        var Artist: Field?
        var LicenseShortName: Field?
    }
    /// Lossy: a value that is not a string (extmetadata is loosely typed) counts as absent instead of failing the reply.
    struct Field: Decodable {
        var value: String?
        enum CodingKeys: String, CodingKey { case value }
        init(from decoder: Decoder) throws {
            value = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .value)
        }
    }
}
