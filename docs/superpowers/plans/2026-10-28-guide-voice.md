# Guide Voice and Richer Grounding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stories sound like a good private guide and stand on real facts: a constant guide system prompt, a structured user message with Apple Maps position, direction, route, recent stories, fuller Wikipedia text, OSM fact tags and Apple Maps places, new lengths, and a "nothing found" ladder.

**Architecture:** All prompt text, lengths, route logic, fact formatting and memory queries live in `Packages/MyGuideCore` (Swift Testing). MapKit work stays in the app behind two core protocols (`ReverseGeocoding`, already there, and the new `PointsOfInterestSearching`). The flows (`PhotoStoryFlow`, `WalkingStoryFlow`) gather the extra context themselves from injected sources, so the app only wires sources and supplies the walking route context.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, SwiftData, MapKit (iOS 26), Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-28-guide-voice-design.md` (parents: `2026-10-26-myguide-design.md`, `2026-10-27-phase-2-walking-mode-design.md`).

## Global Constraints

- Swift 6 language mode, strict concurrency; iOS 26. No new package dependencies.
- The OpenAI key stays in the Keychain; never in source, logs or tests. `store: false` on every Responses call.
- The user's email never goes to any service. Config/Local.xcconfig stays git-ignored.
- The system instructions are **one constant string, byte-identical for every story request** (photo, buzz, stop, continuation, both languages). Language and length go in the user message.
- `prompt_cache_key` is `"myguide-story-v1"`.
- Story lengths (spec 5): app-triggered first level tier 1 → 75 words, tier 2 → 60, tier 3/none → 40, 2–3 points; stop stories capped at 50; owner-triggered (photo first level, any level 2) → 200 words, 3–4 points; level 3 → 300 words, "as many as the facts carry".
- The request is English; only the story is in the story language. Weekdays in English.
- Timeouts: Apple Maps lookups 8 s; Wikipedia article text 5 s. A failed supplementary source never blocks a story.
- Wikipedia/OSM usage policy: one extra Wikipedia request per told place at most; cached.
- Test command for core: `cd Packages/MyGuideCore && swift test`. App build: `xcodegen generate && xcodebuild -project MyGuide.xcodeproj -scheme MyGuide -destination 'generic/platform=iOS' -quiet build` (signing from Config/Local.xcconfig).
- Every numeric assertion has its hand computation in a comment above it (owner rule).
- Complete implementations only; no TODOs. Commit after each task with a conventional message ending in `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A buzz prepared while another is pending** must see the other's text in "Told in the last 3 hours" marked `(prepared)` — Task 6 test `pendingBuzzStoryCountsAsPrepared`.
2. **A stop with nothing within 500 m** must produce no story, no usage, no notification — Task 8 test `stopWithNothingWithin500mIsSilent`, Task 9 checks `ready` is never called.
3. **Walking direction from a track shorter than 100 m or with GPS jitter while standing** must not produce a wild bearing — Task 5 tests `shortPathUsesOldestSample`, `under20mHasNoBearing`.
4. **Old stored data** (Grounding/Address JSON without the new optional fields) must still decode — Task 2 test `addressWithoutDistrictDecodes`, Task 7 test `groundingWithoutApplePlacesDecodes`.
5. **A Norwegian story request** must have the identical system instructions to an English one and carry `Answer in: Norwegian Bokmål` — Task 7 test `instructionsAreOneConstant`.

---

### Task 1: Story lengths

**Files:**
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Story/StoryLength.swift`
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Story/StoryTypes.swift` (remove `targetSeconds`, `targetWords`, `lengthPhrase` from `StoryLevel`; keep `next`)
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Story/PromptBuilder.swift` (only to keep compiling: replace the three uses with `StoryLength` lines; Task 7/8 rewrite these inputs anyway)
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/StoryLengthTests.swift`; update `PromptBuilderTests.levelTargets` and `WalkPromptTests` length expectations

**Interfaces:**
- Produces:
  ```swift
  public enum StoryKind: String, Sendable, Codable { case photo, buzz, stop }
  public struct StoryLength: Sendable, Equatable {
      public var words: Int
      public var points: String          // "2–3", "3–4", "as many as the facts carry"
      public static func of(kind: StoryKind, level: StoryLevel, tier: PlaceTier?) -> StoryLength
      public var seconds: Int             // words · 60 / 150
      public var line: String             // "Length: about 75 words (30 seconds spoken), 2–3 points"
  }
  ```

