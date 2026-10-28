# Guided Walk Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The owner can start, pause, resume and stop the guided walk from the watch. The phone also gets a manual pause, both devices always show the same state, and each walk is saved in Health as an Outdoor Walk without watch GPS.

**Architecture:** The pure rules live in `MyGuideCore` with Swift Testing:
- the walk state, its labels and its plist codec;
- how each command acts on each phase, and the ordering by `sentAt`;
- the detector's hold and release;
- the status texts;
- the log fields.

The phone's `WalkingController` gains manual pause and a non-interactive start, and publishes `GuidedWalkState` through `WatchLink`. The watch app gets a `GuidedWalkModel` that owns the workout and mirrors the phone.

**Tech Stack:** Swift 6 strict concurrency, iOS 26 and watchOS 26, SwiftUI, WatchConnectivity, HealthKit (`HKWorkoutSession`, `HKLiveWorkoutBuilder`, `startWatchApp`), XcodeGen, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-28-guided-walk-controls-design.md`. Section 10 is binding and overrides the earlier sections where they differ.

## Global Constraints

- Swift 6 language mode, strict concurrency. No new package dependencies.
- Every WatchConnectivity and HealthKit callback is a nonisolated `@Sendable` closure or a nonisolated delegate method that hops to the main actor. A closure written inside a `@MainActor` type and handed to WC or HK traps at run time (crash fixed in a7da837).
- The phone holds the truth. The watch applies a state only when its `sentAt` is newer than the last one it applied.
- Exact watch labels: "Off", "Starting…", "Walking · N buzz/buzzes", "Paused · not moving", "Paused".
- Exact phone texts:
  - "Walking · N buzz/buzzes" and "Walking · waiting for GPS" are unchanged.
  - Manual pause: "Paused · N buzz/buzzes".
  - Auto-pause: "Paused · not moving · N buzz/buzzes".
- Exact problem texts:
  - "Open MyGuide on your phone to finish setting up." (phone, non-interactive start);
  - "Phone not reachable. Open MyGuide on your phone." (watch);
  - "Not saved to Health";
  - "Workout ended".
- Message types: `walk.start`, `walk.pause`, `walk.resume`, `walk.stop`. The state message type is `walk.state`.
- Workouts shorter than 60 s of `builder.elapsedTime` are discarded; longer ones are saved.
- No GPS or location permission on the watch.
- Core test command: `cd Packages/MyGuideCore && swift test`.
- Unsigned app build: `xcodegen generate && xcodebuild -project MyGuide.xcodeproj -scheme MyGuide -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/claude-501/-Users-birger-code-MyGuide/43e8ac03-ea1c-4b4d-b907-cc5e890c10a9/scratchpad/dd -quiet CODE_SIGNING_ALLOWED=NO build`. This builds the embedded watch app too. Never write `build/` in the repo.
- Hand computations sit above numeric assertions. Complete code, no TODOs. Commit per task with a conventional message and your system's attribution trailer. Never push.

## Review Focus

1. **A manual pause must survive walking.** Motion or GPS input to a held detector changes nothing. Task 2 test `heldDetectorIgnoresWalkingAndFarFixes`.
2. **A stale state must never overwrite a newer one on the watch.** For example, a reply that arrives after a newer context. Task 1 test `olderSentAtIsNotApplied`.
3. **An old walk log without `source` still decodes.** Task 2 test `oldLinesWithoutSourceDecode`.
4. **An auto pause that becomes manual is one pause, not two.** Summary pauses = 1, and `pausedSince` is unchanged. Task 2 test `pausedThenPausedCountsOnce`, plus a Task 3 self-check.
5. **Start from the background never awaits a prompt.** Task 3 self-check: list every `await` on the non-interactive path.

---

### Task 1: Guided walk state, commands and labels (core)

**Files:**
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/GuidedWalk.swift`
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/GuidedWalkTests.swift`

**Interfaces (produces):**
```swift
public enum GuidedWalkPhase: String, Sendable, Codable { case off, starting, walking, pausedAuto, pausedManual }
public struct GuidedWalkState: Sendable, Equatable {
    public var phase: GuidedWalkPhase; public var buzzCount: Int
    public var startedAt: Date?; public var pausedTotal: TimeInterval; public var pausedSince: Date?
    public var problem: String?; public var sentAt: Date
    public static func off(sentAt: Date, problem: String? = nil) -> GuidedWalkState
    public var label: String                                  // spec 4 table
    public func activeTime(now: Date) -> TimeInterval         // 0 when off; (now − startedAt) − pausedTotal − current pause; never < 0
    public var message: [String: Any]                         // plist: "type": "walk.state" + fields; dates as Double since 1970; nil fields omitted
    public init?(message: [String: Any])                      // nil when type ≠ "walk.state" or a required field is missing/wrong
    public func isNewer(than other: GuidedWalkState?) -> Bool // other nil → true; else sentAt > other.sentAt
}
public enum GuidedWalkCommand: String, Sendable { case start = "walk.start", pause = "walk.pause", resume = "walk.resume", stop = "walk.stop"
    public init?(message: [String: Any]) }
