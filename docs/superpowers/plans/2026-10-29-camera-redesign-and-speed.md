# Camera Redesign and Speed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The photo story gives feedback within a second, shows a likely place early, streams the story text, works from a nearby-places list prepared in advance (also in the background), lets speech be switched off, records timings, and gets the design package's look.

**Architecture:** The pure parts are written test-first in `MyGuideCore`:
- ordered JSON schemas;
- the SSE stream reader and OpenAI streaming;
- the partial-JSON story parser;
- the `NearbyPlaces` list with its freshness and refresh rules and its disk format;
- the streaming photo flow with progress events;
- the timings file.

The app wires CoreLocation (foreground and the significant-change background service), the theme and fonts, and the redesigned camera and story screens.

**Tech Stack:** Swift 6 strict concurrency, iOS 26, SwiftUI, CoreLocation, URLSession bytes streaming, Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-29-camera-redesign-and-speed-design.md`. Sections 14 and 15 are binding and override earlier sections.

## Global Constraints

- Swift 6 language mode, strict concurrency, iOS 26. No new package dependencies.
- OpenAI: `store: false` on every Responses call. The key comes only from `AppServices.apiKey(keychain:)`. System instructions stay one constant (`PromptBuilder.systemInstructions`), and the prompt cache keys are unchanged.
- Honesty is unchanged:
  - an empty story is malformed;
  - an invented `matchedCandidateID` is dropped, and "certain" resting on it becomes "likely";
  - "unsure" stays visible.
- Spec numbers, copied exactly:
  - list radius 500 m for OpenStreetMap and Wikipedia, `wikiLimit` 50;
  - fresh means at most 600 s old and centre within 250 m of the photo;
  - foreground refresh at ≥ 150 m and no more than once per 60 s; walking refresh at 250 m;
  - background: skip above 8 m/s or within 600 s of the last refresh, 25 s cap under `beginBackgroundTask`;
  - article texts for the 5 nearest tier-top or tier-good candidates, stored in the list file;
  - first-story article text cut to 1 500 characters;
  - geocoder and Apple Maps wait at most 1.5 s on the fresh path;
  - streamed text shown at most every 100 ms;
  - timings file keeps the newest 500 lines, trimmed at launch;
  - "Try again" is a button, never automatic.
- Exact UI texts (Norwegian / English, chosen by the story language):
  - "Hva ser du på?" / "What are you looking at?";
  - "Finn stedet" / "Find the place";
  - "Finner stedet …" / "Finding the place …";
  - "Kanskje: {name} · {distance} {direction}" / "Maybe: {name} · {distance} {direction}";
  - "Skriver fortellingen …" / "Writing the story …";
  - "Jeg er ikke sikker på hvilket sted dette er." / "I'm not sure which place this is.";
  - "Prøv igjen med flere steder" / "Try again with more places";
  - "Lytt" / "Listen";
  - settings "Les opp automatisk" / "Read aloud automatically" and "Forbered steder i bakgrunnen" / "Prepare places in the background".
- Design package (`docs/design/designretningslinjer.txt`):
  - colours #123D38 forest green, #FFF8E9 ivory, #EC795D coral, #DDD8CD stone;
  - Playfair Display Semibold for headings, Inter Regular and Medium for UI;
  - body 17 pt, caption at least 13 pt, headings 28–34 pt, with Dynamic Type;
  - touch targets at least 44 pt;
  - no ivory or white text on coral; forest-green text on coral instead.
- Core test command: `cd Packages/MyGuideCore && swift test`.
- Unsigned build: `xcodegen generate && xcodebuild -project MyGuide.xcodeproj -scheme MyGuide -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/claude-501/-Users-birger-code-MyGuide/43e8ac03-ea1c-4b4d-b907-cc5e890c10a9/scratchpad/dd -quiet CODE_SIGNING_ALLOWED=NO build`. Never write `build/` in the repo.
- Every closure handed to CoreLocation, URLSession delegates, WatchConnectivity, HealthKit or UIApplication is nonisolated or `@Sendable`. A main-actor-isolated closure called off the main thread traps; this crashed the watch once.
- Hand computations sit above numeric assertions. Complete code, no TODOs. One commit per task, conventional message with your system's attribution trailer. Never push.

## Review Focus

1. **A stream that breaks halfway** must give the existing failure screen with no partial story kept. Test `streamEndingWithoutCompletedThrows` in Task 2, and `brokenStreamFailsWithoutSession` in Task 5.
2. **A JSON escape split across two deltas** must decode correctly, for example `\u00` then `e6` giving "æ", or `\` then `"`. Test `escapeSplitAcrossChunks` in Task 3.
3. **A list that is 601 s old or 251 m away** must never count as fresh. Test `freshnessBoundaries` in Task 4.
4. **A streamed `matchedCandidateID` that is not among the candidates sent** must never show as "certain", not even partway. Test `partialIdentificationDropsUnknownID` in Task 5.
5. **Two refresh requests at once** must give one network fetch. Test `concurrentRefreshesShareOneFetch` in Task 4.

