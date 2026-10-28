# Walk Log and Auto-Pause Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A per-walk JSON Lines log (where the owner walked, what was found, why it stayed quiet, what was notified, what failed), shown on a map and timeline and shareable. Walking mode also pauses itself after 3 minutes still and resumes on walking motion or GPS movement.

**Architecture:** All rules and formats are pure code in `Packages/MyGuideCore` with Swift Testing:
- the engine's quiet reasons;
- the auto-off and status changes;
- the pause detector;
- the log events with their JSON line codec, file writer, reader and pruning;
- the summary, map data, timeline text and quiet throttle.

The app layer wires CoreLocation, CoreMotion, files, Live Activity and SwiftUI. A `WalkLog` object owned by `AppServices` is handed to `WalkingController` and `WalkingStories`.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, MapKit for SwiftUI, CoreMotion, CoreLocation, ActivityKit, Swift Testing, XcodeGen. iOS 26.

**Spec:** `docs/superpowers/specs/2026-10-28-walk-log-and-auto-pause-design.md`. Section 9 settles the builder questions and is binding.

## Global Constraints

- Swift 6 language mode, strict concurrency, iOS 26. No new package dependencies. No SwiftData change.
- The log never contains the API key, request or response bodies, or story text. Error strings are `String(describing:)` cut to 300 characters.
- Logging never stops or noticeably slows walking mode. A write failure goes to `os.Logger(subsystem: "io.github.birgerlie.MyGuide", category: "walklog")` and the event is dropped.
- JSON line format:
  - every line has `"t"` (ISO 8601 UTC with fractional seconds) and `"e"`;
  - coordinates are rounded to 6 decimals, distances and accuracy to whole metres, seconds to 1 decimal;
  - keys are sorted.
- App UI text is in English.
- Spec numbers (copy exactly):
  - pause: still 180 s; still radius `max(30 m, accuracy)`; usable accuracy ≤ 50 m;
  - resume: walking more than 60 s, or `distance − accuracy > 100 m` with accuracy ≤ 100 m;
  - timer 15 s; auto-off every 4th tick;
  - paused too long 3600 s; active-time limit 14 400 s; battery 15 %;
  - keep 20 log files; at most 150 places per `fetched`; paused stale date now + 120 s;
  - paused location: `kCLLocationAccuracyHundredMeters` with a 50 m distance filter.
- Core test command: `cd Packages/MyGuideCore && swift test`.
- App build: `xcodegen generate && xcodebuild -project MyGuide.xcodeproj -scheme MyGuide -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/claude-501/-Users-birger-code-MyGuide/43e8ac03-ea1c-4b4d-b907-cc5e890c10a9/scratchpad/dd -quiet CODE_SIGNING_ALLOWED=NO build`. Unsigned; never write `build/` inside the repo.
- Every numeric assertion has its hand computation in a comment above it (owner rule).
- Complete implementations, no TODOs. Commit after each task with a conventional message ending in `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push.

## Review Focus

1. **Someone walking steadily after a single `walking` motion report must never pause.** Motion reports only on change. Task 3 test `steadyWalkingAfterOneReportNeverPauses`.
2. **A crash mid-write leaves a truncated last line.** The reader must return every earlier event and count one unreadable line. Task 4 test `truncatedLastLineIsCountedNotFatal`.
3. **A long walk past nothing must give one `noneDue` line, not one per fix.** Task 5 test `repeatedNoneDueLogsOnce`.
4. **GPS jitter indoors while paused must not resume.** A fix at 120 m with accuracy 65 m gives 120 − 65 = 55 ≤ 100. Task 3 test `inaccurateFarFixDoesNotResume`.
5. **Pause time must not count toward the 4-hour limit, and a pause in progress counts up to now.** Task 2 test `activeTimeSubtractsFinishedAndCurrentPauses`.

---

### Task 1: Buzz engine quiet reasons

**Files:**
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/BuzzEngine.swift`
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/BuzzEngineTests.swift` (add tests; existing tests unchanged)

**Interfaces:**
- Produces:
  ```swift
  public enum QuietReason: String, Sendable, Codable, CaseIterable { case badAccuracy, noneDue, busy, skipQuiet, allExcluded, budget }
  public struct DuePlace: Sendable, Equatable, Codable { public var id: String; public var name: String; public var tier: PlaceTier; public var distance: Double; public var excluded: Bool }
  public enum BuzzDecision: Sendable, Equatable { case buzz(Buzz); case quiet(QuietReason, due: [DuePlace])
      public var buzz: Buzz? { get } }
  extension BuzzEngine { public mutating func decide(places: [WalkingPlace], position: Coordinate, accuracy: Double, course: Double?, now: Date) -> BuzzDecision }
  ```
  `evaluate(...)` becomes `decide(...).buzz`.

- [ ] **Step 1: Write failing tests** (use the file's `place`/`engine` helpers and `.at(north:)`).
  - `badAccuracyIsQuietWithNoDue`: accuracy 51 with a place 10 m north gives `.quiet(.badAccuracy, due: [])`.
  - `noneDueWhenNothingWithin60m`: a place 70 m north gives `.quiet(.noneDue, due: [])`.
  - `busyListsDuePlaces`: set `isBusy = true`, place `a` (.good) 40 m north, so the result is `.quiet(.busy, due: [DuePlace(id: "a", name: "a", tier: .good, distance: ≈40, excluded: false)])`. Compare the distance with `abs(d - 40) < 0.01`. Hand computation: `.at(north: 40)` is 40 m by construction (Support/Metres.swift).
  - `skipQuietWithin60s`: buzz `a` at t0, `noteSkip(at: t0)`, add place `b` 50 m north; at t0+59 `.quiet(.skipQuiet, …)`. Hand computation: 59 < 60.
  - `allExcludedFlagsExcluded`: engine with `excluded: ["a"]` and `a` 40 m north gives `.quiet(.allExcluded, due: [DuePlace(id:"a", …, excluded: true)])`.
  - `budgetWhenSpent`: perHour 20, `a` buzzes at t0, `b` (.good, 50 m) at t0+179 gives `.quiet(.budget, …)`. Due lists `a` (excluded true) and `b` (excluded false) in tier-then-distance order. Hand computation: 20/h means 3600/20 = 180 s spacing; 179 < 180.
  - `dueOrderedByTierThenDistance`: busy, with `x` .good at 10 m and `y` .top at 50 m, gives due ids `["y", "x"]`.
  - `evaluateStillMatchesDecide`: the same inputs into two engines give `evaluate == decide.buzz`.
- [ ] **Step 2: Run** `swift test --filter BuzzEngineTests`. Expected: compile failure (no `decide`).
- [ ] **Step 3: Implement `decide`** in `BuzzEngine.swift`. Move the body of `evaluate` into it and keep the order and the `closest` update exactly as now. The quiet reason order is the spec 4.3 / 9.11 order. `allExcluded` applies when there are due places but none survive the filter. `budget` applies when candidates exist and neither the budget nor an override buzzed. `due` holds every due place sorted by `(tier, distance)`, with `excluded` from the excluded set.
- [ ] **Step 4: Run** `swift test`. Expected: all pass (the branch's existing 655 tests plus the new ones).
- [ ] **Step 5: Commit** `feat(walking): buzz engine says why it stayed quiet`.

### Task 2: Auto-off with active time, paused status text

**Files:**
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/AutoOff.swift`, `Packages/MyGuideCore/Sources/MyGuideCore/Walking/WalkingStatus.swift`
- Modify (keep the app building): `MyGuide/Walking/WalkingController.swift` (`checkAutoOff`, `refreshActivity`), `MyGuide/Walking/WalkingStatusPill.swift`
- Test: `AutoOffTests.swift` (rewrite for the new signature), `WalkingStatusTests.swift` (add)