public enum GuidedWalkAction: Sendable, Equatable { case start, pauseManual, resume, stop, none }
extension GuidedWalkCommand { public func action(in phase: GuidedWalkPhase) -> GuidedWalkAction }
```
**Action table (spec 4):**

| Command | off | starting | walking | pausedAuto | pausedManual |
|---|---|---|---|---|---|
| start | start | none | none | none | none |
| pause | none | none | pauseManual | pauseManual | none |
| resume | none | none | none | resume | resume |
| stop | none | stop | stop | stop | stop |

- [ ] **Step 1: failing tests.**
  - `labels`: every phase's label. Walking with 1 buzz gives "Walking · 1 buzz"; with 2, "Walking · 2 buzzes".
  - `activeTimeSubtractsPauses`: startedAt t0, now t0+1000, pausedTotal 100, pausedSince t0+900. Hand computation: 1000 − 100 − 100 = 800. Off gives 0. A clock step back gives 0.
  - `messageRoundTrip`: a state with all fields, and one with nil fields; `init?(message:)` of its message gives an equal state (dates via `timeIntervalSince1970`).
  - `wrongTypeOrMissingFieldIsNil`.
  - `olderSentAtIsNotApplied`: `isNewer` is false for an equal or older `sentAt`, and true for nil.
  - `actionTable`: all 20 cells.
  - `commandParsing`: `["type": "walk.pause"]` gives `.pause`; an unknown type gives nil.
- [ ] **Step 2: run, expect failure. Step 3: implement. Step 4: run all core tests.**
- [ ] **Step 5: commit** `feat(walking): guided walk state, commands and labels`.

### Task 2: Detector hold, status texts, log fields (core)

**Files:**
- Modify: `Walking/PauseDetector.swift`, `Walking/WalkingStatus.swift`, `WalkLog/WalkLogEvent.swift`, `WalkLog/WalkLogCodec.swift`, `WalkLog/WalkLogSummary.swift`, `WalkLog/WalkLogText.swift`
- Tests: `PauseDetectorTests`, `WalkingStatusTests`, `WalkLogEventTests`, `WalkLogSummaryTests`, `WalkLogTextTests` (add or adjust)

**Interfaces (produces):**
```swift
extension PauseDetector { public private(set) var isHeld: Bool
    public mutating func hold()                 // inputs → nil, state unchanged
    public mutating func release(now: Date) }   // isHeld = false, isPaused = false, pausedSince = nil, stillStart = now, anchor = nil, pauseAnchor = nil
public enum WalkingPauseKind: Sendable { case auto, manual }
WalkingStatus.text(isOn: Bool, lastFixAt: Date?, buzzCount: Int, now: Date, pause: WalkingPauseKind? = nil) -> String?
//   manual → "Paused · N buzz/buzzes"; auto → "Paused · not moving · N buzz/buzzes"; replaces `paused: Bool`
public enum WalkPauseReason: String, Sendable, Codable { case motion, gps, manual }
    // init(_ trigger: PauseTrigger)
public enum WalkSource: String, Sendable, Codable { case phone, watch }
WalkLogEvent.Kind: .stopped(WalkStopReason, source: WalkSource?), .paused(WalkPauseReason, at: Coordinate?, source: WalkSource?),
                   .resumed(WalkPauseReason, pausedSeconds: Double, source: WalkSource?)