---

### Task 1: Ordered, deterministic JSON

**Files:** modify `Packages/MyGuideCore/Sources/MyGuideCore/Net/JSONValue.swift` and `Story/PromptBuilder.swift` (`firstStorySchema`, `continuationSchema`); tests in `JSONValueTests.swift` and `PromptBuilderTests.swift`.

**Interfaces (produces):**
- `JSONValue.ordered([JSONMember])`, where `public struct JSONMember: Sendable, Equatable, Codable { public var key: String; public var value: JSONValue }`. It encodes as a JSON object with the members in the given order.
- `.object` encodes its keys sorted, so a request body is byte-identical on every launch.
- Decoding still produces `.object`.
- `firstStorySchema` uses `.ordered` for its properties *and* its `required` order: subject, confidence, matchedCandidateID, title, era, story. `story` is last.

- [ ] Write failing tests:
  - `orderedKeepsOrder`: an ordered value with "b", "a", "c" encodes as `{"b":…,"a":…,"c":…}`.
  - `objectEncodesSorted`: the dictionary `["b":1,"a":2]` encodes as `{"a":2,"b":1}`, the same string 20 times in a row.
  - `firstStorySchemaPutsStoryLast`: in the encoded `firstStorySchema`, the index of `"story"` inside `properties` is greater than the index of `"era"`, and `required` ends with "story".
- [ ] Run (fails), implement, run all core tests, commit `feat(openai): ordered, deterministic JSON schemas`.

### Task 2: SSE stream reader and OpenAI streaming

**Files:** modify `Net/HTTPClient.swift` and `OpenAI/OpenAIClient.swift`; create `Net/ServerSentEvents.swift`; extend `Tests/MyGuideCoreTests/Support/StubHTTPClient.swift`; tests in `ServerSentEventsTests.swift` and `OpenAIClientTests.swift`.

**Interfaces (produces):**
```swift
// HTTPClient gains (with a default implementation that calls send and yields the body's lines, for test doubles):
func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse)
public struct ServerSentEvent: Sendable, Equatable { public var event: String?; public var data: String }
public struct ServerSentEventParser: Sendable { public init(); public mutating func feed(line: String) -> ServerSentEvent? }
//   Standard SSE: "event:", "data:" (several data lines are joined with "\n"), a blank line ends the event, ":" lines are comments.
public enum StoryStreamEvent: Sendable, Equatable { case textDelta(String); case completed(json: Data, usage: TokenUsage) }
extension OpenAIClient {
  public func respondStreaming(model: String, reasoningEffort: String?, instructions: String, text: String, imageJPEG: Data?,
                               schemaName: String, schema: JSONValue, promptCacheKey: String?) -> AsyncThrowingStream<StoryStreamEvent, Error>
}
```
**Behaviour:**
- The request body is the same as `respond(...)`, plus `"stream": true`.
- `response.output_text.delta` yields `.textDelta`.
- `response.completed` yields `.completed` with the JSON taken from the final response by the same rule as `parseResponse` (`output_text`), plus `usage`.
- `response.failed`, `response.incomplete`, `error` and `response.refusal.delta` throw `OpenAIError.malformedResponse`, or the mapped API error when one is present.
- A stream that ends without `response.completed` throws `OpenAIError.malformedResponse`.
- A non-2xx status collects the body lines and maps them like `post` does.
- `URLSessionHTTPClient.lines` uses `URLSession.bytes(for:)` and `.lines`.

