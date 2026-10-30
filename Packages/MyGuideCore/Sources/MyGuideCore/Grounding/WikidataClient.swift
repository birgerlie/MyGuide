import Foundation

/// Fetches sitelink counts and place classes for Wikidata items from the Wikidata Query Service (spec 19).
public struct WikidataClient: Sendable {
    static let endpoint = "https://query.wikidata.org/sparql"
    static let timeout: TimeInterval = 8
    /// Ids per request, and requests per call by default (walking): ids beyond `batchSize * maxBatches` are left out.
    /// Walking asks for up to 6 batches (300 ids): with 100 articles per language a merged list can pass 200 ids
    /// (spec 20.2.4).
    static let batchSize = 50
    public static let maxBatches = 6
    /// Requests per call for a tour, whose area holds far more articles than a walk's list (400 ids).
    public static let tourMaxBatches = 8
    /// Requests in flight at once, whatever the cap, retried halves included.
    static let maxConcurrentBatches = 4

    /// Instance-of classes (through subclass-of) that make an item a place (spec 19.1): architectural structure,
    /// square, park, archaeological site, monument and fountain.
    static let placeClasses = ["Q811979", "Q174782", "Q22698", "Q839954", "Q4989906", "Q483453"]
    /// Hill and island (spec 20.6): `natural`, a place that is at most good and excludes no other place
    /// (spec 20.2.2).
    static let naturalClasses = ["Q54050", "Q23442"]
    /// Work of art: a place too, unless the item is also an organisation, person or event. An order of chivalry
    /// is a decoration in Wikidata (order of chivalry → state order → state decoration → decoration → work of art),
    /// so religious orders such as the Sovereign Military Order of Malta reached `place` this way (spec 20.6, live
    /// check 30 Oct). Kept as its own flag: a SPARQL test per direct class was 4–10 times slower (beyond the 8 s
    /// timeout).
    static let artClasses = ["Q838948"]
    /// Metro station and treaty (spec 20.2.6): `nonPlace` before every other class, since a station is a structure.
    static let neverClasses = ["Q928830", "Q131569"]
    /// Streets and roads (spec 19.1, 20.2.6): `street` even when also a place, since streets are structures in
    /// Wikidata.
    static let streetClasses = ["Q79007", "Q34442"]
    /// Human settlements: `settlement`, below street and place (spec 20.6).
    static let settlementClasses = ["Q486972"]
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

    /// Facts for up to any number of ids (batched by 50, at most `maxBatches` batches; ids beyond are left out). A
    /// failed batch is left out of the result; never throws except CancellationError.
    public func facts(for ids: [String]) async throws -> [String: PlaceFacts] {
        try await lookup(ids: ids).facts
    }

    /// Like `facts(for:)`, and also reports which ids were answered and how many batches failed. At most
    /// `maxBatches` batches of 50 are asked for, in `ids` order (later ids are left out), at most
    /// `maxConcurrentBatches` requests at a time. A batch that fails (an error, a bad answer or the 8 s timeout) is
    /// asked once more as two halves, which go first in the queue and so run concurrently when there is room
    /// (spec 20.2.7); it counts as failed when either half fails, and the ids of a half that answered are answered.
    /// With a `language` other than English, each item's article title in that language is read too
    /// (`PlaceFacts.localTitle`).
    public func lookup(ids: [String], maxBatches: Int = WikidataClient.maxBatches,
                       language: StoryLanguage? = nil) async throws -> Answer {
        var seen = Set<String>()
        let valid = ids.filter { Self.isValid($0) && seen.insert($0).inserted }
            .prefix(Self.batchSize * max(0, maxBatches))
        let batches = stride(from: 0, to: valid.count, by: Self.batchSize).map {
            Array(valid.dropFirst($0).prefix(Self.batchSize))
        }
        let http = http
        let titleCode = Self.titleCode(language)
        /// One request: its ids, the batch it belongs to, and whether it is a retried half.
        struct Work: Sendable {
            var ids: [String]
            var batch: Int
            var isRetry: Bool
        }
        return try await withThrowingTaskGroup(of: (work: Work, facts: [String: PlaceFacts]?).self) { group in
            func add(_ work: Work) {
                group.addTask {
                    do {
                        return (work, try await Self.fetch(work.ids, titleCode: titleCode, http: http))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
                        // The caller is gone: no retry.
                        throw CancellationError()
                    } catch {
                        return (work, nil)
                    }
                }
            }
            var pending = batches.enumerated().map { Work(ids: $0.element, batch: $0.offset, isRetry: false) }
            var running = 0
            func fill() {
                // None starts once the caller is cancelled.
                while running < Self.maxConcurrentBatches, !pending.isEmpty, !Task.isCancelled {
                    add(pending.removeFirst())
                    running += 1
                }
            }
            fill()
            var answer = Answer()
            var failed = Set<Int>()
            while let part = try await group.next() {
                running -= 1
                if let facts = part.facts {
                    answer.answered.formUnion(part.work.ids)
                    answer.facts.merge(facts) { first, _ in first }
                } else if part.work.isRetry {
                    failed.insert(part.work.batch)
                } else {
                    pending.insert(contentsOf: Self.halves(part.work.ids).map {
                        Work(ids: $0, batch: part.work.batch, isRetry: true)
                    }, at: 0)
                }
                // A finished request makes room for the next.
                fill()
            }
            try Task.checkCancellation()
            answer.failedBatches = failed.count
            return answer
        }
    }

