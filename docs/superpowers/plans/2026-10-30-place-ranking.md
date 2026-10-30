# Place ranking without OpenStreetMap — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Walking mode, the map and tours rank places correctly when Overpass is down. Wikidata facts tier the
Wikipedia-only places and drop organisations. One spot buzzes once. The start is faster. The log shows what the
map showed.

**Architecture:**
- Core:
  - `WikidataClient` (SPARQL) and a facts cache;
  - facts stored on `Candidate`;
  - `PlaceTiers` uses them;
  - `BuzzEngine` orders by sitelinks and excludes same-spot twins;
  - the place sources enrich and stop waiting for a slow OpenStreetMap.
- App: wiring, the stale list at start, and logging of the map's selection.

**Spec:** `docs/superpowers/specs/2026-10-29-around-me-and-notifications-design.md`, section 19 (binding).

**Branch:** `place-ranking`, from `tours` (d6a67d4).

## Global Constraints

- Swift 6 strict concurrency. Core tests: `cd Packages/MyGuideCore && swift test`, now 1534, all green.
- App build:
  `xcodebuild -project MyGuide.xcodeproj -scheme MyGuide -destination 'generic/platform=iOS' -derivedDataPath /tmp/mg-dd -quiet build`
  must show no `error:` lines.
- Wikidata endpoint `https://query.wikidata.org/sparql`. Use GET with `query=` (URL-encoded),
  `Accept: application/sparql-results+json`, and the User-Agent `OverpassClient.userAgent`. Timeout 8 s. At most 50
  ids per request.
- **Classes (spec 19.1):**
  - place: Q811979, Q174782, Q22698, Q839954, Q4989906, Q838948, Q483453;
  - area: Q79007, Q123705, Q56061;
  - nonPlace: Q43229, Q5, Q1656682, Q16334295.
  - Precedence: area > place > nonPlace > unknown.
- **Other values:**
  - sitelinks threshold for `top` is 30;
  - same-spot radius 25 m;
  - OSM grace 5 s;
  - empty-feed retry 15 s;
  - stale list ≤ 7 days and within 250 m;
  - facts cache 30 days.
- Old persisted data decodes unchanged (new fields optional). Walk-log lines without the new fields still decode.
- Tests cover happy, edge, error and boundary cases, with hand computations in comments above numeric assertions.
  Complete implementations only.
- Commit trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push.

## Review Focus

1. **Wikidata down or slow:** the list arrives as today, tiers unchanged, nothing dropped. Pinned in W1/W2.
2. **A candidate without a Wikidata id:** today's tier. Pinned in W2.
3. **An OSM candidate whose Wikidata class is nonPlace** (a church whose item is also an organisation): OSM tags
   decide and it is kept. Pinned in W2.
4. **Same-spot exclusion:** a place 26 m from the buzzed one can still buzz; at 25 m it cannot. Pinned in W2.
5. **A stale list at start is replaced by the fresh one,** and is never used when it is more than 7 days old or
   more than 250 m away. Pinned in W3.

---

### Task W1: Wikidata facts client and cache (core)

**Files:**
- Create `Grounding/WikidataClient.swift` and `Grounding/PlaceFacts.swift`.
- Modify `Grounding/Candidate.swift`: add optional `sitelinks: Int?` and `placeClass: PlaceClass?`. Init parameters
  default to nil. Decoding stays tolerant.
- Tests: `WikidataClientTests.swift` and `PlaceFactsTests.swift`.

**Interfaces:**
```swift
public enum PlaceClass: String, Sendable, Codable { case place, area, nonPlace, unknown }
public struct PlaceFacts: Sendable, Equatable, Codable { public var sitelinks: Int; public var placeClass: PlaceClass }
public struct WikidataClient: Sendable {
    public init(http: HTTPClient)
    /// Facts for up to any number of ids (batched by 50, batches run concurrently, at most 4 batches = 200 ids;
    /// ids beyond are left out). A failed batch is left out of the result; never throws except CancellationError.
    public func facts(for ids: [String]) async throws -> [String: PlaceFacts]
    static func query(ids: [String]) -> String   // SPARQL, testable
}
public actor PlaceFactsCache {
    public init(directory: URL?, now: @escaping @Sendable () -> Date = Date.init)   // nil directory → memory only
    /// Cached facts younger than 30 days; looks up the missing ids through `client` and stores them.
    public func facts(for ids: [String], client: WikidataClient) async throws -> [String: PlaceFacts]
}
extension Array where Element == Candidate {
    /// Sets `sitelinks` and `placeClass` from `facts` (by `wikidata` id); candidates without facts are unchanged.
    public func applying(_ facts: [String: PlaceFacts]) -> [Candidate]
}
```

**SPARQL:** per id, return `?item ?n ?area ?place ?nonplace`:
- `?n` from `wikibase:sitelinks`;
- each flag is `BIND(EXISTS { VALUES ?c { … } ?item wdt:P31/wdt:P279* ?c } AS ?flag)`.

The class follows the precedence in Global Constraints. Ids are validated (`^Q[0-9]+$`) before they enter the
query; invalid ids are skipped.

- [ ] **Tests:**
  - query text contains every class id and only valid ids;
  - parse a recorded answer, using the 30 Oct values in spec 19.2:
    - Q36380 → nonPlace 119;
    - Q719794 place+nonPlace → place 40;
    - Q4010851 place+area → area;
    - Q242839 none → unknown;
  - 120 ids → 3 requests of 50/50/20;
  - 250 ids → 4 requests, 200 ids;
  - an HTTP 500 batch is left out while other batches succeed;
  - a malformed body is left out;
  - cancellation propagates;
  - cache:
    - a hit within 30 days makes no request;
    - at 30 days + 1 s it refetches;
    - it survives a new instance on the same directory;
    - a memory-only cache works;
    - a corrupt cache file is ignored;
  - `applying` leaves candidates without an id or without facts unchanged;
  - an old JSON `Candidate` without the new fields decodes.