- [ ] Write failing tests:
  - SSE parser: one event; a multi-line data field; a comment ignored; an event without a blank line at the end yields nothing until the next blank line.
  - `streamYieldsDeltasThenCompleted`, using a stub with literal SSE lines for two deltas and a completed event. Check the deltas and the completed usage (`input_tokens` 120, `output_tokens` 40 becomes `TokenUsage(120, 40)`).
  - `streamEndingWithoutCompletedThrows`.
  - `failedEventThrows`.
  - `non2xxMapsLikePost`: a 401 maps to the same `OpenAIError` as `post`.
  - `bodyHasStreamTrueAndStoreFalse`: decode the captured request body.
- [ ] Run (fails), implement, run all core tests, commit `feat(openai): streaming responses over server-sent events`.

### Task 3: Partial story parser

**Files:** create `Story/PartialStoryParser.swift`; test `PartialStoryParserTests.swift`.

**Interfaces (produces):**
```swift
public struct PartialFirstStory: Sendable, Equatable {
  public var subject: String?; public var confidence: String?; public var matchedCandidateID: String?
  public var title: String?; public var era: String?; public var story: String?   // story may be incomplete
}
public struct PartialStoryParser: Sendable {
  public init()
  public mutating func append(_ chunk: String) -> PartialFirstStory   // the state after all chunks so far
}
```
**Rules:**
- A string field counts only once its closing quote has arrived. `story` is the exception: it is reported while it is still growing, with the escape sequences decoded so far.
- An escape sequence that is not yet complete is held back until the next chunk.
- `matchedCandidateID` may be `null`, which gives nil.
- Unknown keys are skipped.
- The parser never throws. Malformed input just stops updating.

- [ ] Write failing tests:
  - `fieldsAppearWhenClosed`: feeding `{"subject":"Pan` gives subject nil; adding `theon",` gives "Pantheon".
  - `storyGrows`: after `…"story":"Se opp` the story is "Se opp"; after ` i kuppelen."}` it is "Se opp i kuppelen.".
  - `escapeSplitAcrossChunks`: `"story":"\u00` then `e6r"` gives "ær"; `"a\` then `"b"` gives `a"b`; `\n` gives a newline.
  - `nullMatchedID`.
  - `wholeDocumentInOneChunk`.
  - `keyOrderIndependent`.
- [ ] Run (fails), implement, run all core tests, commit `feat(story): parse a streamed story as it arrives`.

### Task 4: Nearby places list

**Files:**
- create `Grounding/NearbyPlaces.swift` and `Grounding/NearbyList.swift`;
- modify `Walking/WalkingPlaceSource.swift`, adding `candidates(around:language:) async throws -> [Candidate]`, the merged list *without* the tier filter. `places(around:language:)` becomes that list mapped through `PlaceTiers`, with the same behaviour as today.
- tests in `NearbyPlacesTests.swift` and `WalkingPlaceSourceTests.swift` (one added test).