- [ ] **Step 1: Write the failing tests** in `StoryLengthTests.swift`:
  ```swift
  @Test func buzzFirstLevelScalesWithTier() {
      // spec 5: tier 1 → 75, tier 2 → 60, tier 3 / none → 40
      #expect(StoryLength.of(kind: .buzz, level: .first, tier: .top).words == 75)
      #expect(StoryLength.of(kind: .buzz, level: .first, tier: .good).words == 60)
      #expect(StoryLength.of(kind: .buzz, level: .first, tier: .wikiOnly).words == 40)
      #expect(StoryLength.of(kind: .buzz, level: .first, tier: nil).words == 40)
      #expect(StoryLength.of(kind: .buzz, level: .first, tier: .top).points == "2–3")
  }
  @Test func stopFirstLevelIsCappedAt50() {
      // min(75, 50) = 50; min(60, 50) = 50; min(40, 50) = 40
      #expect(StoryLength.of(kind: .stop, level: .first, tier: .top).words == 50)
      #expect(StoryLength.of(kind: .stop, level: .first, tier: .good).words == 50)
      #expect(StoryLength.of(kind: .stop, level: .first, tier: nil).words == 40)
  }
  @Test func ownerTriggeredLevelsAre200ThenEvenMore300() {
      #expect(StoryLength.of(kind: .photo, level: .first, tier: nil) == StoryLength(words: 200, points: "3–4"))
      for kind in [StoryKind.photo, .buzz, .stop] {
          #expect(StoryLength.of(kind: kind, level: .more, tier: .top) == StoryLength(words: 200, points: "3–4"))
          #expect(StoryLength.of(kind: kind, level: .evenMore, tier: nil) == StoryLength(words: 300, points: "as many as the facts carry"))
      }
  }
  @Test func lineSpellsSecondsOrMinutes() {
      // 75·60/150 = 30 s; 40·60/150 = 16 s; 200·60/150 = 80 s; 300·60/150 = 120 s = 2 minutes
      #expect(StoryLength(words: 75, points: "2–3").line == "Length: about 75 words (30 seconds spoken), 2–3 points")
      #expect(StoryLength(words: 40, points: "2–3").line == "Length: about 40 words (16 seconds spoken), 2–3 points")
      #expect(StoryLength(words: 200, points: "3–4").line == "Length: about 200 words (80 seconds spoken), 3–4 points")
      #expect(StoryLength(words: 300, points: "as many as the facts carry").line
              == "Length: about 300 words (2 minutes spoken), as many as the facts carry")
  }
  ```
  StoryLength needs a memberwise `public init(words:points:)`.

- [ ] **Step 2:** `cd Packages/MyGuideCore && swift test --filter StoryLengthTests` → FAIL (type missing).
- [ ] **Step 3:** Implement. `line` uses minutes only when `seconds >= 60 && seconds % 60 == 0` ("2 minutes", "1 minute" for 60); otherwise "N seconds". Remove the `StoryLevel` length members and make `PromptBuilder` compile using `StoryLength.of(...).line` (photo first: `.photo/.first/nil`; photo continuation: `.photo/level/nil`; walk buzz: `.buzz/.first/buzz.place.tier`; stop: `.stop/.first/best tier of listed places`; walk continuation: story kind/level/nil). Update the two old tests to the new values.
- [ ] **Step 4:** `swift test` → all pass.
- [ ] **Step 5:** Commit `feat(story): lengths by trigger and place tier`.

### Task 2: Guide vocabulary — district, street, sides, time, OSM facts

**Files:**
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Grounding/Candidate.swift` (`Address.district`)
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Grounding/OverpassClient.swift` (`keptTagKeys`)
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Story/GuideText.swift`
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/GuideTextTests.swift`, extend `OverpassClientTests`

**Interfaces:**
- Produces:
  ```swift
  // Address: new `public var district: String?`, init gains `district: String? = nil` after `line`;
  // display = [line, district, city, country] non-nil joined ", ".
  public enum GuideText {
      /// Removes every whitespace-separated token containing a digit: "Kirkegata 15" → "Kirkegata", "15 Main St" → "Main St".
      /// nil when nothing is left.
      public static func streetName(fromAddressLine: String?) -> String?
      /// Side of `bearing` relative to `direction` (compass degrees). nil direction → compass word ("north-east").
      public static func side(bearing: Double, direction: Double?) -> String
      /// "40 m, to your right" — distance via BuzzText.roundedDistance.
      public static func distanceAndSide(distance: Double, bearing: Double, direction: Double?) -> String
      /// "12:40 Wednesday" in `timeZone`, 24-hour, English weekday.
      public static func time(_ date: Date, timeZone: TimeZone) -> String
      /// "HH:mm" in `timeZone`.
      public static func clock(_ date: Date, timeZone: TimeZone) -> String
      /// "OSM: start_date=1697; architect=…" from the fact keys present, nil when none. Values over 200 characters
      /// cut with TextTrim.truncate.
      public static func osmFacts(_ tags: [String: String]?) -> String?
      /// The order osmFacts prints: start_date, architect, building:architecture, artist_name, inscription,
      /// description, name:etymology, memorial:type, material, heritage, heritage:operator.
      public static let factTagKeys: [String]
  }
  ```
  Side words, with r = bearing − direction normalised into (−180, 180]: |r| ≤ 30 "ahead"; 30 < r ≤ 60 "ahead-right"; 60 < r ≤ 120 "to your right"; 120 < r ≤ 150 "behind-right"; mirrored negatives "ahead-left", "to your left", "behind-left"; |r| > 150 "behind". A direction is usable when finite and ≥ 0.