**Interfaces:**
- Produces:
  ```swift
  public enum AutoOffReason { case timeLimit, lowBattery, pausedTooLong }
  AutoOff.maxPause: TimeInterval = 3_600
  AutoOff.reason(activeTime: TimeInterval, pausedFor: TimeInterval?, batteryLevel: Float) -> AutoOffReason?   // order: timeLimit, pausedTooLong, lowBattery
  AutoOff.activeTime(startedAt: Date, now: Date, pausedTotal: TimeInterval, pausedSince: Date?) -> TimeInterval   // never below 0
  AutoOff.message(.pausedTooLong) == "Walking mode turned off after an hour without walking."
  WalkingStatus.text(isOn: Bool, lastFixAt: Date?, buzzCount: Int, now: Date, paused: Bool = false) -> String?   // paused → "Paused · N buzz/buzzes"
  WalkingStatus.pausedStaleDate(now: Date) -> Date   // now + staleAfter (120)
  ```
  The old `reason(startedAt:now:batteryLevel:)` is removed.

- [ ] **Step 1: Failing tests.**
  - `limits`: activeTime 14 399 gives nil, 14 400 gives `.timeLimit`; pausedFor 3 599 gives nil, 3 600 gives `.pausedTooLong`. Keep the battery cases 0.15, 0.149, −1 and 0 from the old test.
  - `order`: (14 400, 3 600, 0.05) gives `.timeLimit`; (100, 3 600, 0.05) gives `.pausedTooLong`.
  - `activeTimeSubtractsFinishedAndCurrentPauses`: startedAt t0, now t0+5 000, pausedTotal 1 000, pausedSince t0+4 500. Hand computation: 5 000 − 1 000 − 500 = 3 500.
  - `activeTimeNeverNegative`: clock backwards (now t0−10) gives 0.
  - `messages`: the three exact messages.
  - `pausedTextWinsOverWaiting`: `text(isOn: true, lastFixAt: nil, buzzCount: 1, now: t0, paused: true) == "Paused · 1 buzz"`, and with 2 buzzes `"Paused · 2 buzzes"`. When off, the result is nil even if paused.
  - `pausedStaleDate`: t0 gives t0 + 120.
- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement.** In the app, `checkAutoOff` calls `AutoOff.reason(activeTime: AutoOff.activeTime(startedAt:now:pausedTotal: 0, pausedSince: nil), pausedFor: nil, batteryLevel:)` for now. Task 7 supplies the real pause values. The pill and `refreshActivity` pass `paused: false` for now.
- [ ] **Step 4: Run core tests and the unsigned app build.** Both must pass.
- [ ] **Step 5: Commit** `feat(walking): auto-off counts active time; paused status text`.

### Task 3: Pause detector