**Interfaces (produces):**
```swift
public struct NearbyList: Sendable, Equatable, Codable {
  public var centre: Coordinate; public var fetchedAt: Date; public var language: StoryLanguage
  public var candidates: [Candidate]; public var articleTexts: [String: String]   // wikipediaTitle → text
  public static let freshAge: TimeInterval = 600, freshDistance = 250.0
  public func isFresh(for position: Coordinate, now: Date) -> Bool   // age ≤ 600 and distance ≤ 250
  public var walkingPlaces: [WalkingPlace] { get }                   // via PlaceTiers, nil tiers dropped
}
public enum RefreshTrigger: Sendable { case foreground, walking, background(speed: Double?) }
public protocol NearbyFetching: Sendable { func candidates(around: Coordinate, language: StoryLanguage) async throws -> [Candidate] }
extension WalkingPlaceSource: NearbyFetching {}
public actor NearbyPlaces {
  public static let foregroundDistance = 150.0, foregroundInterval: TimeInterval = 60, walkingDistance = 250.0
  public static let backgroundMaxSpeed = 8.0, backgroundInterval: TimeInterval = 600, articleCount = 5
  public init(fetcher: NearbyFetching, articles: ArticleTextSource?, store: NearbyListStore?, now: @escaping @Sendable () -> Date)
  public func current(language: StoryLanguage) -> NearbyList?
  public func shouldRefresh(at position: Coordinate, trigger: RefreshTrigger, language: StoryLanguage) -> Bool
  @discardableResult public func refresh(at position: Coordinate, language: StoryLanguage) async throws -> NearbyList
  //  One fetch in flight per language; concurrent callers await it. Article texts: the 5 nearest candidates
  //  of tier .top or .good that have a wikipediaTitle, fetched concurrently, missing ones skipped.
}
public struct NearbyListStore: Sendable {   // JSON file per language in a directory
  public init(directory: URL); public func load(language: StoryLanguage) -> NearbyList?; public func save(_ list: NearbyList) throws
}
```
**Refresh rules:**
- `foreground`: no list, a different language, distance from the centre ≥ 150, or a list older than 600. In every case, not within 60 s of the last fetch attempt.
- `walking`: distance ≥ 250, or no list.
- `background`: a speed above 8 is never refreshed, nor anything within 600 s of the last refresh. Otherwise as `foreground`.
- A failed fetch keeps the old list and throws.

- [ ] Write failing tests:
  - `freshnessBoundaries`, with t0 and `.at(north:)`:
    - age 600 fresh, 601 not;
    - distance 250 fresh, 251 not (allowing for floating point: 249.9 is fresh, 250.1 is not, as in the earlier walk-log ruling).
  - `foregroundRules`:
    - no list gives true;
    - 149 m gives false, 151 m gives true;
    - within 60 s of an attempt gives false.
  - `backgroundSpeedAndInterval`: speed 8.1 gives false; 8.0 at 200 m and 601 s after the last refresh gives true; 599 s gives false.
  - `concurrentRefreshesShareOneFetch`: a stub fetcher counts calls and suspends on a continuation; two `refresh` calls give count 1.
  - `articleTextsForFiveNearestTopOrGood`: 7 eligible candidates give 5 texts, the nearest; a tier-nil candidate with a title is not fetched.
  - `storeRoundTrip`, in a temp directory.
  - `failedFetchKeepsOldList`.
  - `walkingPlacesUseTiers`.
  - `candidatesKeepUntieredPlaces` (WalkingPlaceSource): a café-only candidate is in `candidates` but not in `places`.
- [ ] Run (fails), implement, run all core tests, commit `feat(grounding): one nearby-places list, fresh rules and disk store`.

### Task 5: Streaming photo flow with progress

**Files:**
- modify `Story/PhotoStoryFlow.swift` and `Story/PromptBuilder.swift` (an article line in `photoFirstInput`);
- create `Story/PhotoStoryProgress.swift`;
- test `PhotoStoryFlowStreamingTests.swift`.

