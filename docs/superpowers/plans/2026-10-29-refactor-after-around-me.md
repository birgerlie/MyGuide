# Refactoring after «Rundt deg» — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Remove the duplicated mechanisms and string-keyed logic found by the codebase audit, without changing
behaviour.

**Architecture:**
- Shared mechanisms (deadline race, compass point, direction bands, walking problems, pause bookkeeping) move into
  MyGuideCore with tests.
- The app's four background-task helpers become one.
- Dead code goes.

**Spec:** none. This is a no-behaviour-change refactor. The binding requirement is that observable behaviour stays
the same, except the bug fixes named below (watch language rule, walking check activity language, Keychain error
logged). The audit report is the source; its findings are copied into each task.

## Global Constraints

- Swift 6 strict concurrency; MyGuideCore tests via `cd Packages/MyGuideCore && swift test` stay green (1266 now).
- App build:
  `xcodebuild -project MyGuide.xcodeproj -scheme MyGuide -destination 'generic/platform=iOS' -derivedDataPath /tmp/mg-dd -quiet build`,
  expected to have no `error:` lines.
- No change to user-visible text or behaviour unless a task names it. Walk-log line formats unchanged. Wire formats
  between phone and watch unchanged (older builds keep working).
- Closures handed to UIKit/system callbacks are built nonisolated and hop to the MainActor explicitly.
- Tests cover boundaries, with hand computations in comments for numeric assertions. Complete implementations
  only.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push.

## Review Focus

1. Expiry of a background task during story preparation and «Mer» must still cancel the work and surface the
   failure. This is a device check; the reviewer verifies it by reading the code.
2. The deadline race: a caller cancelled while the work ignores cancellation returns at once, and a late result is
   dropped. Tested in R1.
3. The direction-band boundaries stay exactly as today (BuzzText says "right" at 150° while RelativeDirection says
   behind-right; both say ahead at ±30). Tested in R2.
4. WalkingProblem rawValues equal today's English sentences, so the watch wire format is unchanged. Tested in R2.
5. Pause bookkeeping: an auto pause turning manual keeps `pausedSince`, and `pausedTotal` sums across pauses.
   Tested in R3.

---

### Task R1: one background-task helper, one deadline race (app + core)

**Files:**
- `MyGuide/Platform/BackgroundTaskHold.swift`
- `MyGuide/Walking/WalkingStories.swift` (BackgroundWork, ~762-780)
- `MyGuide/Story/StoryViewModel.swift` (~564-599)
- `MyGuide/WalkingCheck/WalkingCheckModel.swift` (~364-381)
- new `Packages/MyGuideCore/Sources/MyGuideCore/Concurrency/Deadline.swift`
- `GroundingService.swift` (~79-165)
- `MyGuide/Walking/WalkingController.swift` (`address` + `OnceBox`, ~1068-1116)
- `MyGuide/Walking/WalkingMotion.swift` (~41)
- tests

**Steps:**
- [ ] `BackgroundTaskHold.begin(name:onExpire:)`, where `onExpire: @MainActor @Sendable () -> Void`. The expiration
      handler is built in a nonisolated static and hops to the MainActor. Use it at all four sites; delete the
      other three helpers. Expiry behaviour at each site stays the same.
- [ ] Move `withTimeout`, `abandoningOnCancel` and `ResumeOnce` from GroundingService into public `Deadline.swift`.
      GroundingService uses them from there. Add a public non-throwing helper,
      `Deadline.value(within: Duration, _ work: @Sendable () async -> T?) async -> T?`.
- [ ] WalkingController's address lookup and WalkingMotion use Deadline. Delete `OnceBox`, or make it a thin
      wrapper only if WalkingMotion needs a sync-callback bridge; say which in the report. The geocode timeout
      constant is defined once (`GroundingService.defaultGeocoderTimeout`).
- [ ] Core tests for Deadline: work wins; timeout wins; caller cancelled while the work ignores cancellation
      returns promptly; a late result is dropped.
- [ ] Core suite and app build. Commit `refactor: one background-task helper and one deadline race`.

### Task R2: compass, direction bands, walking problems, watch language, small fixes (core + app + watch)