    /// "Q" followed by one or more ASCII digits, nothing else. Checked on the UTF-8 bytes: a `Character` comparison
    /// would accept a digit with a combining mark or joiner, which makes a malformed IRI that fails its whole batch.
    static func isValid(_ id: String) -> Bool {
        let bytes = id.utf8
        return bytes.count >= 2 && bytes.first == UInt8(ascii: "Q") && bytes.dropFirst().allSatisfy { (48...57).contains($0) }
    }

    /// The two halves of a failed batch (the first one larger for an odd count); one part for a single id.
    static func halves(_ ids: [String]) -> [[String]] {
        let middle = (ids.count + 1) / 2
        return [Array(ids.prefix(middle)), Array(ids.dropFirst(middle))].filter { !$0.isEmpty }
    }

    /// The Wikipedia code whose titles a lookup in `language` reads; nil for none or English, whose titles the
    /// English candidates already carry.
    static func titleCode(_ language: StoryLanguage?) -> String? {
        guard let language, language != .english else { return nil }
        return language.wikipediaCode
    }

    /// The SPARQL for `ids` (invalid ones skipped): one row per item with its sitelink count and one boolean per
    /// class group, and with `titleCode` (lowercase ASCII letters only, else ignored) the title of the item's
    /// article on that Wikipedia, when there is one.
    static func query(ids: [String], titleCode: String? = nil) -> String {
        func flag(_ name: String, _ classes: [String]) -> String {
            "BIND(EXISTS { VALUES ?c { \(classes.map { "wd:" + $0 }.joined(separator: " ")) } "
                + "?item wdt:P31/wdt:P279* ?c } AS ?\(name))"
        }
        let items = ids.filter(isValid).map { "wd:" + $0 }.joined(separator: " ")
        let code = titleCode.flatMap { code in
            !code.isEmpty && code.utf8.allSatisfy({ (97...122).contains($0) }) ? code : nil
        }
        let title = code.map {
            "OPTIONAL { ?article schema:about ?item ; schema:isPartOf <https://\($0).wikipedia.org/> ; "
                + "schema:name ?title . }\n  "
        } ?? ""
        return """
        SELECT ?item ?n\(code == nil ? "" : " ?title") ?never ?street ?settlement ?area ?place ?natural ?art ?nonplace WHERE {
          VALUES ?item { \(items) }
          ?item wikibase:sitelinks ?n .
          \(title)\(flag("never", neverClasses))
          \(flag("street", streetClasses))
          \(flag("settlement", settlementClasses))
          \(flag("area", areaClasses))
          \(flag("place", placeClasses))
          \(flag("natural", naturalClasses))
          \(flag("art", artClasses))
          \(flag("nonplace", nonPlaceClasses))
        }
        """
    }

    static func request(for ids: [String], titleCode: String? = nil) -> URLRequest {
        // Everything but the RFC 3986 unreserved characters is escaped, so "+", "&" and "=" in the query are safe.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = query(ids: ids, titleCode: titleCode).addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        var request = URLRequest(url: URL(string: "\(endpoint)?query=\(encoded)")!)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        request.setValue(OverpassClient.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func fetch(_ ids: [String], titleCode: String?, http: HTTPClient) async throws -> [String: PlaceFacts] {
        let (data, response) = try await http.send(request(for: ids, titleCode: titleCode))
        guard (200..<300).contains(response.statusCode) else { throw GroundingFetchError.http(response.statusCode) }
        return try parse(data)
    }

    private struct Reply: Decodable {
        struct Value: Decodable { var value: String }
        struct Row: Decodable {
            var item: Value
            var n: Value
            var title: Value?
            var never: Value?
            var street: Value?
            var settlement: Value?
            var area: Value?
            var place: Value?
            var natural: Value?
            var art: Value?
            var nonplace: Value?
        }
        struct Results: Decodable { var bindings: [Row] }
        var results: Results
    }

    /// Rows without a readable id or count are skipped; the first row of an item wins; a missing flag is false.
    /// Class precedence (spec 19.1, 20.6, 20.2.6): metro station or treaty → `nonPlace`; street or road → `street`;
    /// place, or work of art that is not also a non-place → `place`; hill or island → `natural`; settlement →
    /// `settlement`; neighbourhood or administrative area → `area`; else `nonPlace`; else `unknown`. A blank title is
    /// no title.
    static func parse(_ data: Data) throws -> [String: PlaceFacts] {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw GroundingFetchError.malformed }
        var facts: [String: PlaceFacts] = [:]
        for row in reply.results.bindings {
            guard let id = row.item.value.split(separator: "/").last.map(String.init), isValid(id),
                  let n = Int(row.n.value), facts[id] == nil else { continue }
            func flag(_ value: Reply.Value?) -> Bool { value?.value == "true" }
            let nonPlace = flag(row.nonplace)
            let kind: PlaceClass
            if flag(row.never) { kind = .nonPlace }
            else if flag(row.street) { kind = .street }
            else if flag(row.place) || (flag(row.art) && !nonPlace) { kind = .place }
            else if flag(row.natural) { kind = .natural }
            else if flag(row.settlement) { kind = .settlement }
            else if flag(row.area) { kind = .area }
            else if nonPlace { kind = .nonPlace }
            else { kind = .unknown }
            let title = row.title?.value.trimmingCharacters(in: .whitespacesAndNewlines)
            facts[id] = PlaceFacts(sitelinks: n, placeClass: kind, localTitle: title?.isEmpty == false ? title : nil)
        }
        return facts
    }
}