WalkLogStart gains `source: WalkSource?` (JSON key "source", omitted when nil)
```
- [ ] **Step 1: failing tests.**
  - `heldDetectorIgnoresWalkingAndFarFixes`: hold at t0, then `motion(true)` at t0+1, ticks to t0+500, and a fix 500 m away. All give nil, and `isPaused` is unchanged.
  - `releaseRestartsStretch`: released at t0+100; tick t0+279 gives nil, and t0+280 gives pause. Hand computation: 100 + 180 = 280.
  - `releaseFromAutoPauseClearsPaused`.
  - Status texts: manual 1 buzz gives "Paused · 1 buzz"; auto 2 buzzes gives "Paused · not moving · 2 buzzes"; not paused stays as before. Update the existing paused tests.
  - Codec:
    - `oldLinesWithoutSourceDecode`: literal old `paused` and `resumed` lines with reason "motion", `stopped`, and `started` decode with source nil.
    - `manualReasonAndSourceRoundTrip`.
    - `sourceOmittedWhenNil`: the key is absent.
  - `pausedThenPausedCountsOnce`: paused(motion), then paused(manual), then resumed gives a summary of pauses 1, and the path is split once.
  - Text: `paused(.manual, …)` gives "Paused (manual)"; with source watch, "Paused (manual, watch)".
- [ ] **Step 2–4: run, implement, run all core tests.** Fix every call site in the app target that the changed cases and signatures break, keeping behaviour. The app build must pass.
- [ ] **Step 5: commit** `feat(walking): detector hold, pause kinds in status and log`.

### Task 3: Phone controller: manual pause, non-interactive start, published state

**Files:** `MyGuide/Walking/WalkingController.swift`, `MyGuide/Walking/WalkingStatusPill.swift`, `MyGuide/Home/HomeScreen.swift`

**Interfaces (produces):**
```swift
WalkingController:
  private(set) var isStarting: Bool          // observable; true from the start's first line until it returns
  private(set) var pauseKind: WalkingPauseKind?   // replaces isPaused (keep `var isPaused: Bool { pauseKind != nil }`)
  func start(source: WalkSource = .phone, interactive: Bool = true) async -> String?   // returns the problem, nil when started or already on
  func stop(reason: WalkStopReason = .user, source: WalkSource? = .phone)
  func pause(source: WalkSource)             // GuidedWalkAction.pauseManual
  func resume(source: WalkSource)            // GuidedWalkAction.resume
  var guidedWalkState: GuidedWalkState { get }   // computed from isOn/isStarting/pauseKind/buzzCount/startedAt/pausedTotal/pausedSince/problems, sentAt = .now
  var onStateChange: ((GuidedWalkState) -> Void)?   // called after every change that alters the state's fields except sentAt
```
**Behaviour (spec 4, 5.1, 5.3, 10.1–10.4, 10.11):**
- `interactive: false`:
  - Return "Open MyGuide on your phone to finish setting up." when location ≠ `.always`, notifications ≠ `.allowed`/`.timeSensitiveOff`, or there is no key. Do this before any await on a prompt.
  - Skip `requestWhenInUse`, the notification request, the motion request and `requestAlways`.
  - The Live Activity start may fail (background), which is fine.
- **Manual pause:**
  - From walking: `enterPause` with kind manual, then `pauseDetector.hold()`. Log `paused(.manual, at: current anchor or nil, source:)`.
  - From auto: kind becomes manual, `pausedSince` is kept, `hold()` is called, and one `paused(.manual…)` line is written. Push the activity and the state.
- **Resume** (either kind): `leavePause`, then `pauseDetector.release(now:)`. Log `resumed(reason, …, source:)`, where the reason is `.manual` from a manual pause, else the last auto trigger.
- While held, detector output is ignored. That is already guaranteed by `hold`, but also guard `applyPause` on `pauseKind != .manual`.
- `refreshActivity` and the pill pass `pause: pauseKind`.
- **Home screen:** a pause/play circle button next to the walk button while `isOn`. It shows `pause.fill` when walking and `play.fill` when paused, with accessibility labels "Pause walk" and "Resume walk". It calls `pause(source: .phone)` or `resume(source: .phone)`.
- `started` gets `source`, and `stopped` gets `source` (nil for automatic stops: auto-off, location denied).

- [ ] **Step 1: implement. Step 2: unsigned app build and core tests pass.**
- [ ] **Step 3: self-check (report).**
  - List every `await` on the `interactive: false` path.
  - Show that `onStateChange` fires on start, stop, pause, resume, auto-pause, auto-resume, a buzz count change and a start failure.
  - Show that an auto → manual switch keeps `pausedSince`.
- [ ] **Step 4: commit** `feat(walking): manual pause and a start without prompts`.

### Task 4: Phone ↔ watch link and HealthKit launch

**Files:** `MyGuide/Watch/WatchLink.swift`, `MyGuide/AppServices.swift`, `project.yml` (phone entitlement `com.apple.developer.healthkit: true`; no Health usage strings needed, since no health data is read), `MyGuide/MyGuide.entitlements` (regenerated)

**Interfaces (produces):**
```swift
WatchLink:
  var onCommand: (@MainActor ([String: Any]) async -> [String: Any])?   // async; reply sent when it returns
  func pushState(_ state: [String: Any])     // updateApplicationContext; when not activated, remembered and pushed on activation