**Steps:**
- [ ] **CompassPoint.** Add a `CompassPoint` enum in core with `init(degrees:)`, `promptWord` (today's English
      word), `words(_ language)` and `abbreviation`. Then:
  - `FieldOfView.compassPoint` returns `.promptWord`;
  - replace `ScreenText.norwegianCompass` (StoryViewModel.swift ~786-789) and `CaptureHUD.abbreviatedCompassPoint`
    (CaptureHUD.swift ~12-17) with it;
  - tests: all 8 points in both languages and the edges 22.4/22.5, 337.5, −10, 360.
- [ ] **Direction bands.**
  - Add `GeoMath.signedOffset(from:to:)` in (−180, 180]. Use it at PlaceSelector.offset, BuzzText, GuideText,
    FieldOfView, CaptureHUD and PhoneHeading, wherever they compute a wrapped difference. Keep each call site's
    semantics.
  - `GuideText.side` becomes `RelativeDirection(offset:).promptWord`, with the strings unchanged.
  - `BuzzText.detail` computes a `BuzzSide` enum (ahead/right/left/behind/away). `localizedDetail` renders from the
    enum, not from English suffixes.
  - Boundary tests at ±30, ±60, ±120, ±150 and 180 for all three, pinning today's results (BuzzText "right" at 150;
    RelativeDirection behindRight at 150).
- [ ] **WalkingProblem.**
  - Add `enum WalkingProblem: String` in core. Its rawValue is today's English sentence.
  - `WalkingReadiness.problems` returns `[WalkingProblem]`. The phone sends the rawValue to the watch as today.
  - Text comes from `text(_ language)`, an exhaustive switch. An unknown string from an older peer is shown as
    received.
  - Fix the doc comment (screen language).
  - Update AroundSheet (~171) and WatchDesign (~76).
  - Tests: rawValues equal today's sentences; nb and en texts; unknown passthrough.
- [ ] **Watch screen language.** WatchDesign (~39) uses
      `StoryLanguage.screen(bundleLocalization: Bundle.main.preferredLocalizations.first, preferredLanguages:)`.
      Fix the comment.
- [ ] **Fresh fix.** Add `WalkingStatus.hasFreshFix(lastFixAt:now:)` in core and use it in `text()` and in
      WalkingController.noteGPS (~742-748) instead of comparing strings. Tests: age == staleAfter is fresh;
      +0.001 is not; nil is not.
- [ ] **Message constants.** Move `"check.tell"`, `"ping"` and `"pong"` to core constants beside GuidedWalk's
      messages, and use them on both sides. TellMeIntent's stale comment is corrected to say what it does today:
      it drives the walking-check tone. Its user-facing behaviour is unchanged; rewiring it is an owner decision,
      so list it in the report.
- [ ] **ScreenText.** Move `ScreenText` from StoryViewModel.swift into `MyGuide/Story/StoryTexts.swift`. No content
      change.
- [ ] **Dead code.** Delete `MemoryStore.placeIDsBuzzed` (WalkMemory.swift ~122) with its tests,
      `StoryPath.underneath` (LatestStory.swift ~91) with its tests, and `AppServices.makeWalkingFlow` (~378).
      Verify no callers with grep first.
- [ ] **Stale comments.** Fix WalkLog.swift (~52, "from Task 7"). Add a DEBUG
      `assert(WalkingActivityAttributes.storyURL(id) == WalkLink.url(for: id))` at app launch with a fixed UUID.
- [ ] **Walking check Live Activity.** WalkingCheckModel (~297) passes `language: UILanguage.current.rawValue` to
      the attributes.
- [ ] **API key check.** `hasAPIKey` (AppServices ~87) logs a Keychain error instead of silently treating it as no
      key. The result is still false on error.
- [ ] Core suite and app build. Commit in 2–3 logical commits.

### Task R3: pause bookkeeping into core (core + app)

**Steps:**
- [ ] Add a core value type `WalkPauseState`. It takes over pauseKind, pausedSince, pausedTotal, autoPauseTrigger,
      enterPause/leavePause and the resume-reason choice, from WalkingController ~486-600. Its mutating methods
      return effects (`log(WalkLogEvent.Kind)`, `resetRoute`, `refreshActivity`), and the controller applies them.
- [ ] WalkingController uses it, keeping the same log lines in the same order.
- [ ] Core tests:
  - an auto pause turning manual keeps `pausedSince`;
  - `pausedTotal` sums two pauses (hand-computed);
  - resume reason motion vs manual vs watch source;
  - leaving a pause that never started does nothing.
- [ ] Core suite and app build. Commit `refactor(walking): pause bookkeeping as a tested core value`.
