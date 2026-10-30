import Foundation

/// Fetches sitelink counts and place classes for Wikidata items from the Wikidata Query Service (spec 19).
public struct WikidataClient: Sendable {
    static let endpoint = "https://query.wikidata.org/sparql"
    static let timeout: TimeInterval = 8
    /// Ids per request, and requests per call: ids beyond `batchSize * maxBatches` are left out.
    static let batchSize = 50
    static let maxBatches = 4

    /// Instance-of classes (through subclass-of) that make an item a place (spec 19.1).
    static let placeClasses = ["Q811979", "Q174782", "Q22698", "Q839954", "Q4989906", "Q838948", "Q483453"]
    /// Streets, squares and districts.
    static let areaClasses = ["Q79007", "Q123705", "Q56061"]
    /// Organisations, people, events.
    static let nonPlaceClasses = ["Q43229", "Q5", "Q1656682", "Q16334295"]

    private let http: HTTPClient

    public init(http: HTTPClient) {
        self.http = http
    }

    /// Facts for up to any number of ids (batched by 50, batches run concurrently, at most 4 batches = 200 ids;
    /// ids beyond are left out). A failed batch is left out of the result; never throws except CancellationError.
    public func facts(for ids: [String]) async throws -> [String: PlaceFacts] {
        var seen = Set<String>()
        let valid = ids.filter { Self.isValid($0) && seen.insert($0).inserted }.prefix(Self.batchSize * Self.maxBatches)
        let batches = stride(from: 0, to: valid.count, by: Self.batchSize).map {
            Array(valid.dropFirst($0).prefix(Self.batchSize))
        }
        let http = http
        return try await withThrowingTaskGroup(of: [String: PlaceFacts].self) { group in
            for batch in batches {
                group.addTask {
                    do {
                        return try await Self.fetch(batch, http: http)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return [:]
                    }
                }
            }
            var merged: [String: PlaceFacts] = [:]
            for try await part in group { merged.merge(part) { first, _ in first } }
            try Task.checkCancellation()
            return merged
        }
    }

    /// "Q" and at least one digit, nothing else.
    static func isValid(_ id: String) -> Bool {
        id.count >= 2 && id.first == "Q" && id.dropFirst().allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    /// The SPARQL for `ids` (invalid ones skipped): one row per item with its sitelink count and one boolean per
    /// class group.
    static func query(ids: [String]) -> String {
        func flag(_ name: String, _ classes: [String]) -> String {
            "BIND(EXISTS { VALUES ?c { \(classes.map { "wd:" + $0 }.joined(separator: " ")) } "
                + "?item wdt:P31/wdt:P279* ?c } AS ?\(name))"
        }
        let items = ids.filter(isValid).map { "wd:" + $0 }.joined(separator: " ")
        return """
        SELECT ?item ?n ?area ?place ?nonplace WHERE {
          VALUES ?item { \(items) }
          ?item wikibase:sitelinks ?n .
          \(flag("area", areaClasses))
          \(flag("place", placeClasses))
          \(flag("nonplace", nonPlaceClasses))
        }
        """
    }

    static func request(for ids: [String]) -> URLRequest {
        // Everything but the RFC 3986 unreserved characters is escaped, so "+", "&" and "=" in the query are safe.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = query(ids: ids).addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        var request = URLRequest(url: URL(string: "\(endpoint)?query=\(encoded)")!)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        request.setValue(OverpassClient.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func fetch(_ ids: [String], http: HTTPClient) async throws -> [String: PlaceFacts] {
        let (data, response) = try await http.send(request(for: ids))
        guard (200..<300).contains(response.statusCode) else { throw GroundingFetchError.http(response.statusCode) }
        return try parse(data)
    }

    private struct Answer: Decodable {
        struct Value: Decodable { var value: String }
        struct Row: Decodable {
            var item: Value
            var n: Value
            var area: Value?
            var place: Value?
            var nonplace: Value?
        }
        struct Results: Decodable { var bindings: [Row] }
        var results: Results
    }

    /// Rows without a readable id or count are skipped; the first row of an item wins.
    static func parse(_ data: Data) throws -> [String: PlaceFacts] {
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw GroundingFetchError.malformed }
        var facts: [String: PlaceFacts] = [:]
        for row in answer.results.bindings {
            guard let id = row.item.value.split(separator: "/").last.map(String.init), isValid(id),
                  let n = Int(row.n.value), facts[id] == nil else { continue }
            let kind: PlaceClass
            if row.area?.value == "true" { kind = .area }
            else if row.place?.value == "true" { kind = .place }
            else if row.nonplace?.value == "true" { kind = .nonPlace }
            else { kind = .unknown }
            facts[id] = PlaceFacts(sitelinks: n, placeClass: kind)
        }
        return facts
    }
}