**Interfaces (produces):**
```swift
public enum PhotoStoryProgress: Sendable, Equatable {
  case finding
  case guess(RankedCandidate)                  // first ranked candidate with inView == true and distance ≤ 250, from a fresh list
  case writing
  case partial(PartialFirstStory)              // matchedCandidateID already checked against the candidates sent; confidence
                                               // "certain" downgraded to "likely" when the id was unknown
}
public struct PhotoStoryTimings: Sendable, Equatable, Codable {
  public var feedbackMs: Int; public var guessMs: Int?; public var placeSearchMs: Int?; public var articleMs: Int?
  public var firstTextMs: Int?; public var modelMs: Int; public var listFresh: Bool; public var listAgeS: Int?
  public var articleChars: Int    // 0 when none was sent
}
public struct PhotoStoryOutcome: Sendable {
  public var session: StorySession; public var usage: [UsageEntry]; public var timings: PhotoStoryTimings
  public var freshCandidates: Grounding?   // set when the list path was used and the fresh search found an in-view candidate the list lacked
}
extension PhotoStoryFlow {
  public func tellFirstStoryStreaming(photoJPEG: Data, capture: CaptureContext, language: StoryLanguage, nearby: NearbyList?,
                                      progress: @escaping @Sendable (PhotoStoryProgress) -> Void) async throws -> PhotoStoryOutcome
  public func tellFirstStoryStreaming(photoJPEG: Data, capture: CaptureContext, language: StoryLanguage, grounding: Grounding,
                                      progress: @escaping @Sendable (PhotoStoryProgress) -> Void) async throws -> PhotoStoryOutcome
  //   ^ "Try again with more places": the given grounding, no list
  public func continueStoryStreaming(_ session: StorySession, onText: @escaping @Sendable (String) -> Void)
                                      async throws -> (StorySession, [UsageEntry])
}
```
**Flow (spec 7.1, 14.2–14.4, 15.2):**
1. Report `finding` at once.
2. Start the fresh grounding (b), the geocoder and Apple Maps.
3. **Fresh list** (`nearby?.isFresh`):
   - rank `nearby.candidates` with `CandidateRanker.rank` and report `guess` when there is one;
   - the request uses the list's ranked candidates, and the address and Apple Maps places that arrive within 1.5 s;
   - the article text for the top candidate comes from `nearby.articleTexts`, else from `articles` with its own timeout, cut to 1 500 characters.
4. **Otherwise:** await (b) as today, then do the same article step.
5. Report `writing`, then stream. Each delta goes through `PartialStoryParser`, and its result is reported as `partial`, with the id check applied.
6. On `completed`, decode with `decodeFirstStory` exactly as today. Build the session and usage as today, and the timings.
7. **`freshCandidates`:** await (b) after the model finishes, but only on the fresh-list path, and only when the decoded confidence is "unsure". It is set when (b) has an in-view candidate id that the list lacked.

**Prompt:** `photoFirstInput` gains `article: (title: String, text: String)?`, rendered as an "Article:" block after the candidates. It is omitted when nil.

The existing non-streaming `tellFirstStory` stays and is used by nothing new.

- [ ] Write failing tests, using stubs: an HTTP stub that streams SSE, a stub geocoder, a stub fetch, and a fixed clock.
  - `freshListGivesGuessBeforeWriting`: the progress order is finding, guess(id), writing, partial…; `listFresh` is true.
  - `staleListWaitsForFreshSearch`: no guess; the request's candidates are the fresh ones.
  - `partialIdentificationDropsUnknownID`: the streamed id "osm:999" is not sent, so `partial` has id nil and confidence "likely", never "certain".
  - `articleCutTo1500`: a text of 4 000 characters gives exactly 1 500 characters in the request and `articleChars` 1500.
  - `brokenStreamFailsWithoutSession`.
  - `unsureWithNewInViewCandidateOffersFresh`.
  - `continuationStreamsText`.
  - `addressBudget1500ms`: a geocoder that takes 3 s on the fresh path gives a request without an address. Use a clock-controlled sleep or a short timeout parameter; hand-compute the budget in a comment.
- [ ] Run (fails), implement, run all core tests, commit `feat(story): stream the photo story with progress and a head start`.

### Task 6: Timings file

**Files:**
- create `WalkLog/JSONLinesFile.swift`, a generic appender: `init(url:)`, `append(Data line)`, `static func trim(url:keepLast:) throws`;
- create `Story/PhotoTimingsLog.swift`;
- refactor `WalkLogWriter` to use `JSONLinesFile` with the same behaviour;
- tests in `PhotoTimingsLogTests.swift`.