- [ ] Commit `feat(places): Wikidata facts — sitelinks and place class, cached 30 days`.

### Task W2: Tiers, buzz order, same spot, sources (core)

**Files:**
- Modify:
  - `Walking/PlaceTier.swift`;
  - `Walking/BuzzEngine.swift`;
  - `Walking/WalkingPlaceSource.swift`;
  - `Tours/TourCandidates.swift` (`TourPlaceSource`);
  - `Grounding/NearbyList.swift` / `NearbyPlaces.swift` as needed;
  - `WalkLog/WalkLogEvent.swift` and `WalkLogCodec.swift` (`fetched` gains `facts: Int` and `dropped: [String]`,
    both omitted when 0/empty).
- Tests in the matching test files.

**Rules (spec 19.2–19.5):**
- `PlaceTiers.tier(for:)`:
  - when the candidate has OSM tags (`tags != nil` and not empty), today's rules decide;
  - otherwise (Wikipedia-only):
    - `nonPlace` → nil;
    - `place` with sitelinks ≥ 30 → top;
    - `place` with fewer → good;
    - `area` and `unknown` → wikiOnly;
    - no facts → today's rule.
- `BuzzEngine`:
  - due order is `(tier, -(sitelinks ?? 0), distance)`;
  - after a buzz, every place in the current `places` within `sameSpotRadius = 25` m (≤ 25 inclusive) of the
    buzzed place is excluded too;
  - the top-tier override keeps its rules and uses the same order.
- `WalkingPlaceSource.candidates`:
  - Wikipedia and Overpass start together;
  - when Wikipedia has answered, the facts lookup runs (through an injected `PlaceFactsCache` + `WikidataClient`;
    both optional, so existing call sites and tests keep working);
  - once Wikipedia and the facts are done, Overpass gets at most `osmGrace = 5` s more, then it is cancelled;
  - the result is `osmFailed: true` with `osmErrors: ["slow"]` when the grace ran out, or with today's errors when
    it failed;
  - facts also apply to OSM candidates that carry `wikidata`, so they get sitelinks for the order; their tier stays
    tag-based;
  - `PlaceSearchResult` gains `factsCount: Int` and `dropped: [String]` (names of Wikipedia-only nonPlace
    candidates);
  - `NearbyList` persists these (optional, default 0/[]) and `WalkingController` logs them in `fetched`.
- `TourPlaceSource`: the same enrichment on its merged candidates before tiering.

- [ ] **Tests**, with hand computations in comments:
  - tier table:
    - nonPlace wiki → nil;
    - place 30 → top;
    - place 29 → good;
    - area 100 → wikiOnly;
    - unknown → wikiOnly;
    - OSM church whose item is nonPlace → good/top by tags;
    - no facts → as before;
  - buzz order: two top places due at 50 m (sitelinks 10) and 20 m (sitelinks 80) → the 80 one;
  - equal sitelinks → nearer;
  - same spot:
    - places 25 m apart → second excluded;
    - 26 m → second can still buzz (needs budget);
    - the excluded one appears as `excluded` in the next decision;
  - source:
    - with a stub Overpass that never answers, the result arrives within Wikipedia time + 5 s (use an injected clock
      or short grace in tests) with `osmErrors == ["slow"]`;
    - facts failing → tiers as today, `factsCount == 0`;
    - dropped names listed;
  - tours: a nonPlace Wikipedia candidate is not a tour candidate;
  - walk log: `fetched` with facts/dropped round-trips; an old line decodes with 0/[].
- [ ] Commit in 2–3 logical commits.

### Task W3: App wiring, faster start, map selection log (core + app)

**Files:**
- Modify:
  - `MyGuide/AppServices.swift` (create the `WikidataClient` and a `PlaceFactsCache` in Caches/PlaceFacts; pass them
    to `WalkingPlaceSource` and `TourPlaceSource`);
  - core `Walking/PlaceFeed.swift` (`emptyRetryInterval = 15`: when `places` is empty, a failure waits 15 s,
    otherwise 60 s);
  - `MyGuide/Walking/WalkingController.swift` (the stale list at start);
  - core `WalkLog` (`fetched` gains `stale: Bool`, omitted when false; new kind `shown(placeID: String?,
    name: String?, reason: String)` where the reason is one of `heading`, `tap`, `buzz`, `cleared`);
  - `MyGuide/Around/AroundModel.swift` (report selection changes to the walking controller while walking mode is
    on; log only when the selected id or reason changes).

**Stale list at start:**
- when walking starts and the feed has no places, `NearbyPlaces` (or its store) is asked for its stored list;
- if that list is centred within 250 m of the first fix, is at most 7 days old and is in the story language, its
  walking places go to the feed at once, logged `fetched` with `stale: true`;
- the feed treats it as needing a refresh, so the normal fetch runs right after;
- a stale list never counts as fresh for `NearbyList.serves`.

- [ ] **Core tests:**
  - PlaceFeed:
    - empty feed failure → `shouldFetch` false at 14.9 s and true at 15 s;
    - non-empty → 59.9 s false, 60 s true;
    - stale places then a fetch → replaced;
  - a stale-list selection helper (pure function in core): 7 days exact is accepted and +1 s rejected; 250 m exact
    is accepted and 250.1 m rejected; another language is rejected;
  - walk log `shown` and `stale` round-trip.
- [ ] App build. Commit `feat(walking): Wikidata ranking wired, faster start, map selection logged`.