```
**Behaviour:**
- `didReceiveMessage(_:replyHandler:)`:
  - "ping" still answers "pong".
  - Any other message runs `onCommand` in a main-actor Task, and the result is passed to the reply handler, which is captured as a nonisolated `@Sendable` box.
  - "check.tell" still goes to `walkingCheck`.
- **AppServices:**
  - `walking.onStateChange = { watchLink.pushState($0.message) }`.
  - At launch, after `activate()`, push `walking.guidedWalkState.message`.
  - `onCommand`: parse `GuidedWalkCommand`, then `action(in: walking.guidedWalkState.phase)`:
    - `start`: reply at once with `starting` (phase `.starting`). Run `start(source: .watch, interactive: false)` in a Task. A returned problem is pushed as an `off` state with that problem.
    - `pauseManual` or `resume`: call it and reply with the state.
    - `stop`: `stop(reason: .user, source: .watch)` and reply with the state.
    - `none`: reply with the current state.
- **startWatchApp:** on a phone start (`source == .phone`) that succeeded, `HKHealthStore().startWatchApp(with:)` with an outdoor walking configuration. The completion is a nonisolated `@Sendable` closure. On failure, `walkLog.log(.failure(context: "watch app launch failed", …))` on the main actor.

- [ ] **Step 1: implement. Step 2: unsigned build plus core tests.**
- [ ] **Step 3: self-check:** every WC and HK closure is `@Sendable` or nonisolated.
- [ ] **Step 4: commit** `feat(watch): phone answers guided walk commands and pushes its state`.

### Task 5: Watch app: guided walk screen and workout

**Files:**
- Create: `MyGuideWatch/GuidedWalkModel.swift`, `MyGuideWatch/GuidedWalkView.swift`, `MyGuideWatch/WatchAppDelegate.swift`
- Modify: `MyGuideWatch/WorkoutKeeper.swift`, `MyGuideWatch/PhoneLink.swift`, `MyGuideWatch/MyGuideWatchApp.swift`, `MyGuideWatch/WatchCheckView.swift` (it becomes the "Check" screen; its own test button keeps working with its own `WorkoutKeeper` instance, which discards)

**Interfaces:**
```swift
WorkoutKeeper:
  func ensureRunning() async throws     // idempotent; a concurrent call awaits the same start
  func adopt(_ session: HKWorkoutSession)   // recovered or delegate-started session
  func pause(); func resume()
  func finish() async -> Bool           // saves when builder.elapsedTime ≥ 60, else discards; returns saved
  var onEnded: (@MainActor () -> Void)? // the session ended or failed from outside (HKWorkoutSessionDelegate, nonisolated)
  // authorization: share workoutType; read heartRate, activeEnergyBurned, distanceWalkingRunning
PhoneLink: var onState: (@MainActor ([String: Any]) -> Void)?   // didReceiveApplicationContext + receivedApplicationContext at activation
@MainActor @Observable final class GuidedWalkModel {
  var state: GuidedWalkState?; var pending: GuidedWalkCommand?; var error: String?; var healthNote: String?
  func send(_ command: GuidedWalkCommand) async
  func apply(_ state: GuidedWalkState)  // only if isNewer; then syncWorkout()
}
```
**Behaviour (spec 6, 10.6–10.8, 10.10, 10.13–10.15):**
- **`send`:**
  - Sets `pending`, applies the workout effect at once (start: `ensureRunning`; pause; resume; stop: `finish`), then sends.
  - The reply goes to `apply`.
  - `PhoneLinkError.notReachable` sets the error "Phone not reachable. Open MyGuide on your phone." and rolls the workout back to the last applied state.
- **`syncWorkout`:**
  - `walking`: ensure running, and resume if paused.
  - `pausedAuto` or `pausedManual`: pause.
  - `off`: finish.
  - `starting`: nothing.
  - An authorization refusal or start failure sets `healthNote` to "Not saved to Health", and the walk state still shows.
  - `onEnded` sets `healthNote` to "Workout ended" and does not restart until the next Start command.
- **View:**
  - The label is large, and the active time (`TimelineView` per second, `h:mm:ss`) only when the walk is not off.
  - Buttons per phase (spec 6.1). They are disabled while `pending`, and the label then shows "Starting…", "Pausing…", "Resuming…" or "Stopping…".
  - `error` in orange; `healthNote` in secondary text; a "Check" `NavigationLink` at the bottom.
- **Delegate** (`@WKApplicationDelegateAdaptor`):
  - `handle(_ workoutConfiguration:)` starts the workout through the model (`ensureRunning`).
  - `handleActiveWorkoutRecovery()` calls `HKHealthStore().recoverActiveWorkoutSession` (nonisolated completion) and then `adopt`.
- `TellMeIntent` is unchanged.

- [ ] **Step 1: implement. Step 2: unsigned build (includes the watch) plus core tests.**
- [ ] **Step 3: self-check:**
  - Every HK and WC callback is nonisolated or `@Sendable`.
  - Two near-simultaneous starts (delegate plus context) give one session.
  - `finish` is never called twice for one session.
- [ ] **Step 4: commit** `feat(watch): guided walk screen controls the phone and records the walk`.