**Interfaces (produces):**
```swift
public struct PhotoTimingsEntry: Sendable, Equatable, Codable { public var at: Date; public var timings: PhotoStoryTimings }
public enum PhotoTimingsLog {
  public static let keep = 500
  public static func append(_ entry: PhotoTimingsEntry, to url: URL) throws
  public static func read(_ url: URL) -> [PhotoTimingsEntry]   // unreadable lines skipped
  public static func trim(_ url: URL) throws                   // keeps the newest 500 lines
  public static func median(_ values: [Int]) -> Int?          // nil for empty; even count → lower middle
}
```
- [ ] Write failing tests:
  - append and read round trip;
  - `trimKeepsNewest500` (502 lines give 500, and the first remaining is entry 3);
  - median of [] is nil, of [5] is 5, of [1, 9, 3] is 3. For [4, 1, 3, 2], sorted is [1, 2, 3, 4] and the lower middle is 2;
  - the existing walk-log tests still pass.
- [ ] Run (fails), implement, run all core tests, commit `feat(story): photo story timings file`.

### Task 7: Theme and fonts (app)

**Files:**
- create `MyGuide/Design/Theme.swift`;
- create `MyGuide/Design/Fonts/`, holding PlayfairDisplay-SemiBold.ttf, Inter-Regular.ttf, Inter-Medium.ttf and OFL.txt files for both families;
- modify `project.yml` (`UIAppFonts` on the phone target) and `MyGuide/MyGuideApp.swift` (apply tint and background);
- create `docs/design/fonts-LICENSE.md`.