- [ ] **Step 1: Write the failing tests:**
  ```swift
  @Test func sides() {
      // r = 90 − 0 = 90 → (60,120] right;  r = 350 − 10 = 340 → −20 → ahead;  r = 200 − 0 = 200 → −160 → behind
      #expect(GuideText.side(bearing: 90, direction: 0) == "to your right")
      #expect(GuideText.side(bearing: 350, direction: 10) == "ahead")
      #expect(GuideText.side(bearing: 200, direction: 0) == "behind")
      // boundaries: r = 30 → ahead; r = 60 → ahead-right; r = −135 → behind-left; r = 150 → behind-right; r = 151 → behind
      #expect(GuideText.side(bearing: 30, direction: 0) == "ahead")
      #expect(GuideText.side(bearing: 60, direction: 0) == "ahead-right")
      #expect(GuideText.side(bearing: 225, direction: 0) == "behind-left")
      #expect(GuideText.side(bearing: 150, direction: 0) == "behind-right")
      #expect(GuideText.side(bearing: 151, direction: 0) == "behind")
      #expect(GuideText.side(bearing: 45, direction: nil) == "north-east")
      #expect(GuideText.side(bearing: 45, direction: -1) == "north-east")
  }
  @Test func distanceAndSide() {
      // 37 m → nearest 10 = 40
      #expect(GuideText.distanceAndSide(distance: 37, bearing: 270, direction: 0) == "40 m, to your left")
  }
  @Test func streetNames() {
      #expect(GuideText.streetName(fromAddressLine: "Kirkegata 15") == "Kirkegata")
      #expect(GuideText.streetName(fromAddressLine: "15 Main St") == "Main St")
      #expect(GuideText.streetName(fromAddressLine: "Karl Johans gate 22B") == "Karl Johans gate")
      #expect(GuideText.streetName(fromAddressLine: "42") == nil)
      #expect(GuideText.streetName(fromAddressLine: nil) == nil)
  }
  @Test func timeIsEnglishAnd24Hour() {
      // 2026-10-28T11:40:00Z = 12:40 CET (UTC+1, after the 2026-10-25 DST change), a Wednesday
      let d = ISO8601DateFormatter().date(from: "2026-10-28T11:40:00Z")!
      #expect(GuideText.time(d, timeZone: TimeZone(identifier: "Europe/Oslo")!) == "12:40 Wednesday")
      #expect(GuideText.clock(d, timeZone: TimeZone(identifier: "UTC")!) == "11:40")
  }
  @Test func osmFactsInFixedOrderAndCut() {
      let long = String(repeating: "a ", count: 150)   // 300 characters
      let text = GuideText.osmFacts(["architect": "Linstow", "start_date": "1697", "historic": "church", "inscription": long])!
      #expect(text.hasPrefix("OSM: start_date=1697; architect=Linstow; inscription="))
      #expect(!text.contains("historic"))
      #expect(text.count < 300)
      #expect(GuideText.osmFacts(["historic": "church"]) == nil)
      #expect(GuideText.osmFacts(nil) == nil)
  }
  @Test func addressWithoutDistrictDecodes() throws {
      let old = #"{"line":"Kirkegata 15","city":"Oslo","country":"Norway"}"#.data(using: .utf8)!
      let a = try JSONDecoder().decode(Address.self, from: old)
      #expect(a.district == nil && a.display == "Kirkegata 15, Oslo, Norway")
      #expect(Address(line: "Kirkegata 15", district: "Kvadraturen", city: "Oslo").display == "Kirkegata 15, Kvadraturen, Oslo")
  }
  ```
  In `OverpassClientTests`, add one test that an element with `start_date`, `architect`, `inscription`, `description`, `artist_name`, `name:etymology`, `wikidata`, `heritage:operator`, `memorial:type`, `material`, `building:architecture` keeps all of them in `tags`, and `shop`-free unrelated keys (e.g. `opening_hours`) are dropped.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement. Use a `DateFormatter` with `locale = Locale(identifier: "en_US_POSIX")`, formats `"HH:mm EEEE"` and `"HH:mm"`. Add the 11 keys of spec 7.2 to `keptTagKeys`.
- [ ] **Step 4:** `swift test` → pass.
- [ ] **Step 5:** Commit `feat(grounding): district, street names, sides, time and OSM fact tags`.

### Task 3: Wikipedia article text with cache

**Files:**
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Grounding/WikipediaClient.swift`
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Grounding/ArticleTextCache.swift`
- Test: extend `WikipediaClientTests`; create `ArticleTextCacheTests.swift`

