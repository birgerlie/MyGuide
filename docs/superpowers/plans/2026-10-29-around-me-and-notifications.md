# «Rundt deg», place selection and designed notifications — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The home screen becomes a muted map of notify-worthy places around the owner. A place is selected by
direction, with a design-package place card. Walking notifications, the expanded notification, the Live Activity
and the walk story screen follow the design.

**Architecture:**
- Pure logic lives in `MyGuideCore` with Swift Testing tests: selection state machine, heading maths, relative
  direction words, notification texts, factual line, failure categories, Wikipedia page images and their cache, and
  walk-story sources.
- The app adds a Core Motion heading provider, an `AroundModel` that feeds the selector, the map screen,
  notification content and attachments, and a "tell this place" entry in `WalkingStories`.
- A new Notification Content Extension and the existing widget extension draw with `Theme` and the bundled fonts.
  They read only a payload from `Shared/` and do not link `MyGuideCore`.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, MapKit for SwiftUI, Core Motion, UserNotifications(+UI),
ActivityKit/WidgetKit, Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-29-around-me-and-notifications-design.md`. Section 12 is binding and
overrides earlier sections where they differ. Rules 6.2.5 and 6.2.7 are already rewritten in place.

**Branch:** create `around-me` from `camera-redesign` (camera-redesign is unmerged and this builds on its `Theme`,
`StoryText`, `StorySources` and `StoryView`).

## Global Constraints

- iOS 26.0 deployment target; Swift 6.0; XcodeGen (`xcodegen generate` after any `project.yml` change).
- Every new screen or notification text comes in both story languages, `StoryLanguage.norwegian` ("nb") and
  `.english`, chosen by the story language. Exact Norwegian copy is in each task.
- Design: ivory #FFF8E9 background, forest #123D38 text and ordinary markers, coral #EC795D for the selected place
  and the main button, with **dark (forest) text on coral**, stone #DDD8CD dividers. Playfair Display SemiBold
  (`Theme.FontName.display`) for place headings; Inter (`Theme.FontName.regular` / `.medium`) for the interface
  and body. 8 pt rhythm, 16–24 pt margins, 44 pt touch targets, never colour alone for status. Light and dark mode
  through `Theme.Colour` tokens.
- No API key and no `MyGuideCore` in the widget or notification extensions.
- No new third-party services. Images come from Wikimedia (`*.wikipedia.org` API).
- Compass and motion updates and the map run only while the map screen is visible.
- Automatic selection never starts audio. No story starts before «Lytt».
- A notification is never delayed more than **1.5 s** by its picture.
- Never invent facts: the factual line comes only from the place's data (spec 7.2, 12.7).
- Closures handed to CoreMotion, CoreLocation, UserNotifications or MapKit callbacks are `@Sendable` or
  nonisolated. A MainActor-isolated closure called off-thread traps; this crashed the watch before.
- Core tests: `cd Packages/MyGuideCore && swift test` must stay green. The last count was 1032 tests.
- App build (each app task ends with it):
  `xcodebuild -project MyGuide.xcodeproj -scheme MyGuide -destination 'generic/platform=iOS' -derivedDataPath /tmp/mg-dd -quiet build`
  expected: no `error:` lines.

## Review Focus

1. **Heading near north with noise** (355°–5° jitter): no repeated switches, and the smoothed heading never jumps
   through 180°. Pinned in Task 1 (`noFlickerUnderNoiseAroundNorth`) and Task 2 (`smoothingAcrossNorth`).
2. **The list refreshes while a place is selected** (the place disappears from the new list): the selection is
   dropped without a crash. A place with the same id in the new list keeps the selection. Pinned in Task 1
   (`selectedPlaceVanishesFromList`).
3. **Unreliable inputs mid-walk** (accuracy jumps to 80 m): no direction words, selection state "uncertain
   position", and back to normal when accuracy recovers. Pinned in Task 1 (`positionAccuracyGate`).
4. **A summary in another language, or a summary whose first sentence is over 140 characters**: the kind label is
   used, or the sentence is cut at a word with "…". Never mid-word, never a foreign-language line. Pinned in Task 3.
5. **The picture fetch hangs at notification time**: the notification is posted without a picture after 1.5 s.
   Pinned in Task 4 (`fetchWithinCapGivesUpAfterCap`). Task 8 calls that API.

---

### Task 1: Place selection state machine (core)

**Files:**
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Around/PlaceSelector.swift`
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/PlaceSelectorTests.swift`

**Interfaces:**
- Consumes: `WalkingPlace`, `Candidate`, `Coordinate`, `GeoMath.distance(_:_:)`, `GeoMath.bearing(from:to:)`.
- Produces:
  ```swift
  public struct PlaceSelectionConfig: Sendable, Equatable {
      public var selectHalfAngle = 30.0      // degrees
      public var keepHalfAngle = 40.0
      public var dwell: TimeInterval = 1.5
      public var equalRatio = 0.15           // challenger must be nearer by > max(ratio·d, metres)
      public var equalMetres = 10.0
      public var maxHeadingAccuracy = 25.0
      public var maxPositionAccuracy = 50.0
      public var directionDistanceFactor = 2.0   // direction stated only when distance > factor·accuracy
      public var explicitHold: TimeInterval = 20
      public var explicitTurn = 60.0
      public var clusterSpacing = 15.0       // two nearest within this of each other …
      public var clusterReach = 40.0         // … and both within this of the owner → suggest a photo
      public init() {}
  }
  public struct PlaceVector: Sendable, Equatable {
      public var place: WalkingPlace
      public var distance: Double
      public var bearing: Double
      public init(place: WalkingPlace, distance: Double, bearing: Double)
      public static func from(position: Coordinate, places: [WalkingPlace]) -> [PlaceVector]
  }
  public struct SelectionInput: Sendable, Equatable {
      public var vectors: [PlaceVector]
      public var positionAccuracy: Double
      public var heading: Double?            // smoothed, degrees; nil = none
      public var headingAccuracy: Double?
      public var playingPlaceID: String?
      public var now: Date
  }
  public struct SelectedPlace: Sendable, Equatable {
      public var vector: PlaceVector
      /// Offset bearing − heading in (−180, 180], only when a direction may be stated (reliable heading and
      /// distance > factor · position accuracy); nil otherwise.
      public var relative: Double?
      public var suggestPhoto: Bool
  }
  public enum SelectionState: Sendable, Equatable {
      case noPlaces
      case uncertainPosition
      case selected(SelectedPlace)
  }
  public struct PlaceSelector: Sendable {
      public init(config: PlaceSelectionConfig = .init())
      public private(set) var state: SelectionState
      public mutating func update(_ input: SelectionInput) -> SelectionState
      public mutating func choose(placeID: String, _ input: SelectionInput) -> SelectionState
      public static func offset(heading: Double, bearing: Double) -> Double   // (−180, 180]
  }
  ```

The rules (spec 6.2 with 12.3, 6.3, 6.4):
- `positionAccuracy > maxPositionAccuracy` → `.uncertainPosition`. No vectors → `.noPlaces`.
- The heading is reliable when it is non-nil, its accuracy is non-nil and ≤ `maxHeadingAccuracy`, and it is finite.
- **Winner:**
  - with a reliable heading, the nearest vector with |offset| ≤ `selectHalfAngle`;
  - if none, or with no reliable heading, the nearest vector overall (the fallback).
- **Current place keeps its claim:**
  - while it is in the new vectors, and the heading is reliable with |offset| ≤ `keepHalfAngle`;
  - or while it is the fallback winner itself.
- **A challenger replaces the current place** when it is the winner and either:
  - the current place lost its claim; or
  - the challenger is in the angle and the current place is not; or
  - both are in the same mode and challenger.distance < current.distance − max(`equalRatio`·current.distance,
    `equalMetres`).

  The challenger must also have been that winner continuously for `dwell` seconds (tracked by its id and its first
  instant).
- **Immediate cases:**
  - the first selection, from `.noPlaces` or `.uncertainPosition`, takes effect at once;
  - a current place that has vanished from the list is replaced at once by the winner.
- **`playingPlaceID` freezes** the selection on that place while it is in the vectors. Its vector and `relative`
  still update on every call.
- **`choose`** selects at once and holds against automatic changes until `explicitHold` seconds have passed, or
  until |offset(heading now, heading at the tap)| > `explicitTurn`.
- **`relative`** is set only when the heading is reliable and distance > `directionDistanceFactor` ·
  positionAccuracy.
- **`suggestPhoto`** is set when the two nearest vectors are within `clusterSpacing` of each other and both
  distances are ≤ `clusterReach`. The spacing is computed as |d1 − d2| when their bearings differ by ≤ 20°, else by
  the law of cosines.

- [ ] **Step 1: Write the failing tests.** Helper: `v(_ id: String, d: Double, b: Double) -> PlaceVector` with a
  `.top` place named `id`. `input(vectors, heading: Double?, hAcc: Double? = 10, pAcc: Double = 10, playing: String? = nil, t: Double)`
  where `now = Date(timeIntervalSince1970: t)`.

```swift
// offset(heading:bearing:) = bearing − heading wrapped into (−180, 180].
// 359 → 1: 1 − 359 = −358 → +360 = 2.   10 → 350: 350 − 10 = 340 → −360 = −20.   0 → 180: 180 (not −180).
@Test func offsetWrapsAroundNorth() {
    #expect(PlaceSelector.offset(heading: 359, bearing: 1) == 2)
    #expect(PlaceSelector.offset(heading: 10, bearing: 350) == -20)
    #expect(PlaceSelector.offset(heading: 0, bearing: 180) == 180)
}
@Test func nearestInsideTheAngleWins() {          // criterion 1: four places around the owner
    var s = PlaceSelector()
    let vs = [v("front", d: 80, b: 10), v("right", d: 30, b: 90), v("back", d: 20, b: 180), v("left", d: 40, b: 270)]
    #expect(s.update(input(vs, heading: 0, t: 0)).placeID == "front")   // only "front" is within ±30°
}
@Test func nearerPlaceBehindDoesNotWin() { … }    // criterion 2: back at 20 m never selected while front at 80 m is in angle
@Test func turnSwitchesAfterDwellOnly() {         // criterion 3: heading 0 → 90 at t=10; still "front" at t=11.4, "right" at t=11.5
}
@Test func noFlickerUnderNoiseAroundNorth() {     // criterion 4 + review focus 1: places at b 2 (60 m) and b 358 (62 m);
    // heading alternates 355, 5, 357, 3 … every 0.2 s for 10 s → exactly one selection, never a switch
}
@Test func northIsContinuous() { … }              // criterion 5: heading 359 selects a place at bearing 1 (offset 2)
@Test func playingPlaceIsFrozen() { … }           // criterion 6: playing "front", turn to "right" for 5 s → still "front", relative updates to −90 (front at b 0, heading 90: 0 − 90 = −90)
@Test func noDirectionWithoutReliableHeading() { … }   // criterion 7: hAcc 30 → relative nil; heading nil → relative nil, nearest overall selected
@Test func positionAccuracyGate() { … }           // pAcc 80 → .uncertainPosition; pAcc 10 again → selected at once
@Test func directionNeedsDistanceAboveTwiceAccuracy() {
    // pAcc 20: place at 40 m → 40 > 2·20 = 40 is false → relative nil; at 41 m → relative set.
}
@Test func equalDistanceKeepsCurrent() {
    // current 100 m in angle; challenger in angle at 86 m: threshold max(0.15·100 = 15, 10) = 15 → needs < 85 → kept.
    // challenger at 84 m for 1.5 s → switches.   current 40 m: max(6, 10) = 10 → challenger at 31 kept, at 29 switches.
}
@Test func fallbackWhenNothingInAngle() { … }      // heading 0, places only at b 120 (50 m) and b 200 (30 m) → selects the 30 m one, relative = 200 − 0 = 200 → −160
@Test func inAngleBeatsFallbackAfterDwell() { … }  // fallback selected; a place enters ±30° → switches only after 1.5 s
@Test func leavingKeepAngleKeepsCardUntilChallengerDwells() { … }  // current leaves ±40° at t; still selected (relative updated) until t+1.5
@Test func explicitChoiceHoldsTwentySecondsOrSixtyDegrees() { … }  // choose "back"; t+19 still "back"; t+20 → automatic again; separate case: turn 61° at t+5 → automatic again
@Test func selectedPlaceVanishesFromList() { … }   // review focus 2: next update lacks the id → winner at once; same id with a new distance → kept
@Test func photoSuggestedForTightCluster() {
    // d 30 and 38, bearings 10 and 15 (≤ 20° apart → spacing |30 − 38| = 8 ≤ 15), both ≤ 40 → true.
    // d 30 and 38 at bearings 0 and 90: √(30² + 38² − 2·30·38·cos 90°) = √(900 + 1444) = 48.4 > 15 → false.
}
@Test func noPlacesState() { #expect(PlaceSelector().state == .noPlaces) }
```

  Give `SelectionState` a test-only extension `placeID: String?` inside the test file.

- [ ] **Step 2:** `cd Packages/MyGuideCore && swift test --filter PlaceSelectorTests`. Expected: FAIL, because
  `PlaceSelector` is not defined.
- [ ] **Step 3: Implement** the types above in `Around/PlaceSelector.swift`. Pending-challenger tracking is
  `(id: String, since: Date)?`, reset whenever the winner id changes.
- [ ] **Step 4:** run the filter again. Expected: PASS. Then the full `swift test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(around): place selection by direction with dwell, hysteresis and reliability gates`.

### Task 2: Heading maths and relative direction words (core)

**Files:**
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Around/PhoneHeading.swift`
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Around/RelativeDirection.swift`
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/BuzzText.swift`. Add a localized detail and leave the
  English `detail` unchanged for the walk log.
- Test: `PhoneHeadingTests.swift`, `RelativeDirectionTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct Vector3: Sendable, Equatable { public var north, east, up: Double; public init(north:east:up:) }
  public enum PhoneHeading {
      /// Azimuth (0..<360, clockwise from true north) of the horizontal projection of top + back; nil when that
      /// projection is shorter than 0.25 (spec 6.4).
      public static func azimuth(top: Vector3, back: Vector3) -> Double?
  }
  public struct HeadingSmoother: Sendable {
      public static let timeConstant: TimeInterval = 0.5
      public init()
      public mutating func add(_ heading: Double, at: Date) -> Double   // circular EMA, α = 1 − e^(−Δt/τ); first sample passes through
  }
  public enum RelativeDirection: Sendable, Equatable {
      case ahead, aheadLeft, aheadRight, left, right, behindLeft, behindRight, behind
      /// Bands of GuideText.side: |r| ≤ 30 ahead; ≤ 60 ahead-left/right; ≤ 120 left/right; ≤ 150 behind-left/right; else behind.
      public init(offset: Double)
      public func words(_ language: StoryLanguage) -> String
  }
  public enum AroundText {
      /// "50 m · foran deg"; without `relative`: "i nærheten · 50 m" / "nearby · 50 m".
      public static func whereLine(distance: Double, relative: Double?, language: StoryLanguage) -> String
  }
  extension BuzzText {
      /// "50 m foran deg" / "50 m til høyre" / "50 m til venstre" / "90 m bak deg" / "50 m unna"; English as `detail`.
      public static func localizedDetail(distance: Double, bearing: Double, course: Double?, language: StoryLanguage) -> String
  }
  ```
- Norwegian words: `foran deg`, `foran til venstre`, `foran til høyre`, `til venstre for deg`, `til høyre for deg`,
  `bak deg til venstre`, `bak deg til høyre`, `bak deg`.
- English words: `ahead`, `ahead to the left`, `ahead to the right`, `to your left`, `to your right`,
  `behind you to the left`, `behind you to the right`, `behind you`.

- [ ] **Step 1: Write the failing tests:**

```swift
// Flat, top edge east, back down: top (0,1,0) + back (0,0,−1) → horizontal (n 0, e 1) → atan2(1, 0) = 90°.
// Upright facing north: top (0,0,1) + back (1,0,0) → (1, 0) → 0°.
// 45° tilt facing south: top (−0.707,0,0.707) + back (−0.707,0,−0.707) → (−1.414, 0) → 180°.
// Degenerate: top (0,0,1) + back (0,0,−1) → (0,0), length 0 < 0.25 → nil.
@Test func azimuthFlatUprightTiltedDegenerate() { … }
// τ = 0.5, Δt = 0.5 → α = 1 − e^(−1) = 0.6321. 350 then 10 (+20 across north) → 350 + 0.6321·20 = 362.64 → 2.64.
// Δt = 0.25 → α = 1 − e^(−0.5) = 0.3935: 0 then 90 → 35.41.
@Test func smoothingAcrossNorth() { … }   // also: never produces a value near 180 for inputs 355/5 alternating
@Test func bands() { … }                   // 30 → ahead, 30.1 → aheadRight, −60 → aheadLeft, 120 → right, −150 → behindLeft, 151 → behind, 180 → behind
@Test func wordsBothLanguages() { … }
@Test func whereLineWithAndWithoutDirection() {
    // distance 47 → BuzzText.roundedDistance 50; relative 10 → "50 m · foran deg"; nil → "i nærheten · 50 m".
}
@Test func localizedDetailMatchesEnglishBands() { … }  // the four bands and "unna" without course, nb and en (en == detail)
```

- [ ] **Step 2:** run `--filter "PhoneHeadingTests|RelativeDirectionTests"`. Expected: FAIL.
- [ ] **Step 3: Implement.** Smoothing works on unit vectors (sum of cos/sin, weighted by α), not raw degrees.
- [ ] **Step 4:** the filter passes, then the full `swift test`.
- [ ] **Step 5: Commit** `feat(around): phone heading from motion vectors, smoothing, relative direction words`.

### Task 3: Notification texts, factual line, failure categories (core)

**Files:**
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Notifications/NotificationText.swift`
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Notifications/FactLine.swift`
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Notifications/FailureCategory.swift`
- Test: `NotificationTextTests.swift`, `FactLineTests.swift`, `FailureCategoryTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum FactLine {
      public static let maxLength = 140
      /// Spec 7.2 + 12.7 + 12.8: first sentence of the summary when the article's language is the story language;
      /// else kind label (+ " · fra 1697" / " · fredet"); else nil.
      public static func text(for candidate: Candidate, language: StoryLanguage) -> String?
      /// "no:Foo" → "no"; "wiki:en/12" → "en"; nil otherwise.
      public static func articleLanguage(_ candidate: Candidate) -> String?
      public static func kindLabel(tags: [String: String], language: StoryLanguage) -> String?
  }
  public enum FailureCategory: Sendable, Equatable {
      case noNetwork, aiFailed, noKey, timedOut, other
      public init(_ error: Error)
      public func text(_ language: StoryLanguage) -> String
  }
  public enum NotificationText {
      public static func listen(_ l: StoryLanguage) -> String        // "Lytt" / "Listen"
      public static func skip(_ l: StoryLanguage) -> String          // "Hopp over" / "Skip"
      public static func more(_ l: StoryLanguage) -> String          // "Mer" / "More"
      public static func moreBody(_ l: StoryLanguage) -> String      // "Trykk Mer for neste del." / "Tap More for the next part."
      public static func failedTitle(_ l: StoryLanguage) -> String   // "Fikk ikke hentet fortellingen" / "Couldn't get the story"
      public static func nearbyLabel(_ l: StoryLanguage) -> String   // "Sted i nærheten" / "Nearby place"
      public static func nextPartLabel(_ l: StoryLanguage) -> String // "Neste del" / "Next part"
      public static func stoppedLabel(_ l: StoryLanguage) -> String  // "Her du stoppet" / "Where you stopped"
      public static func photoCredit(author: String?, licence: String?, _ l: StoryLanguage) -> String?
          // "Foto: A, CC BY-SA 4.0, Wikimedia Commons" / "Photo: …"; missing parts left out; nil when both are nil
  }
  ```
- First sentence: the text up to and including the first `.`, `!` or `?` followed by whitespace and an uppercase
  letter or a digit, or by the end of the text. Abbreviations such as "St. Olav" are accepted as a known limit.
- A sentence longer than 140 characters is cut at the last space at or before character 139, with "…" appended,
  so the result is at most 140 characters.
- Kind-label table: the first matching row wins; checked against `tags`; nb / en.

  | Tag | Norwegian | English |
  |---|---|---|
  | historic=castle, building=castle | Slott | Castle |
  | historic=palace, building=palace | Palass | Palace |
  | historic=fort | Festning | Fortress |
  | historic=city_gate | Byport | City gate |
  | historic=citywalls | Bymur | City wall |
  | historic=ruins | Ruin | Ruins |
  | historic=archaeological_site | Arkeologisk sted | Archaeological site |
  | historic=battlefield | Slagmark | Battlefield |
  | historic=monument | Monument | Monument |
  | historic=memorial + memorial=statue | Statue | Statue |
  | historic=memorial | Minnesmerke | Memorial |
  | historic=tower | Tårn | Tower |
  | building=cathedral | Domkirke | Cathedral |
  | historic=church, building=church | Kirke | Church |
  | amenity=place_of_worship | Gudshus | Place of worship |
  | historic=monastery | Kloster | Monastery |
  | historic=manor | Herregård | Manor |
  | tourism=museum | Museum | Museum |
  | tourism=gallery | Galleri | Gallery |
  | tourism=attraction | Severdighet | Attraction |
  | historic=building | Historisk bygning | Historic building |

- Suffix:
  - ` · fra YYYY` / ` · from YYYY` when `start_date` starts with four digits;
  - else ` · fredet` / ` · listed` when `heritage` is present.
- Failure categories:
  - `OpenAIError.network`, `URLError.notConnectedToInternet`, `.networkConnectionLost` and
    `.cannotFindHost` → `.noNetwork`;
  - `URLError.timedOut` → `.timedOut`;
  - `OpenAIError.missingAPIKey` and `.invalidAPIKey` → `.noKey`;
  - any other `OpenAIError` → `.aiFailed`;
  - else `.other`.
- Failure texts (nb / en):

  | Category | Norwegian | English |
  |---|---|---|
  | noNetwork | Ingen nettilgang. | No connection. |
  | aiFailed | AI-tjenesten feilet. Prøv igjen. | The AI service failed. Try again. |
  | noKey | Mangler API-nøkkel. Legg den inn i Innstillinger. | No API key. Add it in Settings. |
  | timedOut | Det tok for lang tid. Prøv igjen. | It took too long. Try again. |
  | other | Noe gikk galt. Prøv igjen. | Something went wrong. Try again. |

- [ ] **Step 1: Write the failing tests:**
  - `firstSentenceOfSameLanguageSummary`: "Pantheon er et romersk tempel. Det ble bygget …" with title
    "no:Pantheon" and language nb gives "Pantheon er et romersk tempel."
  - `summaryInOtherLanguageFallsToKindLabel`: an "en:" title, language nb, tags historic=church gives "Kirke".
  - `longSentenceCutAtWord`: a 200-character sentence gives a result of length ≤ 140 that ends with "…" after a
    whole word.
  - `kindLabelWithYearAndHeritage`: start_date "1697-05" gives "Kirke · fra 1697"; start_date "c. 1700" with
    heritage "2" gives "Kirke · fredet".
  - `nothingKnownGivesNil`.
  - `statueBeatsMemorial`.
  - `articleLanguageFromTitleAndID`.
  - `failureMapping` (each row above).
  - `failureTextsBothLanguages`.
  - `creditVariants`.
- [ ] **Step 2:** run `--filter "FactLineTests|FailureCategoryTests|NotificationTextTests"`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** PASS, then the full suite.
- [ ] **Step 5: Commit** `feat(notifications): factual line, kind labels, failure categories, texts in both languages`.

### Task 4: Wikipedia page images and their cache (core)

**Files:**
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Grounding/WikipediaClient.swift`. Add the page-image request.
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Grounding/PlaceImages.swift`
- Test: `PlaceImagesTests.swift`. Use the existing HTTP stub pattern from `WikipediaClientTests`.

**Interfaces:**
- Produces:
  ```swift
  public struct PlaceImageInfo: Sendable, Equatable, Codable {
      public var thumbnailURL: URL; public var author: String?; public var licence: String?; public var filePage: URL?
  }
  extension WikipediaClient {
      /// Two requests on the article's own wiki: pageimages (piprop=thumbnail|name, pithumbsize=600, redirects=1),
      /// then imageinfo (iiprop=extmetadata, iiextmetadatafilter=Artist|LicenseShortName) for "File:<name>".
      /// nil when the article has no page image. Artist HTML is reduced to plain text (tags stripped, entities decoded).
      public func pageImage(wikipediaTitle: String) async throws -> PlaceImageInfo?
      public func imageData(_ url: URL) async throws -> Data
  }
  public struct StoredPlaceImage: Sendable, Equatable { public var fileURL: URL; public var info: PlaceImageInfo }
  public actor PlaceImages {
      public static let notificationCap: Duration = .milliseconds(1500)
      public init(directory: URL, client: WikipediaClient, now: @escaping @Sendable () -> Date = Date.init)
      public func cached(wikipediaTitle: String) -> StoredPlaceImage?
      /// Fetch once (in-flight requests merged per title); a "no image" answer is remembered for 7 days.
      public func image(wikipediaTitle: String) async -> StoredPlaceImage?
      /// `image` raced against `cap`; nil past the cap (the fetch continues and fills the cache).
      public func image(wikipediaTitle: String, within cap: Duration) async -> StoredPlaceImage?
      public func prefetch(_ titles: [String]) async
      /// The title to use for a candidate: its wikipediaTitle, or "code:" + name for a "wiki:code/…" id; nil otherwise.
      public static func title(for candidate: Candidate) -> String?
  }
  ```
- Storage: `<directory>/<SHA-256 hex of title>.jpg` plus `.json` holding the `PlaceImageInfo` and the time.
- The language code is validated as in `articleText(wikipediaTitle:)`.
- The `User-Agent` is `OverpassClient.userAgent`; each request has a 10 s timeout.

- [ ] **Step 1: Write the failing tests:**
  - `requestURLsAreOnTheArticlesWiki`;
  - `parsesThumbnailAndCredit`: Artist `<a href="…">Jane Doe</a>` gives "Jane Doe", and
    `LicenseShortName` "CC BY-SA 4.0";
  - `noPageImageGivesNil`;
  - `cacheHitAvoidsNetwork`;
  - `negativeAnswerRememberedSevenDays`: with a stub clock, a call at day 6.9 makes no request and a call at
    day 7.1 makes one;
  - `inFlightMerged`: two concurrent calls make one request;
  - `fetchWithinCapGivesUpAfterCap`: a stub delaying 3 s gives nil at the cap, and `cached` later holds the
    image;
  - `malformedTitleGivesNil`;
  - `titleForCandidate`.
- [ ] **Step 2:** run `--filter PlaceImagesTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** The cap is a task group where the first result wins; the fetch itself runs as an
  unstructured `Task` owned by the actor, so it can finish after the cap.
- [ ] **Step 4:** PASS, then the full suite.
- [ ] **Step 5: Commit** `feat(images): Wikipedia page images with credit, disk cache, merged and capped fetches`.

### Task 5: Chosen-place stories and walk-story sources (core)

**Files:**
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/WalkStory.swift`. Add `Kind.chosen`; `canSkip`
  stays buzz-only.
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/BuzzEngine.swift`. Add `Buzz.init(chosen:position:)`.
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Memory/DiaryMemory.swift`. A `.chosen` walk story counts as
  heard when saved and maps to the buzz entry kind.
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Story/StorySources.swift`. Add sources for a walk story and an
  image-credit kind.
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/WalkingStoryFlow.swift`. The kind of the returned story
  follows a new parameter.
- Test: extend `WalkStoryTests`, `DiaryMemoryTests`, `StorySourcesTests`, `WalkingStoryFlowTests`.

**Interfaces:**
- Produces:
  ```swift
  extension Buzz { public init(chosen place: WalkingPlace, position: Coordinate) }
      // id new UUID; distance/bearing from GeoMath; title = name; detail = BuzzText.detail(…, course: nil); usedOverride false
  // WalkingStoryFlow.buzzStory gains `kind: WalkStory.Kind = .buzz` as last parameter; the story carries it.
  extension StorySource.Kind { case imageCredit }   // add to the enum: detail = credit text, url = file page
  extension StorySources {
      public static func list(for story: WalkStory, image: PlaceImageInfo?, language: StoryLanguage) -> [StorySource]
      // place sources as for a photo story's matched candidate (story.place), then Apple Maps when applePlaces non-empty
      // or address non-nil, then the image credit when `image` is given. A stop story: Apple Maps only (+ none).
  }
  ```
- `DiaryMemory`:
  - a `.chosen` walk story is listed like a heard buzz;
  - its entry's `placeName` is the place name;
  - it does not need a `heardBuzzes` record.

- [ ] **Step 1: Write the failing tests:**
  - `chosenBuzzHasNoCourseDetail`: a place 100 m due north gives detail "100 m away" and bearing 0, with the
    position and place built from `GeoMath`;
  - `flowCarriesKind`;
  - `chosenStoryListedInDiaryWithoutHeardRecord`;
  - `chosenCannotSkip`;
  - `walkStorySources`: a buzz story with an OSM place and an image gives [openStreetMap, imageCredit]; with an
    address it gives [openStreetMap, appleMaps, imageCredit]; a stop story gives [];
  - `storedKindRoundTrips`: `.chosen` survives save and load.
- [ ] **Step 2:** FAIL. **Step 3:** implement. **Step 4:** PASS, then the full suite.
- [ ] **Step 5: Commit** `feat(walking): stories about a place chosen on the map; walk-story sources`.

### Task 6: «Tell this place» and one audio owner (app)

**Files:**
- Modify: `MyGuide/Walking/WalkingStories.swift`
- Modify: `MyGuide/Walking/WalkingController.swift`

**Interfaces:**
- Consumes: Task 5 `Buzz(chosen:position:)`, `buzzStory(…, kind:)`.
- Produces (app):
  ```swift
  // WalkingStories
  /// Spec 12.1: the prepared story for this place if one exists (walk story with place.id == placeID), else a new
  /// `.chosen` story through the buzz pipeline; then plays level 1. Works with walking mode off. Stops any other audio.
  func tellPlace(_ place: WalkingPlace, position: Coordinate, language: StoryLanguage,
                 context: @escaping @MainActor @Sendable () async -> WalkContext)
  /// The place whose story is playing or loading, for the map card (spec 12.2).
  var playingPlaceID: String? { get }
  func storyID(forPlace placeID: String) -> UUID?
  // WalkingController
  /// Set on every delivered buzz; the map selects this place explicitly when the app is active (spec 12.2).
  private(set) var lastBuzz: (placeID: String, at: Date)?   // @Observable property
  /// Called by WalkingStories when a .chosen story starts playing: excludes the place from buzzing this run and
  /// records it retired in memory (spec 12.1, "marks the place heard").
  func noteChosenHeard(_ place: Candidate)
  ```
- `tellPlace` with walking mode off builds the `WalkContext` from the address lookup the controller already uses.
  When the controller is not running, it passes
  `{ WalkContext(address: nil, bearing: nil, street: nil, cameFrom: nil) }`.
- No `BuzzBudget` token is used and no notification is posted.

- [ ] **Step 1: Implement.**
  - `tellPlace` reuses `prepare`'s save/store/speech path with `kind: .chosen` and no `feed(.buzzSent)` when the
    playback machine needs a buzz. Use a dedicated `.chosenStarted(id)` event in `WalkingPlayback` if the machine
    rejects unknown ids. Read `Core/Walking/WalkingPlayback.swift` first and add a test there for the new event.
  - Once the story is ready, call `play(id, level: 1)`.
  - Single audio: `tellPlace` and `listen` call `stopAudio()` before starting.
- [ ] **Step 2:** `swift test` in core (for any playback change) and the app build. Expected: green and no errors.
- [ ] **Step 3: Commit** `feat(walking): tell a place chosen on the map, one audio owner, last buzz for the map`.

### Task 7: Phone heading provider and the around model (app)

**Files:**
- Create: `MyGuide/Around/PhoneHeadingProvider.swift`
- Create: `MyGuide/Around/AroundModel.swift`

**Interfaces:**
- Consumes:
  - Task 1 `PlaceSelector`, `PlaceVector.from`, `SelectionInput`, `SelectionState`;
  - Task 2 `PhoneHeading.azimuth`, `HeadingSmoother`;
  - `NearbyPlaces` (`current`, `shouldRefresh(at:trigger: .foreground, …)`, `refresh`);
  - `LocationProvider` (`onFix`, `fix()`, `start/stop`);
  - Task 6 `playingPlaceID`, `lastBuzz`, `tellPlace`, `storyID(forPlace:)`, `listen`.
- Produces:
  ```swift
  @MainActor @Observable final class PhoneHeadingProvider {
      private(set) var heading: Double?          // smoothed
      private(set) var accuracy: Double?
      func start(); func stop()
  }
  @MainActor @Observable final class AroundModel {
      private(set) var places: [WalkingPlace]
      private(set) var selection: SelectionState
      private(set) var position: Coordinate?
      private(set) var heading: Double?          // nil when unreliable (no cone)
      private(set) var listAge: TimeInterval?    // shown when > 600 s
      private(set) var loading: Bool             // no list yet
      init(services: AppServices, location: LocationProvider)
      func appear(); func disappear()            // start/stop location, heading, refresh loop
      func choose(_ placeID: String)
      func listen()                              // selected place: stored story → listen(id, 1); else tellPlace
      var language: StoryLanguage { get }
  }
  ```
- Heading: `CMMotionManager.startDeviceMotionUpdates(using: .xTrueNorthZVertical, to: OperationQueue)` at 20 Hz.
  The `@Sendable` handler hops to the MainActor.
  - `v_device = R · v_ref`, so device axis i in the reference frame is row i of `attitude.rotationMatrix`. The
    reference frame is X north, Y west, Z up.
  - top = device +Y = (north m21, east −m22, up m23);
  - back = device −Z = (north −m31, east m32, up −m33).
  - Accuracy: `CMDeviceMotion.heading` is only valid with a magnetometer. Use `CLHeading.headingAccuracy` from the
    existing `LocationProvider.compass?.accuracy`; nil means unreliable.
  - Fallback when device motion is unavailable: `LocationProvider.compass?.heading`.
  - This is device check 1 in the spec: pointing the back camera north must read about 0°.
- Selector updates: on every heading or position change, at most 10 Hz; vectors are rebuilt from the latest
  position.
- Refresh: on each fix, `shouldRefresh(at:trigger: .foreground)`, then `refresh` in a task; the list language is
  the story language.
- When `lastBuzz` changes while the scene is active and the place is in `places`, `choose(placeID)` is called.

- [ ] **Step 1: Implement both files.**
- [ ] **Step 2:** app build. Expected: no errors.
- [ ] **Step 3: Commit** `feat(around): phone heading provider and the model feeding the selector`.

### Task 8: «Rundt deg» map screen replaces the home content (app)

> **Superseded layout:** spec section 14, with the sketch `docs/design/landing-sketch.png`, replaces the layout
> details below. Data, selection, card states and image handling stay. Add `MyGuide/Home/RootTabs.swift`, a tab
> bar with Utforsk and Dagbok. HomeScreen becomes the Utforsk tab. The diary tab gets the history link and the
> settings gear. HomeScreen remains the single owner of LocationProvider (Task 7 ruling), with
> `locationWanted` true while the Utforsk tab is showing its root.

**Files:**
- Create: `MyGuide/Around/AroundMap.swift` (map, markers, cone)
- Create: `MyGuide/Around/AroundPlaceCard.swift`
- Create: `MyGuide/Around/PlaceSymbol.swift`
- Create: `MyGuide/Around/AroundTexts.swift`
- Modify: `MyGuide/Home/HomeScreen.swift`. The map becomes the main surface; the latest-story card is removed
  (spec 5); the toolbar, walking panel and bottom bar stay.
- Modify: `MyGuide/AppServices.swift` (`placeImages`), `MyGuide/Walking/WalkingController.swift` (prefetch after a
  refresh).

**Interfaces:**
- Consumes: Task 7 `AroundModel`; Task 2 `AroundText.whereLine`, `RelativeDirection`; Task 4
  `PlaceImages.cached/image`, `PlaceImages.title(for:)`; `HomeRoute.camera`, `.walkStory(UUID)`.
- Map:
  - `Map(position:)` with
    `.mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))`;
  - `MapCompass` and `MapUserLocationButton` in `.mapControls`;
  - the initial camera follows the user without heading.
- Owner annotation: a forest dot, and a translucent forest wedge of ±30° rotated to `model.heading` (minus the
  camera heading) only when the heading is non-nil.
- Markers: `Annotation` per place, a 28 pt circle with an SF Symbol.
  - Forest with ivory symbol; the selected one coral with forest symbol, at 36 pt.
  - Tap → `model.choose`.
  - Accessibility label: the name plus "valgt" / "selected".
- Place symbols:
  - castle/palace/fort/city_gate/citywalls → `building.columns`;
  - church/cathedral/place_of_worship/monastery → `building.2`;
  - monument/memorial/statue → `figure.stand`;
  - museum/gallery → `photo.artframe`;
  - ruins/archaeological_site/battlefield → `mountain.2`;
  - tower → `antenna.radiowaves.left.and.right`;
  - else → `mappin`.
- Card (spec 6.5), over the bottom bar:
  - the picture is a 64 pt rounded square from the cached image, or none;
  - the name in `Theme.Font.title`;
  - the arrow (`arrow.up` rotated by `relative`, only when `relative` is non-nil) plus the `whereLine`;
  - «Lytt» capsule in coral with forest text, which becomes a spinner or «Stopp» while the place plays;
  - «Ta et bilde» as a link when `suggestPhoto`; it opens `.camera`;
  - tapping the card opens `.walkStory(id)` when a story exists, else starts `listen()` and opens it.
- The image is requested on selection through `PlaceImages.image(wikipediaTitle:)`, which goes on demand per
  spec 12.6.
- States, in the story language (nb / en):

  | State | Norwegian | English |
  |---|---|---|
  | loading | Finner steder rundt deg … | Finding places around you … |
  | noPlaces | Ingen steder å fortelle om her ennå. | Nothing to tell about here yet. |
  | uncertainPosition | Usikker posisjon | Uncertain position |
  | list older than 10 min | Steder fra for NN min siden | Places from NN min ago |

  Uncertain position also shows «Ta et bilde».
- `AppServices` gains `let placeImages: PlaceImages`, with directory `Caches/place-images` and the shared
  `WikipediaClient`. Add `MyGuide/AppServices.swift` to the files.
- Prefetch, so pocket walks get pictures too: after each list refresh, both from `AroundModel` and from
  `WalkingController.fetch`, call `PlaceImages.prefetch(NearbyPlaces.articleTitles(for:around:))`. Make
  `articleTitles` public if needed.

- [ ] **Step 1: Implement.**
- [ ] **Step 2:** app build. Expected: no errors.
- [ ] **Step 3: Install and screenshot-check** is the controller's job. Note in the report which states could not
  be seen.
- [ ] **Step 4: Commit** `feat(around): Rundt deg map with selected place card as the home screen`.

### Task 9: Notification content and attachments (app + Shared payload)

**Files:**
- Create: `Shared/NotificationPayload.swift`, a Codable payload carried in `userInfo["payload"]` as JSON `Data`.
- Modify: `MyGuide/Walking/BuzzNotifier.swift`
- Modify: `MyGuide/Walking/WalkingController.swift`. Pass the language and the image to `post`.

**Interfaces:**
- Consumes: Task 2 `BuzzText.localizedDetail`; Task 3 `FactLine`, `NotificationText`, `FailureCategory`; Task 4
  `PlaceImages.image(wikipediaTitle:within: PlaceImages.notificationCap)`, `PlaceImages.title(for:)`.
- Produces:
  ```swift
  // Shared (no MyGuideCore):
  struct NotificationPayload: Codable, Equatable {
      var label: String          // "STED I NÆRHETEN" text before uppercasing: "Sted i nærheten" / "Neste del" / "Her du stoppet"
      var name: String
      var line: String?          // "50 m foran deg"; nil for STOP
      var fact: String?          // FactLine, or the stop story's first two lines for STOP
      var credit: String?        // photo credit
      static let userInfoKey = "payload"
      func encoded() -> Data; static func decode(_ userInfo: [AnyHashable: Any]) -> NotificationPayload?
  }
  ```
- BUZZ:
  - title = name; subtitle = `localizedDetail`; body = `FactLine.text` or "";
  - actions «Lytt» / «Hopp over»;
  - attachment = the stored image file, copied to a temporary file (UNNotificationAttachment moves its file) with
    `UNNotificationAttachmentOptionsThumbnailHiddenKey` false;
  - payload `label: nearbyLabel`.
- MORE: title = story title, body = `moreBody`, actions «Mer» / «Hopp over», payload `label: nextPartLabel`, same
  image if cached.
- STOP: as today plus payload `label: stoppedLabel`, `fact` = the first two lines of level 1 (up to 2 sentences,
  ≤ 160 characters), no image.
- Failure: title `failedTitle`, body `FailureCategory(error).text`.
- Auto-off: the existing message in the story language. Add both texts beside the existing message.
- Categories are re-registered with the localized action titles at launch and when the story language changes.
- The 1.5 s cap: `post` awaits `image(within:)` before `add`. The walk log's `posting` timing includes it.

- [ ] **Step 1: Implement.** Keep the identifiers, categories, interruption level, thread and sound exactly as
  today.
- [ ] **Step 2:** core `swift test` (no core change expected) and the app build.
- [ ] **Step 3: Commit** `feat(notifications): name, direction, factual line, picture and Norwegian actions`.

### Task 10: Notification Content Extension (new target)

**Files:**
- Create: `MyGuideNotificationContent/NotificationViewController.swift` (UIKit `UIViewController` conforming to
  `UNNotificationContentExtension`, hosting SwiftUI)
- Create: `MyGuideNotificationContent/NotificationCard.swift`
- Create: `MyGuideNotificationContent/Info.plist` (through project.yml)
- Modify: `project.yml`. Add the target and embed it in MyGuide.

**Interfaces:**
- Consumes: `Shared/NotificationPayload.swift`, `MyGuide/Design/Theme.swift` and `MyGuide/Design/Fonts/*` (added
  as sources and resources of the new target).
- Target `MyGuideNotificationContent`:
  - `type: app-extension`, iOS 26.0;
  - bundle `io.github.birgerlie.MyGuide.NotificationContent`;
  - sources `[MyGuideNotificationContent, Shared/NotificationPayload.swift, MyGuide/Design/Theme.swift, MyGuide/Design/Fonts]`;
  - `UIAppFonts` lists the three font files;
  - `NSExtension`:
    - `NSExtensionPointIdentifier: com.apple.usernotifications.content-extension`;
    - `NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).NotificationViewController`;
    - `NSExtensionAttributes`: `UNNotificationExtensionCategory: [BUZZ, MORE, STOP]`,
      `UNNotificationExtensionInitialContentSizeRatio: 1.0`,
      `UNNotificationExtensionDefaultContentHidden: true`,
      `UNNotificationExtensionUserInteractionEnabled: false`.
  - Same signing settings as MyGuideWidgets. Add it to MyGuide's dependencies (embed).
- The card (spec 7.4 + 12.9):
  - Theme background;
  - the attachment image on top when present (read through `attachment.url` with
    `startAccessingSecurityScopedResource`), aspect fill, 16:10, clipped;
  - the label in spaced capitals (13 pt Inter Medium, tracking 1.6);
  - the name in `Theme.Font.title`;
  - `line` with a coral `location.fill` icon;
  - `fact` in `Theme.Font.body`;
  - `credit` in `Theme.Font.caption` at 75 % opacity.
  - 24 pt margins. The height is fitted with `preferredContentSize` from the SwiftUI layout.
- If `Theme.swift` uses anything the extension lacks (such as `Logger`), guard it so it compiles in both targets.
  The extension must not import MyGuideCore.

- [ ] **Step 1: Implement**, then `xcodegen generate`.
- [ ] **Step 2:** app build (it embeds the extension). Expected: no errors. Also confirm the `.appex` is inside
  `MyGuide.app/PlugIns`.
- [ ] **Step 3: Commit** `feat(notifications): expanded notification card in the design`.

### Task 11: Live Activity and Dynamic Island in the design

**Files:**
- Modify: `Shared/WalkingActivityAttributes.swift`. Add `placeName: String?` and `placeFact: String?` to
  `ContentState`; Norwegian and English paused texts chosen by a new `language: String` attribute ("nb"/"en").
- Modify: `MyGuideWidgets/WalkingLiveActivity.swift`
- Modify: `MyGuide/Walking/WalkingActivityController.swift`
- Modify: `project.yml`. Add Theme.swift and Fonts to the widget target, with `UIAppFonts`.

**Interfaces:**
- Consumes: Task 3 `FactLine.text`. The controller computes it; the widget only displays.
- Content (spec 7.5 + 12.5):
  - Walking status headline: «Gåmodus» / «Walking», or «Gåmodus satt på pause» / «Walking paused».
  - Before the first buzz the body is «Ser etter steder rundt deg» / «Looking for places around you».
  - After a buzz, or while a story plays, it shows `placeName` in Playfair and `placeFact` in Inter. No distance.
  - Stop stories: title and text as today, restyled.
  - Stale state: the localized paused texts plus «Åpne MyGuide» / «Open MyGuide».
- A buzz never sets an `AlertConfiguration`. Stop stories keep theirs.
- Island:
  - compact leading: `figure.walk` in coral;
  - compact trailing: the place name truncated to 12 characters, or nothing;
  - minimal: `figure.walk` in coral;
  - expanded: the name in Playfair plus the fact, with 2 lines maximum.
- Colours follow light and dark mode through Theme tokens. `activityBackgroundTint(Theme.Colour.background)`.

- [ ] **Step 1: Implement.** The controller sets the place on `deliver` (buzz) and on story playback start.
- [ ] **Step 2:** app build. Expected: no errors.
- [ ] **Step 3: Commit** `feat(live-activity): place name and fact in the design; no extra alert on buzz`.

### Task 12: Walk story screen in the photo story layout (app)

**Files:**
- Create: `MyGuide/Story/StoryComponents.swift`. Extract from `StoryView.swift`: `StorySheetPage` (photo +
  overlapping sheet), `SectionLabel`, `StoryDivider`, `ListenBar` (big coral bottom button + status line) and
  `MoreSourcesRow`.
- Modify: `MyGuide/Story/StoryView.swift`. Use the components; its behaviour must not change.
- Modify: `MyGuide/Walking/WalkStoryView.swift`. Rewrite per spec 8.
- Modify: `MyGuide/Story/StoryViewModel.swift`. Move the `SourcesSheet` from `StoryView` into the components so
  both screens share it.

**Interfaces:**
- Consumes:
  - Task 5 `StorySources.list(for: WalkStory, image:, language:)`;
  - Task 4 `PlaceImages.cached` / `image`;
  - Task 2 `RelativeDirection`, `AroundText.whereLine`;
  - Task 3 `NotificationText.nearbyLabel` / `stoppedLabel`.
- Walk story:
  - hero = the place's image when there is one, else no hero;
  - label «Sted i nærheten» for buzz and chosen, «Her du stoppet» for stop;
  - name `Theme.Font.display`;
  - where-line from `story.position` to `story.place` with `story.course` as the direction (`relative` =
    `PlaceSelector.offset(heading: course, bearing:)` when the course is non-nil, else nil), prefixed by the
    address city line when known;
  - «KORT FORTELLING» and levels with `StoryText`; deeper levels get «MER» / «ENDA MER» and their own Lytt
    (`stories.listen(id, level:)`);
  - «Mer om <name>» (`stories.more`), «Kilder» (shared sheet), and the photo credit under the hero when there is
    one;
  - `ListenBar` bound to level 1 (`stories.listen` / `stopListening`), with the status line «Lagret i dagboken»;
  - «Hopp over dette stedet» / «Skip this place» as a quiet link when `canSkip`;
  - failures from `stories.lastFailure` in red caption;
  - the preparing state: `StorySheetPage` with «Skriver fortellingen …» and a disabled ListenBar.

- [ ] **Step 1: Extract the components and switch `StoryView` to them.** Build; the photo story screen must look
  the same.
- [ ] **Step 2: Rewrite `WalkStoryView`.**
- [ ] **Step 3:** app build plus core `swift test`.
- [ ] **Step 4: Commit** `feat(walk-story): walk story screen in the design, shared story components`.

### Task 13: Walking fixes from the Rome walk — 30-day rule, read counts, speech on demand, reset, OSM resilience (core + app)

Executed right after Task 6, before Task 7. The binding text is spec section 13.

**Files:**
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Memory/WalkMemory.swift`. Change `retiredPlaceIDs(now:)`, add
  `resetPlaceNotifications()`, and remove the trip exclusion's caller.
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Grounding/OverpassClient.swift`. Add the fallback endpoint.
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/WalkingPlaceSource.swift`. Report an OSM failure.
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Grounding/NearbyPlaces.swift` and `NearbyList.swift`. Carry the
  OSM places forward.
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/WalkLog/WalkLogEvent.swift`. `fetched` gains
  `osmFailed: Bool`.
- Modify: `MyGuide/Walking/WalkingController.swift`, `WalkingStories.swift`, `WalkStoryView.swift`,
  `WalkingPanel.swift` (or the status texts), and `MyGuide/Settings/SettingsView.swift`.
- Test: `WalkMemoryTests`, `OverpassClientTests`, `WalkingPlaceSourceTests`, `NearbyPlacesTests`,
  `WalkLogEventTests`.

**Interfaces:**
- Produces:
  ```swift
  extension MemoryStore {
      public static let placeRestDays = 30
      /// Retired: (deepestLevelHeard ≥ 1 and lastHeardAt ≥ now − 30 d) or (skippedAt ≥ now − 30 d). A heard place with
      /// lastHeardAt nil (stored before lastHeardAt existed) is not retired.
      public func retiredPlaceIDs(now: Date) throws -> Set<String>
      /// Sets lastHeardAt and skippedAt to nil on every place; deepestLevelHeard, stories, buzz log untouched.
      public func resetPlaceNotifications() throws
  }
  // OverpassClient: endpoints [overpass-api.de, overpass.kumi.systems]; the second is tried once when the first throws
  // (HTTP non-2xx, timeout, malformed). Cancellation is never retried.
  public struct PlaceSearchResult: Sendable, Equatable { public var candidates: [Candidate]; public var osmFailed: Bool }
  // WalkingPlaceSource.candidates(...) returns PlaceSearchResult (both failing still throws the OSM error).
  // NearbyList gains `osmFailed: Bool` (Codable, default false when decoding old files).
  // NearbyPlaces.refresh: when osmFailed and the previous list (same language) is ≤ 7 days old with centre ≤ 500 m away,
  // its "osm:" candidates are merged in (CandidateRanker.merge) and osmFailed stays true for the log.
  // WalkLogEvent.Kind.fetched gains `osmFailed: Bool` (encoded as "osmFailed"; old lines decode as false).
  ```
- App:
  - `WalkingController` builds the exclusions from `retiredPlaceIDs(now:)` only. The trip's `placeIDsBuzzed` is
    no longer excluded; the in-run `engine.exclude` on delivery stays.
  - `WalkingStories.prepare` stops after the text (no `speechFile` for level 1). `tellMe` / `listen` fetch the
    speech on demand, as `more` already does, and the playback state waits while loading.
  - Opening `WalkStoryView` for a buzz or chosen story marks level 1 read through `memory.markHeard`. That sets
    `lastHeardAt`.
  - `WalkingPanel` shows «Du har hørt om alt i nærheten» / «You've heard about everything nearby» while the last
    quiet reason is `allExcluded`.
  - Settings has a «Nullstill stedsvarsler» / «Reset place notifications» button with a confirmation dialog:
    - dialog text «Alle steder kan gi varsel igjen. Fortellinger og dagbok beholdes.» / «Every place can notify
      you again. Stories and diary are kept.»;
    - on confirm it calls `resetPlaceNotifications()` and `WalkingController.resetExclusions()`, which clears the
      running engine's exclusions.

- [ ] **Step 1: Write the failing core tests:**
  - `retiredWithinThirtyDays`: heard 29 d 23 h ago is retired; 30 d 1 h ago is not; skipped likewise; heard with
    lastHeardAt nil is not retired.
  - `resetMakesEveryPlaceEligibleAndKeepsHistory`.
  - `overpassFallsBackToSecondEndpointOnce`: the first returns 502, the second answers, so 2 requests; both fail
    gives a throw after 2 requests; cancellation makes 1 request and no retry.
  - `osmFailureReportedWhenWikipediaAnswers`.
  - `previousOSMPlacesCarriedForward`: centre 400 m and 6 days carries; 600 m or 8 days does not.
  - `fetchedEventCarriesOSMFailedAndOldLinesDecode`.
- [ ] **Step 2:** run them; they FAIL.
- [ ] **Step 3: Implement the core part**, then the app changes.
- [ ] **Step 4:** full core `swift test` and the app build.
- [ ] **Step 5: Commit** `fix(walking): 30-day place rest, reading counts, speech on demand, reset button, OSM fallback`.

### Task 14: Design pass over every remaining screen (app + watch)

Spec section 15 is binding. Run this after Task 12, which extracts `StoryComponents` (SectionLabel and friends);
reuse those components.

**Files:**
- Modify: `MyGuide/Diary/DiaryView.swift`, `DiaryRows.swift`, `DayStoryView.swift`
- Modify: `MyGuide/History/HistoryView.swift`
- Modify: `MyGuide/Settings/SettingsView.swift`, `StoryTimingsView.swift`, `BuzzLogView.swift`,
  `WalkLogListView.swift`, `WalkLogRunView.swift`
- Modify: `MyGuide/SelfCheck/SelfCheckView.swift`, `MyGuide/WalkingCheck/WalkingCheckView.swift`
- Modify: `MyGuideWatch/GuidedWalkView.swift`, `WatchCheckView.swift`. Add a small watch colour palette with the
  same hex values. The watch does not link `Theme.swift`'s fonts; use the system font.

**Steps:**
- [ ] Apply the spec 15 rules screen by screen. Behaviour and data are unchanged.
- [ ] Texts: any user-facing string you touch comes in both story languages, through a local texts enum per area.
- [ ] Build the app (it embeds the watch app). Expected: no errors.
- [ ] Commit `style: every remaining screen in the design package`.