**Fonts:**
- The owner approved the download. Fetch static TTFs from the official GitHub releases:
  - `rsms/inter` releases for Inter-Regular and Inter-Medium;
  - `clauseggers/Playfair-Display` (Playfair Display's upstream) static folder for PlayfairDisplay-SemiBold, or Google Fonts' static instance if upstream has none.
- Put each download in a new temporary directory and verify that it is a TrueType/OpenType file (`file`) before copying it in.
- Note the source URL and version in `fonts-LICENSE.md`.

**Theme:**
- `Theme.Colour.forest`, `.ivory`, `.coral`, `.stone`, with dark variants: background forest, text ivory.
- `Theme.Font.display` (Playfair SemiBold, 34, `relativeTo: .largeTitle`), `title` (Playfair SemiBold, 28, `relativeTo: .title`), `body` (Inter Regular, 17, `relativeTo: .body`), `bodyMedium`, `caption` (Inter Regular, 13, `relativeTo: .caption`).
- `Theme.PrimaryButtonStyle(colour: .forest | .coral)`: at least 44 pt high, corner 18. On coral the text is forest.
- `Theme.SecondaryButtonStyle` on stone.
- A font missing at run time falls back to the system font, logged once.

- [ ] Implement. Then run `xcodegen generate` and the unsigned build, and confirm the fonts are in the built app's Info.plist `UIAppFonts` and bundle.
- [ ] Commit `feat(design): theme and bundled fonts from the design package`.

### Task 8: Nearby list in the app, including background

**Files:**
- modify `MyGuide/AppServices.swift` (owns `NearbyPlaces` and `NearbyListStore` in Application Support/NearbyPlaces);
- modify `MyGuide/AppDelegate.swift`;
- create `MyGuide/Platform/BackgroundPlaces.swift`;
- modify `MyGuide/Walking/WalkingController.swift` (fetch through `NearbyPlaces` and use `walkingPlaces`);
- modify `MyGuide/Capture/LocationProvider.swift` (or the camera screen) to feed foreground refreshes;
- modify `MyGuide/Settings/SettingsView.swift` (the background setting);
- modify `project.yml` (Always purpose string, rewritten to: "In walking mode MyGuide follows your position with the phone locked, so it can tell you about places you pass, and it prepares the places around you in the background so the camera answers faster.").

**Interfaces (produces):** `AppServices.nearby: NearbyPlaces`; `BackgroundPlaces.shared.start()` / `.stop()`; the `UserDefaults` key `prepareBackgroundPlaces` (Bool, default true).

**Behaviour:**
- **Walking mode:**
  - replaces its own `source.places` fetch with `nearby.refresh` and `walkingPlaces`, keeping `PlaceFeed`'s retry delay;
  - writes the same `fetchStarted`, `fetched` and `fetchFailed` walk-log lines;
  - the trigger is `.walking`.
- **Camera open:** each fix from `LocationProvider` with accuracy ≤ 50 m checks `shouldRefresh(.foreground)` and refreshes in a task.
- **`BackgroundPlaces`:**
  - its own `CLLocationManager` with `startMonitoringSignificantLocationChanges`, started when the setting is on and authorisation is Always;
  - on each update (delegate nonisolated, hopping to the main actor) it calls `requestLocation()` once for an accurate fix;
  - with that fix: if `shouldRefresh(.background(speed:))`, it refreshes under `beginBackgroundTask` (expiration handler built nonisolated and `@Sendable`), capped at 25 s, then ends the task exactly once;
  - failures go to `os.Logger` (category `nearby`).
- **AppDelegate:** at `didFinishLaunching` (including a relaunch with `.location` in the options), calls `BackgroundPlaces.shared.start()` when the setting is on and authorisation is Always. This does not depend on any scene.
- **Settings:** a toggle "Forbered steder i bakgrunnen" / "Prepare places in the background". Turning it on when authorisation is not Always asks for Always (`requestAlwaysAuthorization`; first When-in-use if undetermined).

- [ ] Implement. Run the unsigned build and core tests.
- [ ] Self-check:
  - walking mode still logs fetches;
  - every CoreLocation and UIApplication closure is nonisolated or `@Sendable`;
  - nothing in the background path touches SwiftUI state.
- [ ] Commit `feat(nearby): shared nearby list, refreshed in the foreground, in walking mode and in the background`.

### Task 9: Camera screen, story screen and speech setting (app)

**Files:**
- modify `MyGuide/Capture/CaptureScreen.swift`;
- modify `MyGuide/Story/StoryViewModel.swift` and `StoryView.swift`;
- modify `MyGuide/Settings/SettingsView.swift`, adding the "Les opp automatisk" toggle and a "Story timings" link;
- create `MyGuide/Settings/StoryTimingsView.swift`;
- modify `MyGuide/AppServices.swift` (`makeFlow` passes the nearby list; a timings file URL; a trim at launch).

**Behaviour:**
- **Camera screen:**
  - the design overlay: heading "Hva ser du på?" / "What are you looking at?" in `Theme.Font.display` over the preview, with a soft dark gradient for legibility;
  - focus corners;
  - the shutter;
  - the library picker;
  - a coral primary button "Finn stedet" / "Find the place", with forest text, that takes the photo;
  - the HUD shrunk to one caption line;
  - pinch to zoom kept.
- **Story screen states:** `finding`, `guess(card)`, `writing(card?, partial text)`, `showing`, `failed`.
  - The card shows the name, distance and direction (with `GuideText`'s direction words), and the prefix "Kanskje:" / "Maybe:" until the decoded identification arrives.
  - "unsure" shows the not-sure sentence.
  - The streamed text updates at most every 100 ms.
  - When `freshCandidates` is non-nil and the confidence is "unsure", a "Prøv igjen med flere steder" / "Try again with more places" button reruns with them.
- **Speech:**
  - `@AppStorage("readAloudAutomatically")`, default true. When on, level speech starts when that level's text is complete.
  - When off, nothing is requested, and a "Lytt" / "Listen" button plays it. This applies to every level.
  - The background task ends at text completion when speech is off.
- **Timings:**
  - every finished first story appends a `PhotoTimingsEntry`;
  - `StoryTimingsView` shows the median of each field over the stored entries, and the last 20 with date and `listFresh`;
  - no story text appears.
- **Theme:** the story screen's typography and colours come from `Theme`.

- [ ] Implement. Run the unsigned build and core tests.
- [ ] Self-check: every spec text from the Global Constraints appears exactly, and the old "Looking around…" text is gone.
- [ ] Commit `feat(camera): redesigned camera and story screens with streaming and quick feedback`.
