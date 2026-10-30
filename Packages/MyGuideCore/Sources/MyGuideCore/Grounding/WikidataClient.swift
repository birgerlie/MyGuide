import Foundation

/// Fetches sitelink counts and place classes for Wikidata items from the Wikidata Query Service (spec 19).
public struct WikidataClient: Sendable {
    static let endpoint = "https://query.wikidata.org/sparql"
    static let timeout: TimeInterval = 8
    /// Ids per request, and requests per call by default (walking): ids beyond `batchSize * maxBatches` are left out.
    static let batchSize = 50
    public static let maxBatches = 4
    /// Requests per call for a tour, whose area holds far more articles than a walk's list (400 ids).
    public static let tourMaxBatches = 8
    /// Requests in flight at once, whatever the cap.
    static let maxConcurrentBatches = 4

    /// Instance-of classes (through subclass-of) that make an item a place (spec 19.1).
    static let placeClasses = ["Q811979", "Q174782", "Q22698", "Q839954", "Q4989906", "Q838948", "Q483453"]
    /// Streets: `area` even when also a place, since streets are structures in Wikidata (spec 19.1).
    static let streetClasses = ["Q79007"]
    /// Neighbourhoods and administrative territorial entities: `area` only when not also a place, since castles,
    /// city gates and walls reach Q56061 through odd subclass chains (spec 19.1).
    static let areaClasses = ["Q123705", "Q56061"]
    /// Organisations, people, events.
    static let nonPlaceClasses = ["Q43229", "Q5", "Q1656682", "Q16334295"]

    private let http: HTTPClient

    public init(http: HTTPClient) {
        self.http = http
    }

    /// The outcome of a lookup: the facts found, the ids whose batch succeeded (an answered id without facts is
    /// unknown to Wikidata), and how many batches failed (for the caller to log; core has no logging dependency).
    public struct Answer: Sendable, Equatable {
        public var facts: [String: PlaceFacts] = [:]
        public var answered: Set<String> = []
        public var failedBatches = 0

        public init(facts: [String: PlaceFacts] = [:], answered: Set<String> = [], failedBatches: Int = 0) {
            self.facts = facts
            self.answered = answered
            self.failedBatches = failedBatches
        }
    }

    /// Facts for up to any number of ids (batched by 50, at most 4 batches = 200 ids; ids beyond are left out). A
    /// failed batch is left out of the result; never throws except CancellationError.
    public func facts(for ids: [String]) async throws -> [String: PlaceFacts] {
        try await lookup(ids: ids).facts
    }

    /// Like `facts(for:)`, and also reports which ids were answered and how many batches failed. At most
    /// `maxBatches` batches of 50 are asked for, in `ids` order (later ids are left out), at most
    /// `maxConcurrentBatches` at a time.
    public func lookup(ids: [String], maxBatches: Int = WikidataClient.maxBatches) async throws -> Answer {
        var seen = Set<String>()
        let valid = ids.filter { Self.isValid($0) && seen.insert($0).inserted }
            .prefix(Self.batchSize * max(0, maxBatches))
        let batches = stride(from: 0, to: valid.count, by: Self.batchSize).map {
            Array(valid.dropFirst($0).prefix(Self.batchSize))
        }
        let http = http
        return try await withThrowingTaskGroup(of: (batch: [String], facts: [String: PlaceFacts]?).self) { group in
            func add(_ batch: [String]) {
                group.addTask {
                    do {
                        return (batch, try await Self.fetch(batch, http: http))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (batch, nil)
                    }
                }
            }
            var pending = batches[...]
            for batch in pending.prefix(Self.maxConcurrentBatches) { add(batch) }
            pending = pending.dropFirst(Self.maxConcurrentBatches)
            var answer = Answer()
            while let part = try await group.next() {
                // A finished batch makes room for the next one; none starts once the caller is cancelled.
                if !Task.isCancelled, let next = pending.popFirst() { add(next) }
                guard let facts = part.facts else {
                    answer.failedBatches += 1
                    continue
                }
                answer.answered.formUnion(part.batch)
                answer.facts.merge(facts) { first, _ in first }
            }
            try Task.checkCancellation()
            return answer
        }
    }

    /// "Q" followed by one or more ASCII digits, nothing else. Checked on the UTF-8 bytes: a `Character` comparison
    /// would accept a digit with a combining mark or joiner, which makes a malformed IRI that fails its whole batch.
    static func isValid(_ id: String) -> Bool {
        let bytes = id.utf8
        return bytes.count >= 2 && bytes.first == UInt8(ascii: "Q") && bytes.dropFirst().allSatisfy { (48...57).contains($0) }
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
        SELECT ?item ?n ?street ?area ?place ?nonplace WHERE {
          VALUES ?item { \(items) }
          ?item wikibase:sitelinks ?n .
          \(flag("street", streetClasses))
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

    private struct Reply: Decodable {
        struct Value: Decodable { var value: String }
        struct Row: Decodable {
            var item: Value
            var n: Value
            var street: Value?
            var area: Value?
            var place: Value?
            var nonplace: Value?
        }
        struct Results: Decodable { var bindings: [Row] }
        var results: Results
    }

    /// Rows without a readable id or count are skipped; the first row of an item wins. Class precedence (spec 19.1):
    /// street → `area`; else place → `place`; else neighbourhood or administrative area → `area`; else `nonPlace`;
    /// else `unknown`.
    static func parse(_ data: Data) throws -> [String: PlaceFacts] {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw GroundingFetchError.malformed }
        var facts: [String: PlaceFacts] = [:]
        for row in reply.results.bindings {
            guard let id = row.item.value.split(separator: "/").last.map(String.init), isValid(id),
                  let n = Int(row.n.value), facts[id] == nil else { continue }
            let kind: PlaceClass
            if row.street?.value == "true" { kind = .area }
            else if row.place?.value == "true" { kind = .place }
            else if row.area?.value == "true" { kind = .area }
            else if row.nonplace?.value == "true" { kind = .nonPlace }
            else { kind = .unknown }
            facts[id] = PlaceFacts(sitelinks: n, placeClass: kind)
        }
        return facts
    }
}