**Files:**
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/PauseDetector.swift`
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/PauseDetectorTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum MotionActivity: String, Sendable, Codable { case stationary, walking, running, automotive, cycling, unknown }
  public enum MotionConfidence: String, Sendable, Codable { case low, medium, high }
  public struct MotionReading: Sendable, Equatable { public var activity: MotionActivity; public var confidence: MotionConfidence; public var at: Date
      public var isWalking: Bool { get } }   // (walking or running) and confidence medium/high
  public enum PauseTrigger: String, Sendable, Codable { case motion, gps }
  public enum PauseChange: Sendable, Equatable { case pause(PauseTrigger, anchor: Coordinate?); case resume(PauseTrigger) }
  public struct PauseDetector: Sendable {
      public static let stillDuration: TimeInterval = 180, stillRadius = 30.0, maxStillAccuracy = 50.0
      public static let resumeWalkingDuration: TimeInterval = 60, resumeDistance = 100.0, maxResumeAccuracy = 100.0
      public private(set) var isPaused: Bool
      public private(set) var pausedSince: Date?
      public init(now: Date, motionAvailable: Bool)
      public mutating func motion(isWalking: Bool, at: Date) -> PauseChange?
      public mutating func fix(position: Coordinate, accuracy: Double, at: Date) -> PauseChange?
      public mutating func tick(now: Date) -> PauseChange?
  }
  ```
  **Rules** (spec 5.2, 5.3, 9.1):
  - State: `walkingSince: Date?`, `stillStart: Date`, `anchor: Coordinate?`, `pauseAnchor: Coordinate?`.
  - `motion(true)` while not walking sets `walkingSince = at`. While already walking it keeps the earlier time.
  - `motion(false)` while walking sets `walkingSince = nil`, `stillStart = at` and `anchor = nil`. While already not walking it changes nothing.
  - Active fix with 0 ≤ accuracy ≤ 50:
    - no anchor: the fix becomes the anchor;
    - distance > `max(30, accuracy)`: anchor = fix and `stillStart = at`.
    - Other fixes are ignored while active.
  - Every call, when active: pause when `walkingSince == nil` and `now − stillStart ≥ 180`.
    - The trigger is `.motion` if `motionAvailable`, else `.gps`.
    - The change carries `anchor`; `pauseAnchor = anchor`.
  - Every call, when paused:
    - resume `.motion` when `walkingSince != nil` and `now − walkingSince > 60`;
    - on a fix with 0 ≤ accuracy ≤ 100: no `pauseAnchor` means the fix becomes it; otherwise resume `.gps` when `distance − accuracy > 100`.
  - On resume: `isPaused = false`, `pausedSince = nil`, `stillStart = now`, `anchor = nil`, `pauseAnchor = nil`.
  - "now" is the event's time (`at`) for `motion` and `fix`.
  - `MotionReading.isWalking`: `.walking` or `.running` with confidence `.medium` or `.high`.

- [ ] **Step 1: Failing tests.** Start every test from `PauseDetector(now: t0, motionAvailable: true)` unless noted.
  - `pausesAfter180sStill`: tick t0+179 gives nil; tick t0+180 gives `.pause(.motion, anchor: nil)`; `isPaused`, `pausedSince == t0+180`.
  - `steadyWalkingAfterOneReportNeverPauses`: `motion(true, t0+1)`, then ticks every 15 s up to t0+3 600 all give nil.
  - `walkingThenStoppingRestartsStretch`: `motion(true, t0+10)`, `motion(false, t0+100)`; tick t0+279 gives nil, t0+280 gives pause. Hand computation: 100 + 180 = 280.
  - `gpsOnlyTriggerIsGps`: `motionAvailable: false`, tick t0+180 gives `.pause(.gps, anchor: nil)`.
  - `fixWithin30mKeepsStretch`: fix at `.at()` acc 5 at t0+10, fix at `.at(north: 29)` acc 5 at t0+100; tick t0+180 gives `.pause(.motion, anchor: .at())`.
  - `fixBeyond30mMovesAnchorAndRestarts`: fix `.at()` at t0+10, fix `.at(north: 31)` acc 5 at t0+100; tick t0+279 gives nil, t0+280 gives pause with anchor `.at(north: 31)`. Hand computation: 31 > max(30, 5) = 30, so the stretch restarts at 100, and 100 + 180 = 280.
  - `poorAccuracyWidensRadius`: fix `.at()` acc 5 at t0+10, fix `.at(north: 40)` acc 45 at t0+20; tick t0+180 gives pause (40 ≤ max(30, 45) = 45, so no move). A fix at acc 60 is ignored entirely.
  - `resumesAfterMoreThan60sWalking`: paused at t0+180; `motion(true, t0+200)`; tick t0+260 gives nil (60 is not > 60); tick t0+261 gives `.resume(.motion)`.
  - `walkingInterruptedDoesNotResume`: paused; `motion(true, t0+200)`, `motion(false, t0+230)`, `motion(true, t0+240)`; tick t0+300 gives nil (60 s since 240, not more); t0+301 gives resume.
  - `gpsResumeNeedsDistanceMinusAccuracyOver100`: fix `.at()` acc 5 at t0+10; paused at t0+180 with anchor `.at()`. Fix `.at(north: 110)` acc 10 gives nil (110 − 10 = 100, not > 100). Fix `.at(north: 111)` acc 10 gives `.resume(.gps)` (101 > 100).
  - `inaccurateFarFixDoesNotResume`: paused with anchor `.at()`; fix `.at(north: 120)` acc 65 gives nil (120 − 65 = 55); fix at acc 101 is ignored.
  - `pausedWithoutAnchorTakesFirstFix`: no fixes; paused at t0+180 (anchor nil). Fix `.at(north: 500)` acc 50 gives nil (it becomes the anchor). Fix `.at(north: 651)` acc 50 gives resume (151 − 50 = 101).
  - `afterResumeStretchRestarts`: paused at t0+180, `motion(true, t0+200)`, tick t0+261 resumes; then `motion(false, t0+262)`; tick t0+441 gives nil and t0+442 gives pause. Hand computation: the stretch restarts at 262 when walking stops, and 262 + 180 = 442.
  - `isWalkingConfidence`: walking/low is false; walking/medium, running/high true; automotive/high, stationary/high false.