**Interfaces:**
- Produces:
  ```swift
  extension WikipediaClient {
      public static let articleTextLimit = 4_000
      /// Plain text of the article (intro plus following sections), cut to `articleTextLimit` with TextTrim.truncate.
      /// `wikipediaTitle` is "code:Title" (Candidate.wikipediaTitle). Throws on HTTP/API/malformed errors and on a
      /// missing page; throws GroundingFetchError.malformed for a title without a "code:" prefix.
      public func articleText(wikipediaTitle: String) async throws -> String
  }
  public protocol ArticleTextSource: Sendable {
      /// The article text, or nil on any failure or after the timeout. Never throws.
      func text(wikipediaTitle: String) async -> String?
  }
  public actor ArticleTextCache: ArticleTextSource {
      public static let capacity = 50
      public init(client: WikipediaClient, timeout: Duration = .seconds(5))
  }
  ```
  Request: `https://<code>.wikipedia.org/w/api.php?action=query&format=json&formatversion=2&prop=extracts&explaintext=1&exsectionformat=plain&redirects=1&titles=<percent-encoded title>` with the existing User-Agent and a 10 s request timeout. No `exintro`, so the whole article comes back; cut locally.
  Cache: successful texts only (a failure is retried next time); when full, the least recently used entry goes. Timeout via `GroundingService.withTimeout`. *(Ruling: spec 7.1 says cached per trip or session; one process-wide cache of 50 serves both and is smaller than a trip's places.)*

- [ ] **Step 1: Failing tests** (StubHTTPClient): URL contains `de.wikipedia.org`, `titles=Michaelertor`, `explaintext=1`, no `exintro`; a 5,000-character extract comes back ≤ 4,001 characters ending in `…`; a page with `"missing": true` throws; a title "Michaelertor" (no prefix) throws `.malformed`. Cache: second call for the same title makes no second HTTP request (stub counts requests); a failed fetch returns nil and the next call fetches again; 51 distinct titles evict the least recently used (title 1 refetched after touching titles 2…51).
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test` → pass.
- [ ] **Step 5:** Commit `feat(grounding): fuller Wikipedia text for the told place, cached`.

### Task 4: Apple Maps places in core

**Files:**
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Grounding/ApplePlace.swift`
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/ApplePlaceTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ApplePlace: Sendable, Equatable, Codable {
      public var name: String
      public var category: String        // lowercase words, e.g. "museum", "café"
      public var coordinate: Coordinate
  }
  public protocol PointsOfInterestSearching: Sendable {
      func places(around: Coordinate, radius: Double) async throws -> [ApplePlace]
  }
  public enum ApplePlaces {
      public static let walkingRadius = 150.0
      public static let photoRadius = 250.0
      public static let limit = 8
      public static let timeout: Duration = .seconds(8)
      /// Searches with the timeout; nil on failure or timeout (cancellation propagates).
      public static func fetch(_ search: PointsOfInterestSearching?, around: Coordinate, radius: Double) async throws -> [ApplePlace]?
      /// Nearest first, at most `limit`, dropping names equal (case- and diacritic-insensitive, trimmed) to any of `knownNames`.
      public static func select(_ places: [ApplePlace], from: Coordinate, knownNames: [String]) -> [ApplePlace]
  }
  ```
- [ ] **Step 1: Failing tests:** `select` sorts by distance, caps at 8 from 10, drops "Oslo domkirke" when known is "OSLO DOMKIRKE" and "Café Ål" when known is "cafe al"; `fetch(nil, …)` returns nil; a throwing search returns nil; a search sleeping past a 0.05 s timeout returns nil (make the timeout injectable: `fetch(_:around:radius:timeout:)` with default `timeout`).
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement (folding with `.caseInsensitive, .diacriticInsensitive`). **Step 4:** pass.
- [ ] **Step 5:** Commit `feat(grounding): Apple Maps places, selection and timeout`.

### Task 5: Route memory and walk context

**Files:**
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/RouteMemory.swift`
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/RouteMemoryTests.swift`

**Interfaces:**
- Consumes: `TrackSample`, `GeoMath.distance/bearing`, `GuideText.streetName`.
- Produces:
  ```swift
  public struct CameFrom: Sendable, Equatable {
      public var street: String
      public var minutesAgo: Int          // whole minutes, rounded down
      public var distance: Double         // straight line, metres
      public var bearing: Double          // from the current position to that point
      public var along: String?           // the current street, when it covered the whole stretch since then
  }
  public struct WalkContext: Sendable, Equatable {
      public var address: Address?        // nil = lookup failed
      public var bearing: Double?         // walking direction; nil = unknown
      public var street: String?          // current street
      public var cameFrom: CameFrom?
      public init(address: Address?, bearing: Double?, street: String?, cameFrom: CameFrom?)
  }
  public struct RouteMemory: Sendable {
      public static let bearingPath = 100.0, minimumBearingPath = 20.0
      public static let lookupSpacing = 100.0
      public static let windowPath = 300.0, windowTime: TimeInterval = 300
      public static let addressReuseDistance = 50.0
      public init()
      public mutating func add(_ sample: TrackSample)
      /// Bearing from the sample `bearingPath` back along the path (or the oldest, when the path is at least
      /// `minimumBearingPath`) to the newest sample; nil below that.
      public var walkingBearing: Double? { get }
      /// True when there are samples and no lookup yet, or the path since the last lookup is ≥ `lookupSpacing`.
      public var needsStreetLookup: Bool { get }
      /// Records a lookup at the newest sample. nil (failed) still resets the spacing: skipped, not retried.
      public mutating func recordLookup(_ address: Address?, at: Date)
      /// The newest looked-up address within `addressReuseDistance` of `position`.
      public func recentAddress(near position: Coordinate) -> Address?
      public func context(address: Address?, course: Double?, now: Date) -> WalkContext
      public mutating func reset()
  }
  ```
  `context`: bearing = `walkingBearing ?? usable course`; street = streetName of `address?.line`; cameFrom = the oldest successful lookup whose path offset to the newest sample is ≤ 300 m and age ≤ 300 s, excluding lookups less than 30 m (path) back *(ruling: a lookup at the current spot is not "came from")*; `along` = current street when every successful lookup newer than that one has the current street and the current street differs from the came-from street. Samples beyond 400 m of path or 10 minutes are trimmed.

- [ ] **Step 1: Failing tests** (use `Coordinate.at(north:east:)` from Support/Metres.swift):
  ```swift
  @Test func bearingFrom100mBack() {
      // samples every 10 m due north for 150 m → the sample 100 m back is due south → bearing 0 (north)
      var r = RouteMemory(); for i in 0...15 { r.add(sample(north: Double(i) * 10, t: Double(i) * 7)) }
      #expect(abs(r.walkingBearing! - 0) < 0.5)
  }
  @Test func shortPathUsesOldestSample() {
      // 0 → 30 m east: path 30 ≥ 20 → bearing 90
      var r = RouteMemory(); r.add(sample(east: 0, t: 0)); r.add(sample(east: 30, t: 20))
      #expect(abs(r.walkingBearing! - 90) < 0.5)
  }
  @Test func under20mHasNoBearing() {
      // path 15 m < 20
      var r = RouteMemory(); r.add(sample(north: 0, t: 0)); r.add(sample(north: 15, t: 10))
      #expect(r.walkingBearing == nil)
      #expect(r.context(address: nil, course: 270, now: .now).bearing == 270)
      #expect(r.context(address: nil, course: -1, now: .now).bearing == nil)
  }
  @Test func lookupEvery100mAndFailuresAreNotRetried() { /* add 0 m → needs; record nil; 60 m → false; 100 m → true */ }
  @Test func cameFromOldestStreetInWindowWithAlong() {
      // lookups: "Stortorvet 1" at 0 m (t=0), "Kirkegata 3" at 100 m (t=72), "Kirkegata 15" at 200 m (t=144); now t=180 at 220 m north.
      // came from Stortorvet: path 220 ≤ 300, age 180 ≤ 300; distance 220 m, bearing 180 (south), 3 min (180/60 = 3);
      // along Kirkegata (both newer lookups are Kirkegata, which differs from Stortorvet)
  }
  @Test func cameFromDropsLookupsOlderThan5Minutes() { /* lookup at t=0, now t=301 → nil */ }
  @Test func cameFromDropsLookupsBeyond300mPath() { /* lookup at 0 m, now at 310 m path → nil */ }
  @Test func recentAddressReusedWithin50m() { /* lookup at 0; position 40 m → address; 60 m → nil */ }
  @Test func resetClearsEverything() { }
  ```
  Write the elided bodies fully, with the hand computation above each assertion.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** pass.
- [ ] **Step 5:** Commit `feat(walking): route memory for direction, street lookups and came-from`.

### Task 6: Recently told stories

**Files:**
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Story/RecentStory.swift`
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Memory/MemoryStore.swift` (new query)
- Test: extend `MemoryStoreTests` / `WalkMemoryTests`; create `RecentStoryTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct RecentStory: Sendable, Equatable {
      public var toldAt: Date              // StoryRecord.createdAt
      public var placeName: String?        // capture subject, buzz place name; nil for stop stories
      public var level: StoryLevel
      public var text: String
      public var prepared: Bool            // buzz story level 1 written but not heard yet
  }
  public typealias RecentStoryLookup = @Sendable (_ since: Date, _ excludingSession: UUID?) async -> [RecentStory]
  public enum RecentStories {
      public static let window: TimeInterval = 3 * 3600
      public static let limit = 10
      public static let sentenceLimit = 160
      /// Up to and including the first ". ", "! " or "? " (or the whole text), then TextTrim.truncate to 160.
      public static func firstSentence(_ text: String) -> String
      /// `- 11:58 Akershus Fortress level 1: "…"`, `this spot` for nil names, ` (prepared)` appended when prepared.
      public static func line(_ story: RecentStory, timeZone: TimeZone) -> String
      /// Priors whose (level, text) is not among `recent`.
      public static func priorsNotRecent(_ priors: [PriorStory], recent: [RecentStory]) -> [PriorStory]
  }
  extension MemoryStore {
      /// Story levels created at or after `since`, newest first, at most RecentStories.limit: photo levels; stop story
      /// levels; buzz levels ≤ the buzz's deepestLevel; and level 1 of a buzz whose outcome is pending and deepestLevel 0,
      /// marked prepared. Excludes the capture or walk story `excludingSession`.
      public func recentStories(since: Date, excludingSession: UUID?) throws -> [RecentStory]
  }
  ```
  *(Ruling: spec 6.7 names `PreparedWalkStories`; a buzz story is saved to memory when prepared and its buzz stays `pending` until heard, skipped or ignored, so "pending, deepest 0" in memory is exactly the prepared set and needs no app plumbing.)*

- [ ] **Step 1: Failing tests:** `pendingBuzzStoryCountsAsPrepared` (buzz recorded pending, story saved → one RecentStory, prepared true, placeName = buzz place name); heard buzz to level 2 of 3 → levels 1–2, not prepared; ignored buzz → none; stop story → placeName nil; photo session → subject name; story older than `since` excluded; 12 stories → 10 newest; `excludingSession` drops that story. `firstSentence("Built in 1697. It burned.") == "Built in 1697."`; a 300-character single sentence → ≤ 161 characters ending in `…`. `line` format exact for prepared and stop cases using `TimeZone(identifier: "UTC")`. `priorsNotRecent` drops an equal (level, text) and keeps others.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** pass.
- [ ] **Step 5:** Commit `feat(memory): stories told in the last three hours`.

### Task 7: Guide voice, request plumbing and photo stories

**Files:**
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/OpenAI/OpenAIClient.swift` (`promptCacheKey`)
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Story/PromptBuilder.swift` (system constant; photo first and continuation inputs; `era` description)
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Story/PhotoStoryFlow.swift`
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Grounding/Candidate.swift` (`Grounding.applePlaces: [ApplePlace]?`, default nil)
- Test: `PromptBuilderTests`, `PhotoStoryFlowTests`, `OpenAIClientTests`

**Interfaces:**
- Consumes: Tasks 1–4, 6.
- Produces:
  ```swift
  // OpenAIClient.respond gains `promptCacheKey: String? = nil`; when set, body["prompt_cache_key"] = .string(key).
  extension PromptBuilder {
      public static let systemInstructions: String          // spec 4 text exactly, ◆ marks removed
      public static let promptCacheKey = "myguide-story-v1"
      static func photoFirstInput(capture: CaptureContext, grounding: Grounding, recent: [RecentStory],
                                  priors: [PriorStory], language: StoryLanguage, now: Date, timeZone: TimeZone) -> String
      static func photoContinuationInput(session: StorySession, level: StoryLevel, articleText: String?,
                                         recent: [RecentStory], priors: [PriorStory], now: Date, timeZone: TimeZone) -> String
  }
  // PhotoStoryFlow.init gains (after priors): recent: RecentStoryLookup = { _, _ in [] },
  //   pointsOfInterest: PointsOfInterestSearching? = nil, articles: ArticleTextSource? = nil, timeZone: TimeZone = .current
  ```
  `systemInstructions(language:)` is removed; every caller uses the constant. Every `respond` call for a story passes `promptCacheKey: PromptBuilder.promptCacheKey`.

  **Photo first input** (fields in this order, spec 6): `Story: photo, first level` · `Position: <address.display>` or `Position: address lookup failed`, then the existing coordinate/accuracy/substitute lines · `Time: <GuideText.time>` · `Facing: south-east (135°), compass ±10°` or `Facing: unknown — identify the subject from position and the photo alone, and be more cautious.` · `Map data unavailable: …` (as today) · `Nearby:` with, per ranked candidate, `- [id] Name (kind), <GuideText.distanceAndSide(distance, bearing, usable heading)>` + `, in view`/`, out of view` when known, then `  Summary: …` and `  <osmFacts>` lines when present; or `Nearby: none found` · `Also on Apple Maps:` lines `- Name (category), <distanceAndSide>` from `grounding.applePlaces` selected with known names = candidate names (field omitted when nil or empty) · `Told in the last 3 hours:` + lines, or `Told in the last 3 hours: nothing` · `Told here before:` + existing prior lines (from `priorsNotRecent`), or `Told here before: nothing` · `StoryLength.of(.photo, .first, nil).line` · `Answer in: <promptName>` · `Task: Identify what the photo shows, preferring places in view. Set matchedCandidateID only if the subject is one of the listed places (use its id in brackets). Then tell the user about it. If nothing listed matches what you see, talk about what can actually be seen in the frame and say plainly that you know no recorded history of it.`

  **Photo continuation input:** `Story: photo, level N` · Position · Time · Facing · `Subject: <subject> (confidence: …)` · if matched: `Facts about <name>:` with `  <osmFacts>` and `  Wikipedia: <articleText ?? summary>`; else `Nearby:` for `factCandidates` with summaries and OSM lines (or `Facts: none found`) · `Also on Apple Maps:` (from the session's grounding) · `Told so far:` + `Level i: text` · recent · told-before · length · answer-in · `Task: Continue from where the story left off; new points, from another domain where the facts allow; do not repeat.`

  `era` schema description: `"The era the subject is best known from, e.g. 'built 1697' or 'around 1780'"`.

  **PhotoStoryFlow:** first story runs grounding and `ApplePlaces.fetch(pointsOfInterest, around:, radius: ApplePlaces.photoRadius)` concurrently; stores the result in `grounding.applePlaces`; recent = `recent(now − RecentStories.window, nil)`; continuation fetches `articles?.text(wikipediaTitle:)` for the matched candidate when it has a title, and recent with the session id excluded.

- [ ] **Step 1: Failing tests:**
  - `instructionsAreOneConstant`: `PromptBuilder.systemInstructions` contains "You are a brilliant private guide", "Never recommend a particular restaurant", "Told in the last 3 hours", "no recorded history"; contains no "{{", "◆", "English", "Norwegian". A stub-HTTP photo flow run in `.norwegian` and one in `.english` send byte-identical `instructions`, both send `"prompt_cache_key":"myguide-story-v1"`, and the Norwegian input contains `Answer in: Norwegian Bokmål`.
  - `photoFirstInputFieldOrder`: for a fixture with address, heading 135 ± 10, one in-view candidate with tags `start_date=1697`, one Apple place, one recent story and one prior, the prefixes of the non-indented lines are in order `Story:`, `Position:`, (coordinate line), `Time:`, `Facing:`, `Nearby:`, `Also on Apple Maps:`, `Told in the last 3 hours:`, `Told here before:`, `Length:`, `Answer in:`, `Task:`; the candidate line is `- [osm:way/1] Michaelertor (historic=building), 40 m, behind, in view` *(35.4 m → 40; r = 304.6 − 135 = 169.6 → |r| > 150 → "behind")*; `  OSM: start_date=1697` follows; Length line is `Length: about 200 words (80 seconds spoken), 3–4 points`.
  - `photoNothingFound`: no candidates, no Apple places → `Nearby: none found`, no `Also on Apple Maps:` line, Task contains "no recorded history".
  - `addressFailedSaysSo`: grounding address nil → `Position: address lookup failed`.
  - `groundingWithoutApplePlacesDecodes`: old Grounding JSON without the key decodes with `applePlaces == nil`.
  - `continuationUsesArticleTextForMatched`: articles stub returns "FULL TEXT" → `  Wikipedia: FULL TEXT` under `Facts about Michaelertor:`; when the stub returns nil → the summary; unmatched session → `Nearby:` with up to 3 places.
  - `recentPriorsAreNotRepeatedInToldHereBefore`.
  - `OpenAIClientTests`: `prompt_cache_key` present when given, absent when nil.
- [ ] **Step 2:** FAIL. **Step 3:** Implement; delete the old `firstStoryInput`/`continuationInput` and their now-obsolete tests (replace, do not keep both). **Step 4:** `swift test` → pass.
- [ ] **Step 5:** Commit `feat(story): guide voice, structured request and richer photo grounding`.

### Task 8: Walking stories — structured input and the nothing-found ladder

**Files:**
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Story/PromptBuilder.swift` (walking inputs)
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/WalkingStoryFlow.swift`
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/WalkStory.swift` (`applePlaces: [ApplePlace]? = nil`, in memory only; `tier: PlaceTier?` is not needed)
- Test: `WalkPromptTests`, `WalkingStoryFlowTests`

**Interfaces:**
- Consumes: Tasks 1–7 (`WalkContext`, `CameFrom`, `GuideText`, `ApplePlaces`, `ArticleTextSource`, `RecentStoryLookup`, `StoryLength`, `PromptBuilder.systemInstructions/promptCacheKey`).
- Produces:
  ```swift
  public struct WalkingStoryFlow {
      public static let detourRadius = 500.0
      public static let detourLimit = 2
      public init(openAI:, models: = .current, priors: = …, recent: RecentStoryLookup = { _, _ in [] },
                  pointsOfInterest: PointsOfInterestSearching? = nil, articles: ArticleTextSource? = nil,
                  timeZone: TimeZone = .current, now: = Date.init, makeID: = UUID.init)
      public func buzzStory(_ buzz: Buzz, position: Coordinate, context: WalkContext, nearby: [WalkingPlace],
                            language: StoryLanguage) async throws -> (WalkStory, [UsageEntry])
      /// nil: nothing within `detourRadius` — no request is made (spec 9 step 4).
      public func stopStory(position: Coordinate, context: WalkContext, nearby: [WalkingPlace],
                            language: StoryLanguage) async throws -> (WalkStory, [UsageEntry])?
      public func continueStory(_ story: WalkStory, nearby: [WalkingPlace]) async throws -> (WalkStory, [UsageEntry])
  }
  ```
  WalkStory keeps `address` (now also set for buzz stories from `context.address`) and `course` (= `context.bearing`).

  **Shared walking lines** (spec 6): `Position: <display>` or `Position: address lookup failed` · `Time:` · direction: buzz `Walking: north along Kirkegata` / `Walking: north` (no street) / `Walking: direction unknown`; stop `Standing still; walked in heading north along Kirkegata` / `Standing still` · `Came from: <street>, <N> min ago, <distanceAndSide(distance, bearing, context.bearing)>` + `, along <street>` when set; `N min ago` is `under a minute ago` for 0 (buzz only; never on stop stories, which follow a standstill).

  **Buzz input:** `Story: walking buzz, first level` · shared lines · `Subject: <name> (<kind>), <distanceAndSide(buzz.distance, buzz.bearing, context.bearing)>` · `Facts about <name>:` + `  <osmFacts>` + `  Wikipedia: <article text ?? summary>` (block omitted when it would be empty) · `Nearby:` from `buzzFacts` (limit 4, tier then distance) as `- Name (kind), <distanceAndSide>` + OSM line · `Also on Apple Maps:` (radius `ApplePlaces.walkingRadius`, known names = subject + nearby) · recent · told-before · `StoryLength.of(.buzz, .first, buzz.place.tier).line` · answer-in · `Task: Tell the user about the subject they are passing.`

  **Stop ladder:** listed = `stopFacts` (≤ 150 m, ≤ 5). If listed is non-empty → normal stop: `Story: stop, first level`, `Facts about` the first listed (best tier, nearest), `Nearby:` the rest, length `.stop/.first/listed[0].tier`, `Task: Tell the user about the spot where they are standing.` Else, places within `detourRadius` exist → `Worth the detour:` the best `detourLimit` (tier, then distance) as `- Name (kind), <distanceAndSide>`, length `.stop/.first/nil` (40 words), `Task: There is little to tell right here: say so in one sentence, then point them to the place worth the detour.` Else → return nil without calling OpenAI, POI search or Wikipedia.

  **Continuation input:** `Story: <walking buzz|stop>, level N` · shared lines from the stored story (`address`, `course`; no came-from) · Time now · buzz: Subject + Facts (article text) / stop: `Nearby:` from `stopFacts(nearby, story.position)` · `Also on Apple Maps:` from `story.applePlaces`, fetched again when nil · `Told so far:` · recent (excluding the story id) · told-before · `StoryLength.of(kind, level, nil).line` · answer-in · the continuation Task of Task 7. *(Ruling: spec 6.9 asks for a fresh position on continuations; the walking flow does not get the current position on "More", and "More" is tapped within seconds of the first level, so the story's own position is used. Cost if wrong: a stale side in a nudge.)*

- [ ] **Step 1: Failing tests:**
  - `buzzInputFieldOrderAndLines`: context with address "Kirkegata 15, Kvadraturen, Oslo", bearing 0, street "Kirkegata", cameFrom (Stortorvet, 3 min, 220 m, bearing 180, along Kirkegata); buzz place tier `.top` at distance 40, bearing 90 → lines `Walking: north along Kirkegata`, `Came from: Stortorvet, 3 min ago, 220 m, behind, along Kirkegata` *(r = 180 − 0 = 180 → behind)*, `Subject: Michaelertor (historic=city_gate), 40 m, to your right` *(r = 90 → right)*, `Length: about 75 words (30 seconds spoken), 2–3 points`, and the field order as in spec 6.
  - `buzzWithoutAddressSaysLookupFailed`, `buzzWithoutDirectionSaysUnknown`.
  - `buzzUsesArticleTextAndFallsBackToSummary` (stub `ArticleTextSource`).
  - `stopWithPlacesWithin150mIsNormal`: length 50 for a `.top` listed place *(min(75, 50))*.
  - `stopWithOnlyDistantPlacesPointsToDetour`: places at 300 m (`.good`) and 450 m (`.top`) and 600 m → `Worth the detour:` lists the 450 m `.top` place then the 300 m `.good`; the 600 m one absent; length 40.
  - `stopWithNothingWithin500mIsSilent`: returns nil; the stub HTTP client received zero requests; the POI stub was not called.
  - `continuationOfStopListsNearbyPlaces`, `continuationReusesApplePlaces` (POI stub called once across first level + "More").
  - Existing `WalkingStoryFlowTests` updated to the new signatures; delete tests of removed input text.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. Remove `walkBuzzInput`/`walkStopInput`/`walkContinuationInput` old texts. **Step 4:** `swift test` → pass (whole suite).
- [ ] **Step 5:** Commit `feat(walking): guide-voice walking requests and the nothing-found ladder`.

### Task 9: App wiring — MapKit, walking route, specs

**Files:**
- Modify: `MyGuide/Platform/MapKitReverseGeocoder.swift` (district)
- Create: `MyGuide/Platform/MapKitPointsOfInterest.swift`
- Modify: `MyGuide/AppServices.swift` (shared `ArticleTextCache`, `recentLookup`, POI search into both flows)
- Modify: `MyGuide/Walking/WalkingStories.swift` (`prepare`/`prepareStop` take a context provider; stop nil is silent; `currentPlaces` for "More")
- Modify: `MyGuide/Walking/WalkingController.swift` (RouteMemory, street lookups, contexts, reset after a stop story and on stop)
- Modify: `docs/superpowers/specs/2026-10-26-myguide-design.md` (sections 3 and 6 per guide-voice spec 10), `docs/superpowers/specs/2026-10-27-phase-2-walking-mode-design.md` (7.5, 7.6 pointers), `README.md` line 26 (walking button is on Home)

**Interfaces:**
- Consumes: everything above.
- Produces (app-internal):
  ```swift
  struct MapKitPointsOfInterest: PointsOfInterestSearching   // MKLocalPointsOfInterestRequest(center:radius:) with
                                                             // MKPointOfInterestFilter(including:) of spec 7.3's categories
  // WalkingStories
  func prepare(_ buzz: Buzz, position: Coordinate, nearby: [WalkingPlace], language: StoryLanguage,
               context: @escaping @MainActor () async -> WalkContext)
  func prepareStop(position: Coordinate, nearby: [WalkingPlace], language: StoryLanguage,
                   context: @escaping @MainActor () async -> WalkContext,
                   ready: @escaping @MainActor (WalkStory) -> Void)
  var currentPlaces: (@MainActor () -> [WalkingPlace])?
  ```
  - **District:** read it from the iOS 26 `MKMapItem` address representations; verify the field in the SDK headers (`MKAddressRepresentations`, `MKAddress`) and pick the one that gives the neighbourhood/sub-locality; if the SDK has none, leave `district` nil and say so in the report.
  - **POI categories → words:** museum, landmark, castle, fortress, monument, park, national park, library, university, theater, music venue, stadium, zoo, aquarium, planetarium, spring, beach, bakery, restaurant, café, brewery, winery, market. Skip any case missing from the iOS 26 SDK and list the skipped ones in the report. Map items without a name are dropped. MapKit objects stay on the main actor, as in `MapKitReverseGeocoder`.
  - **WalkingController:** a `RouteMemory` per run. Every stored track sample is also added to it. When `needsStreetLookup` and no lookup is in flight, start one (`Self.address(at:)`, 8 s) and `recordLookup` the result (nil on failure). The buzz context provider: `route.recentAddress(near: position)` or a fresh `Self.address(at:)`, then `route.context(address:course:now:)`. The stop context: same, and `route.reset()` after `deliverStop` runs. `route.reset()` in `stop()`. `stories.currentPlaces = { [weak self] in self?.feed.places ?? [] }`.
  - **WalkingStories.prepareStop:** a nil result from the flow ends silently (no `ready`, no usage recorded since none was spent, nothing saved).
  - **AppServices:** one `ArticleTextCache(client: WikipediaClient(http: http))` for the app's lifetime; `recentLookup(memory:)` mirroring `priorLookup` (memory failure → logged, `[]`); both flows get `recent`, `pointsOfInterest: MapKitPointsOfInterest()`, `articles`.
- [ ] **Step 1:** Implement the app changes; `xcodegen generate && xcodebuild … build` → BUILD SUCCEEDED with no new warnings in the touched files.
- [ ] **Step 2:** `cd Packages/MyGuideCore && swift test` → all pass.
- [ ] **Step 3:** Apply the spec edits (guide-voice spec section 10) and the README fix.
- [ ] **Step 4:** Commit `feat(app): Apple Maps places, district and walking route in story requests`.

---

## Self-review notes (plan author)

- Spec coverage: §4 → T7; §5 → T1 (+T7/T8 use); §6.1–6.4 → T2, T5, T7, T8; §6.5 → T5, T9; §6.6 → T7, T8; §6.7–6.8 → T6, T7, T8; §6.9 → T7, T8; §7.1 → T3, T7, T8; §7.2 → T2; §7.3 → T4, T9; §8 → T7; §9 → T7 (photo), T8 (stop), T9 (silence); §10 → T9.
- Rulings made here (recorded for the ledger): one process-wide article cache (T3); prepared = pending buzz in memory (T6); came-from ignores lookups < 30 m back (T5); walking continuations use the story's position (T8).
