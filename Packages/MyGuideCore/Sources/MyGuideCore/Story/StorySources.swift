import Foundation

/// One source behind a photo story, for the story screen's «Kilder» (design guidelines: show sources for factual
/// claims). Only sources the story actually drew on are listed; nothing is inferred.
public struct StorySource: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case wikipedia, openStreetMap, wikidata, appleMaps
    }

    public var kind: Kind
    /// What to show: the article title, the OSM object, the Wikidata id, or nil for Apple Maps.
    public var detail: String?
    public var url: URL?

    public var id: String { "\(kind)|\(detail ?? "")" }

    public init(kind: Kind, detail: String?, url: URL?) {
        self.kind = kind
        self.detail = detail
        self.url = url
    }
}

public enum StorySources {
    /// The matched place's Wikipedia article, OpenStreetMap object and Wikidata item, then Apple Maps when its places
    /// or its address were in the request. A story with no matched place (the model's subject by name, or "unsure")
    /// lists no place sources, because none of the candidates is known to be what the story is about.
    public static func list(for session: StorySession) -> [StorySource] {
        var sources: [StorySource] = []
        if session.identified.confidence != .unsure, let candidate = session.matchedCandidate?.candidate {
            if let article = wikipedia(candidate) { sources.append(article) }
            if let osm = openStreetMap(candidate.id) { sources.append(osm) }
            if let item = candidate.wikidata?.trimmingCharacters(in: .whitespaces), isWikidataID(item) {
                sources.append(StorySource(kind: .wikidata, detail: item,
                                           url: URL(string: "https://www.wikidata.org/wiki/\(item)")))
            }
        }
        if !(session.grounding.applePlaces ?? []).isEmpty || session.grounding.address != nil {
            sources.append(StorySource(kind: .appleMaps, detail: nil, url: nil))
        }
        return sources
    }

    /// "de:Michaelertor" → the article on de.wikipedia.org; without a title, a "wiki:en/123" id → the page by id.
    static func wikipedia(_ candidate: Candidate) -> StorySource? {
        if let title = candidate.wikipediaTitle, let colon = title.firstIndex(of: ":") {
            let code = String(title[..<colon])
            let name = String(title[title.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard isLanguageCode(code), !name.isEmpty else { return nil }
            let path = name.replacingOccurrences(of: " ", with: "_")
                .addingPercentEncoding(withAllowedCharacters: articleAllowed) ?? ""
            return StorySource(kind: .wikipedia, detail: name, url: URL(string: "https://\(code).wikipedia.org/wiki/\(path)"))
        }
        let parts = candidate.id.split(separator: "/", omittingEmptySubsequences: false)
        guard candidate.id.hasPrefix("wiki:"), parts.count == 2 else { return nil }
        let code = String(parts[0].dropFirst("wiki:".count))
        let pageID = String(parts[1])
        guard isLanguageCode(code), !pageID.isEmpty, pageID.allSatisfy(\.isASCIIDigit) else { return nil }
        return StorySource(kind: .wikipedia, detail: candidate.name,
                           url: URL(string: "https://\(code).wikipedia.org/?curid=\(pageID)"))
    }

    /// "osm:node/1" → openstreetmap.org/node/1 (node, way or relation only).
    static func openStreetMap(_ id: String) -> StorySource? {
        guard id.hasPrefix("osm:") else { return nil }
        let parts = id.dropFirst("osm:".count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, ["node", "way", "relation"].contains(String(parts[0])),
              !parts[1].isEmpty, parts[1].allSatisfy(\.isASCIIDigit) else { return nil }
        let path = "\(parts[0])/\(parts[1])"
        return StorySource(kind: .openStreetMap, detail: path, url: URL(string: "https://www.openstreetmap.org/\(path)"))
    }

    /// Wikipedia language codes: lowercase letters and hyphens ("en", "no", "zh-yue"), so a title like
    /// "Category:X" or "https:…" never becomes a host name.
    private static func isLanguageCode(_ code: String) -> Bool {
        (2...12).contains(code.count) && code.allSatisfy { ($0.isASCII && $0.isLowercase) || $0 == "-" }
            && code.first != "-"
    }

    private static func isWikidataID(_ item: String) -> Bool {
        item.count > 1 && item.first == "Q" && item.dropFirst().allSatisfy(\.isASCIIDigit)
    }

    /// Path characters minus "?" and "#", which would end the article name.
    private static let articleAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))
}

/// "Roma, Italia" under the place name: the address's city and country; the district stands in for a missing city.
public enum PlaceLocationLine {
    public static func text(_ address: Address?) -> String? {
        guard let address else { return nil }
        let parts = [address.city ?? address.district, address.country]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