- [ ] **Step 2: Run, expect failure. Step 3: Implement. Step 4: Run all core tests.**
- [ ] **Step 5: Commit** `feat(walking): pause detector from motion state and GPS`.

### Task 4: Walk log events, line codec, writer, reader, store

**Files:**
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/WalkLog/WalkLogEvent.swift` (types and factories), `.../WalkLog/WalkLogCodec.swift` (line encode/decode), `.../WalkLog/WalkLogFiles.swift` (writer, reader, store)
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/WalkLogEventTests.swift`, `WalkLogFilesTests.swift`

**Interfaces:**
- Consumes: `QuietReason`, `DuePlace` (Task 1); `MotionActivity`, `MotionConfidence`, `PauseTrigger` (Task 3); `Buzz`, `WalkingPlace`, `PlaceTier`, `Coordinate`, `GeoMath`.
- Produces:
  ```swift
  public struct WalkLogEvent: Sendable, Equatable { public var at: Date; public var kind: Kind; public init(at: Date, kind: Kind)
    public enum Kind: Sendable, Equatable {
      case started(WalkLogStart)
      case stopped(WalkStopReason)
      case app(foreground: Bool)
      case fix(WalkLogFix)
      case gps(found: Bool)
      case fetchStarted(Coordinate)
      case fetched(count: Int, top: Int, good: Int, wikiOnly: Int, places: [WalkLogPlace])
      case fetchFailed(error: String)
      case quiet(QuietReason, due: [DuePlace])
      case buzz(WalkLogBuzz)
      case notified(id: UUID?, kind: WalkNotificationKind, settings: NotificationSettingsSnapshot)
      case notifyFailed(id: UUID?, kind: WalkNotificationKind, error: String)
      case busy(Bool)
      case storyPreparing(id: UUID)
      case storyReady(id: UUID, seconds: Double)
      case storyFailed(id: UUID, seconds: Double, error: String)
      case stopDetected(Coordinate)
      case stopStory(outcome: StopStoryOutcome, title: String?, error: String?)
      case stopShown(via: StopShownVia)
      case motion(MotionActivity, confidence: MotionConfidence)
      case paused(PauseTrigger, at: Coordinate?)
      case resumed(PauseTrigger, pausedSeconds: Double)
      case failure(context: String, error: String)
    }
    public static func errorText(_ error: Error) -> String               // String(describing:), first 300 characters
    public static func fetched(_ places: [WalkingPlace], around: Coordinate) -> Kind   // counts over all; places capped at 150 by (tier, distance from `around`)
  }
  public struct WalkLogStart: Sendable, Equatable { appVersion, build: String; location: LocationPermission; notifications: NotificationPermission; liveActivities: Bool; motion: MotionPermission; perHour: Int; battery: Double? }
  public enum LocationPermission: String { case always, whenInUse, denied, notDetermined }
  public enum NotificationPermission: String { case allowed, denied, notDetermined }
  public enum MotionPermission: String { case authorized, denied, restricted, notDetermined, unavailable }
  public enum WalkStopReason: String { case user, timeLimit, lowBattery, pausedTooLong, locationDenied }
  public struct WalkLogFix: Sendable, Equatable { coordinate: Coordinate; accuracy: Double; speed: Double?; course: Double?; paused: Bool; dropped: FixDrop? }
  public enum FixDrop: String { case stale, invalid }
  public struct WalkLogPlace: Sendable, Equatable { id, name: String; tier: PlaceTier; coordinate: Coordinate }
  public struct WalkLogBuzz: Sendable, Equatable { id: UUID; placeID, name: String; tier: PlaceTier; distance: Double; override: Bool; detail: String
      public init(_ buzz: Buzz) }
  public enum WalkNotificationKind: String { case buzz, more, stop, storyFailed, autoOff }
  public struct NotificationSettingsSnapshot: Sendable, Equatable { authorization, alert, sound, lockScreen, notificationCenter, timeSensitive: String }
  public enum StopStoryOutcome: String { case told, silent, failed }
  public enum StopShownVia: String { case liveActivity, notification }
  public enum WalkLogCodec { static func line(_ event: WalkLogEvent) -> Data   // one JSON object + "\n"
                             static func event(from line: Data) -> WalkLogEvent? }
  public final class WalkLogWriter { public let url: URL; public init(url: URL) throws; public func append(_ event: WalkLogEvent) throws; public func close() }
  public enum WalkLogReader { static func read(_ data: Data) -> (events: [WalkLogEvent], unreadable: Int) }
  public enum WalkLogStore {
      public static let keep = 20
      public static func fileName(start: Date, runID: UUID, timeZone: TimeZone) -> String   // "yyyyMMdd-HHmmss-<UUID>.jsonl"
      public static func runFiles(in directory: URL) throws -> [URL]                        // .jsonl only, newest first by name
      public static func prune(in directory: URL, keep: Int = keep, sparing: URL?) throws   // deletes oldest beyond `keep`; never `sparing`
  }
  ```
  All the enums are `String`-raw, `Sendable` and `Codable`, and all the structs are `Sendable` and `Equatable` with public memberwise inits. The JSON field names are exactly those of spec 4.2 and 9.4–9.5. Specifically:
  - `fix` holds `lat`, `lon`, `accuracy`, `speed`, `course`, `paused`, and `dropped` only when non-nil.
  - `fetched` holds `count`, `top`, `good`, `wikiOnly` and `places: [{id, name, tier, lat, lon}]`. `tier` is the raw Int.
  - `quiet` holds `reason` and `due: [{id, name, tier, distance, excluded}]`.
  - `notified` holds `id` (null allowed), `kind` and `settings: {…}`.
  - `paused` holds `reason`, `lat` and `lon` (null when no anchor).
  - `resumed` holds `reason` and `pausedSeconds`.

  Null optionals are written as JSON `null`, except `dropped`, which is omitted. The writer appends with `FileHandle.write`. Each event is one unbuffered write, so a crash loses at most the line being written; no fsync is needed.

- [ ] **Step 1: Failing tests.**
  - `roundTripEveryKind`: one event of every case through `line` and then `event(from:)` comes back equal. Pre-round the values: coordinates to 6 decimals, distances and accuracy whole, seconds to 1 decimal.
  - `rounding`: lat 59.91234567 is written as `59.912346`; distance 52.6 as 53; seconds 3.04 as 3.0 and 3.06 as 3.1 (3.05 is avoided: it is 3.0499… in binary). Hand computation: 6-decimal rounding of …4567 gives …46, half away from zero. Use `(x * 1e6).rounded() / 1e6` and assert on the decoded Double.
  - `fixJSONShape`: parse the line with `JSONSerialization` and check the keys are exactly `["accuracy","course","e","lat","lon","paused","speed","t"]` when not dropped, and the line ends with `"\n"`. `"e" == "fix"`; `"speed"` is `NSNull` when nil.
  - `timestampIsUTCWithFraction`: Date(1_000_000.25) gives `"t" == "1970-01-12T13:46:40.250Z"`. Hand computation: 1 000 000 s = 11 d 13 h 46 m 40 s after the epoch.
  - `errorTextCutAt300`: a 400-character description gives exactly 300 characters.
  - `fetchedCountsAndCap`: 160 places, 10 top, 100 good, 50 wikiOnly, at increasing distance. The result has count 160, top 10, good 100, wikiOnly 50 and 150 places, the first 10 top and the last ones good before any wikiOnly. Hand computation: 10 + 100 + 40 = 150, so 10 wikiOnly are dropped.
  - `unknownEventIsUnreadable`: `{"t":"…","e":"nope"}` gives nil.
  - Writer and reader (temp directory per test, removed after):
    - `writerAppendsAndReaderReads`: three events written, so `read` returns the three in order with unreadable 0;
    - `truncatedLastLineIsCountedNotFatal`: write two events, then append the first 10 bytes of a third line. `read` returns two with unreadable 1;
    - `blankLinesIgnored`: a trailing `"\n\n"` is not counted as unreadable.
  - Store:
    - `fileNameFormat`: start 2026-10-28 14:03:09 in Europe/Oslo gives `"20261028-140309-<uuid>.jsonl"`;
    - `pruneKeepsNewest20AndSpares`: 23 files with ascending names plus `sparing` = the oldest leaves 21 files: the 20 newest plus the spared one;
    - `runFilesNewestFirstOnlyJsonl`: a `.txt` file is ignored.
- [ ] **Step 2: Run, expect failure. Step 3: Implement. Step 4: Run all core tests.**
- [ ] **Step 5: Commit** `feat(walklog): events, JSON lines codec, writer, reader and store`.

### Task 5: Summary, map data, timeline text, quiet throttle

**Files:**
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/WalkLog/WalkLogSummary.swift`, `.../WalkLog/WalkLogText.swift`, `.../WalkLog/QuietThrottle.swift`
- Test: `WalkLogSummaryTests.swift`, `WalkLogTextTests.swift`, `QuietThrottleTests.swift`

**Interfaces:**
- Consumes: Task 4 types.
- Produces:
  ```swift
  public struct WalkLogSummary: Sendable, Equatable {
      public var start: Date?; public var end: Date?; public var duration: TimeInterval   // end − start, 0 when empty
      public var distance: Double; public var fetches, fetchFailures, places, buzzes, notifications, failures, pauses: Int
      public var stopReason: WalkStopReason?   // nil means "Ended without a stop"
      public var unreadable: Int
      public init(events: [WalkLogEvent], unreadable: Int)
  }
  public struct WalkLogMapData: Sendable, Equatable {
      public var path: [[Coordinate]]          // segments; a paused fix or a `paused` event ends a segment
      public var places: [WalkLogPlace]        // distinct by id, last seen wins, in first-seen order
      public var buzzedPlaceIDs: Set<String>
      public var stops: [Coordinate]           // stopDetected whose next stopStory is `told`
      public var pauses: [Coordinate]          // `paused` events with a position
      public init(events: [WalkLogEvent])
  }
  public enum WalkLogText { public static func line(_ kind: WalkLogEvent.Kind) -> String }
  public struct QuietThrottle: Sendable { public init(); public mutating func shouldLog(_ reason: QuietReason, due: [DuePlace]) -> Bool; public mutating func reset() }
  ```
  **Distance and path:**
  - Only `fix` events with `dropped == nil`, `paused == false` and accuracy ≤ 50 count.
  - Distance sums the `GeoMath.distance` between consecutive counting fixes within a segment.
  - A paused fix or a `paused` event ends the segment. Non-counting unpaused fixes are skipped without ending it.

  **Counts:**
  - `places` counts distinct place ids across all `fetched` events.
  - `notifications` counts `notified` events.
  - `failures` counts `failure`, `fetchFailed`, `notifyFailed` and `storyFailed` events.

  **QuietThrottle** logs when `(reason, due ids sorted)` differs from the last logged pair. After `reset()` the next call always logs.

  **Timeline text** (exact for these, free wording for the rest; never empty):
  - `fetched` gives `"Fetched 34 places (3 top, 12 good)"`.
  - `quiet(.busy, due: [Akershus festning 52 m])` gives `"Quiet: busy · Akershus festning 52 m"`. Several due places are joined with `", "`, and none gives just `"Quiet: noneDue"`.
  - `buzz` gives `"Buzz: <name> · <distance> m"`, with `" (override)"` appended when it was an override.
  - `stopped(.user)` gives `"Stopped: user"`.
  - `paused(.motion, …)` gives `"Paused (motion)"`; `resumed(.gps, pausedSeconds: 312)` gives `"Resumed (gps) after 5 min"`. Hand computation: 312 s / 60 = 5.2, floor 5.

- [ ] **Step 1: Failing tests.**
  - `distanceSkipsPausedAndPoorFixes`: counting fixes at north 0, 10 and 30, then a paused fix at 1 000, then a counting fix at 1 010 and one at 1 020. Hand computation: 10 + 20 = 30 in the first segment and 10 in the second, so 40 in total, with 2 segments.
  - `poorFixSkippedNotSplitting`: north 0 (acc 5), north 10 (acc 80, skipped), north 20 (acc 5) gives 20 m and 1 segment.
  - `endedWithoutStop`: no `stopped` event means `stopReason == nil`.
  - `countsAndPlacesDistinct`: two `fetched` events sharing one id out of 3 and 2 places give places 4. Hand computation: 3 + 2 − 1 = 4.
  - `durationFromFirstToLast`: events at t0 and t0+3 725.5 give a duration of 3 725.5.
  - `emptyLog`: no events gives start nil, duration 0 and distance 0.
  - `stopsOnlyWhenTold`: stopDetected A, stopStory told, stopDetected B, stopStory silent gives stops `[A]`.
  - Text: the exact strings above, and every kind's line is non-empty (build one of each, as in Task 4).
  - `repeatedNoneDueLogsOnce`: shouldLog(.noneDue, []) gives true, then false ×100. Then `.busy` with [a] gives true, `.busy` with [a] again false, and `.busy` with [a, b] true. After `reset()`, `.busy` with [a, b] is true.
  - `dueOrderIrrelevant`: [a, b] and then [b, a] with the same reason gives false the second time.
- [ ] **Step 2–4: Run, implement, run all core tests.**
- [ ] **Step 5: Commit** `feat(walklog): summary, map data, timeline text and quiet throttle`.

### Task 6: Log wiring in the app

**Files:**
- Create: `MyGuide/Walking/WalkLog.swift`
- Modify: `MyGuide/AppServices.swift`, `MyGuide/MyGuideApp.swift`, `MyGuide/Walking/WalkingController.swift`, `MyGuide/Walking/WalkingStories.swift`, `MyGuide/Walking/WalkingActivityController.swift`, `MyGuide/Walking/BuzzNotifier.swift`, `MyGuide/Home/HomeScreen.swift` (stop call site if needed)

**Interfaces:**
- Consumes: Tasks 1, 4 and 5.
- Produces (used by Tasks 7 and 8):
  ```swift
  @MainActor final class WalkLog {
      static let directory: URL               // Application Support/WalkLogs (created on demand)
      private(set) var currentURL: URL?       // the run in progress, nil when none
      func begin(runID: UUID, at: Date)       // prune(keep 20, sparing new) then open; failure → os log, no writer
      func log(_ kind: WalkLogEvent.Kind, at: Date = .now)   // no-op without a writer; write failure → os log
      func logQuiet(_ reason: QuietReason, due: [DuePlace], at: Date = .now)   // through QuietThrottle
      func resetQuiet()
      func end()                              // close; currentURL = nil
      /// Runs `post`; logs `notified` (with the settings read after it) or `notifyFailed`; rethrows.
      func posting(_ kind: WalkNotificationKind, id: UUID?, _ post: () async throws -> Void) async throws
  }
  extension BuzzNotifier { static func settingsSnapshot() async -> NotificationSettingsSnapshot }
  WalkingController.stop(reason: WalkStopReason = .user)
  WalkingController.noteScenePhase(_ phase: ScenePhase)
  WalkingStories.walkLog: WalkLog?   // set by WalkingController.init
  WalkingActivityController.onFailure: ((String, Error) -> Void)?
  ```
  **Where each event comes from** (spec 4.2 and 9):
  - `started`: in `start()` right after `isOn = true`, with `log.begin(runID:)` called first using the new `runToken`.
    - Fields: version and build from `Bundle.main` (`CFBundleShortVersionString`, `CFBundleVersion`); the readiness values; `ActivityAuthorizationInfo().areActivitiesEnabled`; motion from `CMMotionActivityManager.isActivityAvailable()` and `.authorizationStatus()` (or `unavailable`); `perHour`; battery (nil when < 0).
  - `stopped`: in `stop(reason:)` before `log.end()`.
    - `onDenied` passes `.locationDenied`, and `checkAutoOff` maps `AutoOffReason` to its stop reason.
    - `HomeScreen`'s stop stays `stop()`, which means `.user`.
  - `app`: `MyGuideApp` reads `@Environment(\.scenePhase)` and calls `.onChange(of: scenePhase) { services.walking.noteScenePhase($1) }` on `HomeScreen`. `.active` maps to foreground, `.background` to background, and `.inactive` is ignored. Only logged while `isOn`.
  - `fix`: in `handle(_:)`, thinned with `TrackSample.isWorthStoring` against `lastLoggedSample`.
    - Fixes dropped by the guard are logged with `dropped`: `.invalid` for accuracy < 0, else `.stale`, only while `isOn`.
    - Speed and course are nil when < 0.
    - `paused` is false until Task 7.
  - `gps`: the controller keeps `loggedGPS: Bool?`. "Found" means `WalkingStatus.text` is not the waiting text, judged at each fix and each timer tick. A line is written on change.
  - `fetchStarted`, `fetched` and `fetchFailed`: in `fetch(around:)`. Cancellation is not logged.
  - `quiet` and `buzz`: `handle(_:)` calls `engine.decide`. `.quiet` goes to `log.logQuiet`; `.buzz` logs `buzz(WalkLogBuzz(buzz))`, calls `resetQuiet()` and then `deliver`.
  - `notified` and `notifyFailed`: every `BuzzNotifier.post*` call site wraps its post in `log.posting(kind:id:)`. The kinds are `.buzz` (deliver), `.more` and `.storyFailed` (stories), `.stop` (deliverStop fallback) and `.autoOff` (checkAutoOff). The existing `logMemoryFailure` calls stay.
  - `busy`: in `WalkingStories.feed`, only when `playback.isBusy` differs from the last logged value.
  - `storyPreparing`, `storyReady` and `storyFailed`:
    - `storyPreparing` is written in `prepare` with `preparedAt[id] = .now`.
    - The other two are written in `endPreparing`, with seconds since `preparedAt`.
    - The error comes from `errors.last { $0.id == id }`. A `CancellationError` gives `"cancelled"`, and an unknown error gives `"unknown"`.
  - `stopDetected`: in `handle(_:)` when the detector fires.
  - `stopStory`: in `prepareStop`.
    - `told` with the title before `ready`.
    - `silent` when the flow returns nil.
    - `failed` with `errorText`; a cancellation gives `"cancelled"`.
  - `stopShown`: in `deliverStop`. `.liveActivity` is logged after `showStop` succeeds, and `.notification` after the fallback post succeeds.
  - `failure`: every `AppServices.logMemoryFailure` call in `WalkingController` and `WalkingStories` goes through a local `fail(_ context: String, _ error: Error)` that also logs `failure`. `WalkingActivityController` calls `onFailure` beside its own `logMemoryFailure`, and the controller wires `onFailure` to `log.log(.failure…)`.

- [ ] **Step 1: Implement the above.** There is no app test target; the core tests cover the logic. Keep each call site small.
- [ ] **Step 2: Unsigned app build passes; core tests pass.**
- [ ] **Step 3: Self-check by reading the diff.**
  - Every event in the spec 4.2 table except `motion`, `paused` and `resumed` (Task 7) has a call site.
  - No story text is logged.
  - Nothing is logged after `stop()` ended the log. `log` is a no-op without a writer, and late tasks hit that.
- [ ] **Step 4: Commit** `feat(walklog): walking mode writes its log`.

### Task 7: Auto-pause in the app

**Files:**
- Create: `MyGuide/Walking/WalkingMotion.swift`
- Modify: `MyGuide/Walking/WalkingLocation.swift`, `MyGuide/Walking/WalkingController.swift`, `MyGuide/Walking/WalkingStatusPill.swift`, `MyGuide/Walking/WalkingActivityController.swift` (if the paused stale date needs a parameter), `project.yml`, `MyGuide/Info.plist` (regenerated by xcodegen)

**Interfaces:**
- Consumes: Tasks 2, 3 and 6.
- Produces:
  ```swift
  @MainActor final class WalkingMotion {
      static var permission: MotionPermission { get }     // unavailable when !isActivityAvailable()
      func requestPermissionIfNeeded() async               // notDetermined + available → one queryActivityStarting(from: now−60, to: now, to: .main) and await its callback
      func start(_ onReading: @escaping (MotionReading) -> Void)   // startActivityUpdates(to: .main); maps CMMotionActivity → MotionActivity by priority automotive > cycling > running > walking > stationary > unknown
      func stop()
  }
  WalkingLocation.setPaused(_ paused: Bool)   // true: kCLLocationAccuracyHundredMeters, distanceFilter 50; false: kCLLocationAccuracyBest, kCLDistanceFilterNone
  WalkingController.isPaused: Bool            // observable
  ```
  **Controller changes:**
  - **Start:** call `await motion.requestPermissionIfNeeded()` after the notification prompt and before `location.requestAlways()`. Re-check `startToken` after it. Then create `PauseDetector(now:, motionAvailable: WalkingMotion.permission == .authorized)`, set `pausedTotal = 0` and `pausedSince = nil`, start the motion updates and keep the run's stop spots in `stopSpots`.
  - **Motion reading:** log `motion` only when the activity or confidence changed. Feed `detector.motion(isWalking:at:)` and apply the change.
  - **Timer:** one 15 s loop replaces the 60 s one, with a tick counter. Every tick runs `detector.tick(now:)`, applies it and runs the GPS state check. Every 4th tick runs `checkAutoOff` and `refreshActivity`.
  - **`handle(_:)`:**
    - While paused: after the fresh/valid guard, feed `detector.fix`, log the fix (thinned, `paused: true`), apply the change, and return. Nothing else runs: no engine, feed, stop detector, track, route or `lastFixAt`.
    - While active: feed `detector.fix` after the existing work and apply the change.
  - **`enterPause(trigger:anchor:)`:**
    - `isPaused = true`, `pausedSince = now`;
    - `location.setPaused(true)`;
    - log `paused`, `resetQuiet()`;
    - `refreshActivity` with paused text and `WalkingStatus.pausedStaleDate`.
  - **`leavePause(trigger:)`:**
    - `pausedTotal += now − pausedSince`, `isPaused = false`;
    - `location.setPaused(false)`;
    - `resetRoute()`; `stopDetector = StopDetector(previousStops: stopSpots)`; `lastTrackSample = nil`; `loggedGPS = nil`;
    - log `resumed` with the paused seconds, `resetQuiet()`, `refreshActivity`.
  - **`tellStop`** appends the spot to `stopSpots`.
  - **`checkAutoOff`** uses `AutoOff.activeTime(startedAt:now:pausedTotal:pausedSince:)` and `pausedFor: pausedSince.map { now − $0 }`. `.pausedTooLong` maps to the stop reason `.pausedTooLong` and posts its message.
  - **`refreshActivity`** passes `paused: isPaused`. While paused the stale date is `WalkingStatus.pausedStaleDate(now:)`.
  - **Pill** passes `paused: controller.isPaused`.
  - **`stop`** calls `motion.stop()`, sets `location.setPaused(false)` and `isPaused = false`, and clears the pause state.
  - **`project.yml`:** add `NSMotionUsageDescription: "MyGuide notices when you stop and start walking, so walking mode can pause itself and save battery."` beside the other usage strings of the phone target.

- [ ] **Step 1: Implement. Step 2: `xcodegen generate`; the unsigned app build passes; core tests pass. Check that `Info.plist` contains `NSMotionUsageDescription`.**
- [ ] **Step 3: Self-check by reading the diff.**
  - While paused, no fetch, buzz, stop detection, track or route update.
  - The pause state is cleared in `stop`.
  - The timer is cancelled in `stop`, and a tick from an old run returns (runToken check).
  - A motion reading after stop is ignored (`isOn` check).
- [ ] **Step 4: Commit** `feat(walking): auto-pause and resume on motion and GPS`.

### Task 8: Walk log screens

**Files:**
- Create: `MyGuide/Settings/WalkLogListView.swift`, `MyGuide/Settings/WalkLogRunView.swift`
- Modify: `MyGuide/Settings/SettingsView.swift` (a `NavigationLink("Walk log")` right after "Buzz log"), `MyGuide/AppServices.swift` (expose `walkLog` if needed)

**Interfaces:**
- Consumes: `WalkLog.directory`, `WalkLog.currentURL` (Task 6); `WalkLogStore.runFiles`, `WalkLogReader`, `WalkLogSummary`, `WalkLogMapData`, `WalkLogText` (Tasks 4 and 5).

**Behaviour** (spec 4.5, 6):
- **The list:**
  - It reads files off the main thread with `Task.detached`, then reads and summarises each.
  - Each row shows the date, the time span `HH:mm–HH:mm`, the duration, the distance (`m` under 1 000, else `x.x km`) and `N buzzes`.
  - Red text shows "Ended without a stop" when `stopReason == nil` and it is not the current run, or `N failures` when the count is non-zero.
  - The current run shows "In progress" and has no delete action. Other rows delete their file on swipe.
  - A file that fails to read shows "Unreadable" and can still be deleted and opened, with an empty map.
  - With no files: "No walks logged yet".
- **The run:**
  - A `Map` 300 pt high shows:
    - a `MapPolyline` per path segment;
    - grey circles for places;
    - orange markers for buzzed places;
    - blue markers for stops;
    - `pause.circle` annotations for pauses.
  - The camera fits all points.
  - A summary section shows the distance, duration, fetches with failures, places, buzzes, notifications, failures, pauses, the stop reason or "Ended without a stop", and "N unreadable lines" when non-zero.
  - The timeline uses `LazyVStack` or `List` rows with local `HH:mm:ss` and `WalkLogText.line`. Failures are in red.
  - A "Hide fixes" toggle defaults to on.
  - `ShareLink(item: url)` sits in the toolbar.

- [ ] **Step 1: Implement. Step 2: Unsigned app build passes.**
- [ ] **Step 3: Commit** `feat(walklog): walk log list and run screens`.
