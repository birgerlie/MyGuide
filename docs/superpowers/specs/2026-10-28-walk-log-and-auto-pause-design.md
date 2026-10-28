# MyGuide: Walk log and auto-pause — design

**Status:** approved in chat 2026-10-28 ("det virker fornuftig nå"). Items marked *(Claude's call)* are open for the owner to change.
**Builds on:** branch `guide-voice` (walking mode with the guide voice), not on `diary-and-day-story`.

## 1. Why

On a walk on 2026-10-28 the owner got no buzzes or notifications, and nothing on the phone could tell why. Walking mode logs almost nothing: a few `os.Logger` lines for memory failures, and the buzz log, which only lists buzzes that were sent.

The owner's words: "vi må lage en logg for hvor vi går og hva systemet finner og hva det gir notifications på".

The owner also asked for an auto-pause: "if we don't sense any acceleration or movement for a few minutes we can pause the trip and resume if we have acceleration or consistent movement from the accelerometer in more than one minute".

Leads the log must be able to confirm or rule out:
- The buzz engine stays busy because a story never finishes preparing or playing (`BuzzEngine.isBusy` blocks every buzz).
- Walking mode had already turned itself off (the 4-hour limit counts from the start).
- The app was ended or crashed in the background.
- Overpass fetches failed, so there were no places.
- Notifications were refused by iOS.

## 2. Goals, non-goals, anti-goals

**Goals**
1. A per-walk log on the phone that shows where the owner walked, what the app found, why it stayed quiet, what it notified about, and what failed.
2. The log survives a crash or a killed app, up to the last event written.
3. The owner can see a walk on a map with a timeline, and share the raw file with Claude for analysis.
4. Walking mode pauses itself when the owner has not moved for 3 minutes and resumes when they walk on.

**Non-goals**
- Uploading logs anywhere. Sharing is a manual share-sheet action.
- Logging photo stories or the diary.
- Changing how buzzes are chosen (beyond reporting why there was none).
- The watch.

**Anti-goals**
- A log so noisy it is useless. Repeated "quiet" decisions are logged only when they change (4.3).
- Logging that can break or slow walking mode. A write failure is logged to `os.Logger` and dropped.
- The API key, or any request or response body, in the log.
- Pausing while the owner is walking slowly or standing at a crossing for a minute.

## 3. Constraints

- Swift 6 strict concurrency, iOS 26, SwiftUI, Swift Testing in `MyGuideCore`, complete implementations, no TODOs.
- No SwiftData change. The log is plain files.
- Pure logic (event model, file format, summaries, pause rules, quiet reasons) lives in `MyGuideCore` and is unit-tested. The app layer only wires CoreLocation, CoreMotion, files and UI.
- App UI text is English, like the rest of the app.

## 4. The walk log

### 4.1 Storage

- One file per run (start to stop): `Application Support/WalkLogs/<yyyyMMdd-HHmmss>-<runID>.jsonl`, in the phone's time zone for the name.
- JSON Lines: one JSON object per line, each written and flushed when the event happens (`FileHandle` append). A crash loses at most the line being written.
- The newest **20** files are kept. Older ones are deleted when a new run starts *(Claude's call)*.
- A write failure is logged with `os.Logger` (category `walklog`) and the event is dropped. Walking mode carries on.
- Reading tolerates a truncated or unreadable line: it is skipped and counted, and the count is shown.

### 4.2 Events

Every line has `"t"` (ISO 8601 with fractional seconds, UTC) and `"e"` (the event name). Coordinates are rounded to 6 decimals, distances to whole metres, seconds to one decimal.

| Event | Fields | When |
|---|---|---|
| `started` | app version and build, location (`always`/`whenInUse`/`denied`/`notDetermined`), notifications (`allowed`/`denied`/`notDetermined`), liveActivities (bool), motion (`authorized`/`denied`/`restricted`/`notDetermined`/`unavailable`), perHour, battery (0–1 or null) | walking mode started |
| `stopped` | reason: `user`, `timeLimit`, `lowBattery`, `pausedTooLong`, `locationDenied` | walking mode stopped |
| `app` | state: `foreground` or `background` | scene phase changes during a run |
| `fix` | lat, lon, accuracy, speed (null when unknown), course (null when unknown), paused (bool) | the same thinning as the stored track: one per 5 m or per minute (`TrackSample.isWorthStoring`) |
| `gps` | state: `found` or `lost` | `WalkingStatus` changes between waiting-for-GPS and having GPS |
| `fetchStarted` | lat, lon | an Overpass/Wikipedia fetch starts |
| `fetched` | count, top, good, wikiOnly, places: [{id, name, tier, lat, lon}] | a fetch succeeded |
| `fetchFailed` | error | a fetch failed (not a cancellation) |
| `quiet` | reason (4.3), due: [{name, tier, distance}] | the engine decided not to buzz, and the reason or the set of due place ids changed since the last `quiet` or buzz |
| `buzz` | id, placeID, name, tier, distance, override (bool), detail | a buzz was chosen |
| `notified` | id, kind (`buzz`/`stop`/`autoOff`) | a notification was added |
| `notifyFailed` | id (null for auto-off), kind, error | adding a notification failed |
| `busy` | busy (bool) | the story engine's busy flag changes |
| `storyPreparing` | id | a buzz story starts preparing |
| `storyReady` | id, seconds | the buzz story is ready, with the time since `storyPreparing` |
| `storyFailed` | id, seconds, error | the buzz story failed or was cancelled |
| `stopDetected` | lat, lon | the stop detector reported a stop |
| `stopStory` | outcome: `told`/`silent`/`failed`, title (when told), error (when failed) | the stop story ended |
| `stopShown` | via: `liveActivity` or `notification` | a told stop story reached the owner |
| `motion` | activity (`stationary`/`walking`/`running`/`automotive`/`cycling`/`unknown`), confidence (`low`/`medium`/`high`) | the reported activity or confidence changed |
| `paused` | reason: `motion` or `gps`, lat, lon (null when no fix) | walking mode paused (5) |
| `resumed` | reason: `motion` or `gps`, pausedSeconds | walking mode resumed (5) |
| `failure` | context, error | any failure walking mode logs today with `AppServices.logMemoryFailure`, plus Live Activity failures |

- `error` fields hold `String(describing: error)`, cut to 300 characters. They never hold request bodies or the key; `OpenAIClient` errors already describe status and type only.
- Story text is never logged. Titles and place names are.

### 4.3 Quiet reasons

`BuzzEngine` gains a decision call that says why it did not buzz. The reasons, checked in this order:

1. `badAccuracy`: the fix is not usable (`WalkingFix.isUsable` fails).
2. `noneDue`: no place is due.
3. `busy`: a story is preparing, being continued or playing.
4. `skipQuiet`: within 60 s of a skip.
5. `allExcluded`: every due place was already buzzed, heard or retired.
6. `budget`: the budget is spent and no top-tier place qualifies for the override.

- The existing `evaluate` keeps its behaviour and result. It becomes a thin wrapper over the decision call, so existing tests keep passing unchanged.
- A `quiet` line is written only when the reason or the set of due place ids differs from the last `quiet` line of the run, and the first quiet after a buzz, a pause or a resume is always written. A long walk past nothing gives one `noneDue` line, not thousands.

### 4.4 Summary per run (core, pure)

Computed from the events of one file:
- start time, end time (the last event's time), duration;
- walked distance (sum of distances between consecutive `fix` lines with accuracy ≤ 50 m and `paused` false);
- counts: fetches, fetch failures, places found (distinct ids), buzzes, notifications, failures, pauses;
- stop reason, or **"Ended without a stop"** when there is no `stopped` line. That means the app was ended, crashed, or is still running;
- the number of unreadable lines.

### 4.5 Screens

- **Settings → Walk log**, next to "Buzz log". The list of runs, newest first. Each row shows the date and time span, duration, distance, buzz count, and in red "Ended without a stop" or the failure count when non-zero. Swipe deletes a run's file. The run in progress shows "In progress" and cannot be deleted.
- **One run:**
  - A map (SwiftUI `Map`) with the walked path as a polyline (fixes with accuracy ≤ 50 m), the places found as small grey dots, buzzed places as orange pins, stop stories as blue pins, and pauses as pause markers.
  - Below it, the summary and then the timeline: one line per event, local time `HH:mm:ss` plus a short readable text, such as "Fetched 34 places (3 top, 12 good)" or "Quiet: busy · Akershus festning 52 m".
  - A "Hide fixes" toggle, on by default *(Claude's call)*.
  - A share button that shares the `.jsonl` file through the share sheet.

## 5. Auto-pause

### 5.1 Motion source

`CMMotionActivityManager` (the motion coprocessor's activity classification), not raw accelerometer data. Raw `CMMotionManager` updates stop when the app is in the background and cost far more power. *(Claude's call, explained to the owner in chat.)*

- Updates go to the main queue. The app keeps running in the background while walking mode is on, because location updates run there, so activity updates keep arriving. That is believed, not verified on this phone; the GPS rules below cover it if it proves wrong.
- "Walking motion" means an activity with `walking` or `running` true and confidence medium or high.
- The motion permission is asked during start, after the existing location and notification prompts and before the Always upgrade, with a one-off activity query that waits for the answer, so two system prompts never overlap. It is asked on the first start of walking mode after this change (`NSMotionUsageDescription`: "MyGuide notices when you stop and start walking, so walking mode can pause itself and save battery."). A refusal, a restriction or no motion hardware means GPS-only rules. It never blocks walking mode and never shows a problem.

### 5.2 Pause rule (core, pure)

Walking mode pauses when, for the last **180 s**, both are true:
1. The motion state has not been walking. `CMMotionActivityManager` reports changes, not a steady stream, so the detector keeps the latest report as a state: it is walking from a walking-motion report until a report that is not walking motion. A walking report at low confidence counts as not walking. With no motion source, this part always holds.
2. No usable fix (accuracy ≤ 50 m) was farther than `max(30 m, its accuracy)` from the stillness anchor. The anchor is the first usable fix of the still stretch, and a fix that breaks the rule becomes the new anchor and restarts the stretch. With no fixes at all, this part holds.

- The stretch starts at the start of the run, at a resume, when the motion state changes from walking to not walking, and at every anchor move. While the motion state is walking there is no stretch.
- The 60 s stop story fires well before the 180 s pause, so a stop story is told first.

### 5.3 Resume rule (core, pure)

A paused run resumes when either holds:
1. **Motion:** the motion state has been walking for more than **60 s** since the report that made it walking.
2. **GPS:** a fix with accuracy ≤ 100 m is more than **100 m** from the pause position, after subtracting its accuracy (`distance − accuracy > 100`). The pause position is the anchor when the pause began. With no anchor, the first such fix in the pause becomes the anchor, and only a later one can resume.

### 5.4 While paused

- No buzz decisions, no fetches, no stop detection, no stored track samples, no route samples. Fixes still go to the walk log (thinned, with `paused: true`) and to the resume rule.
- Location runs at `kCLLocationAccuracyHundredMeters` with a 50 m distance filter, so the app stays alive in the background without GPS at full power. On resume it goes back to best accuracy and no distance filter.
- A story that is playing or preparing is not interrupted.
- The Live Activity shows "Paused · N buzzes". While paused, the 60 s timer pushes it with a stale date of now + 120 s, so it does not go stale.
- The in-app status pill shows the same text.
- On resume: the route memory starts afresh, the stop detector starts afresh (with the run's earlier stop spots), the next usable fix may fetch places at once (the feed decides as usual), and the engine evaluates as usual.

### 5.5 Time limits

- The 4-hour limit counts **active** time only: time on minus time paused *(Claude's call)*.
- After **60 minutes** paused, walking mode turns off with reason `pausedTooLong` and the notification "Walking mode turned off after an hour without walking." *(Claude's call)*.
- The battery limit (15 %) is unchanged and also applies while paused.
- These are checked by the existing 60 s timer and on every fix.

### 5.6 Checks

The pause and resume rules are evaluated on every fix, on every motion update, and on a timer. The timer runs every **15 s** *(Claude's call)*, so a 60 s motion streak or a 180 s stillness is noticed within 15 s even when fixes and motion updates stop arriving. It replaces the 60 s auto-off timer, and auto-off is checked on every fourth tick.

## 6. Failure behaviour

- Log directory cannot be created: no log for this run, one `os.Logger` error, walking mode works.
- Motion updates fail or never arrive: GPS rules only (5.2 part 1 holds, 5.3 part 1 never fires).
- A log file that cannot be parsed at all: the list shows it with "Unreadable" and allows deleting and sharing.

## 7. Left to the builder

- Exact timeline wording and icons.
- Map styling and the camera fit (fit the path and pins).
- The file writer's internal structure (actor or main-actor class) within the rule that a write never blocks the main thread noticeably. Appending a short line on the main actor is acceptable.

## 8. Device checks after install

1. Start walking mode and lock the phone; the walk log shows `started` with the permissions.
2. Stand still for 4 minutes: `paused` appears and the Live Activity says "Paused".
3. Walk for 2 minutes: `resumed` with reason `motion` (or `gps`).
4. Walk past places: `fetched`, `quiet` and `buzz` lines; the map shows them.
5. Share the file to the Mac.

## 9. Settled during the builder check *(Claude's calls)*

1. **Motion as state.** See 5.2 and 5.3. Tests feed a single walking report and check that someone walking steadily never pauses.
2. **Live Activity.** The widget's existing stale path (`pausedHeadline`/`pausedBody` when `context.isStale`) stays as the signal for "app ended or no GPS". A real pause pushes the body "Paused · N buzzes" with a fresh stale date. `WalkingStatus.text` gains a `paused` parameter (paused wins over waiting-for-GPS), and `WalkingStatus.pausedStaleDate(now:)` returns now + 120 s. Tests cover both. The status pill shows the same text.
3. **Fixes while paused.**
   - `handle(_ fix:)` branches on the pause before the usable check. Every fresh fix with accuracy ≥ 0 goes to the resume rule and to the log.
   - `lastFixAt` is not updated while paused, and `gps` events are not written while paused.
   - On resume, the GPS state is judged afresh, and a `gps` line is written if the state differs from the last one logged.
   - GPS resume is best-effort, and motion is the main resume path.
4. **Fix logging** has its own thinning state (`lastLoggedSample`), separate from the track. Fixes the controller drops are logged too, with `dropped: "stale"` or `"invalid"` (accuracy < 0), thinned the same way. Logged fixes have no `dropped` field.
5. **Notification settings.** `notified` also carries the current settings: authorization, alert, sound, lockScreen, notificationCenter, and the Focus-relevant `timeSensitive` setting, as strings. `UNUserNotificationCenter.add` succeeds even when iOS will not show anything, so this is the only way to see it.
6. **`notified`/`notifyFailed` kinds:** `buzz`, `more`, `stop`, `storyFailed`, `autoOff`, one for each `BuzzNotifier` post call.
7. **Stop reasons.**
   - `WalkingController.stop(reason:)`, where the reason is the `stopped` event's reason.
   - The owner's stop passes `user` (the existing call sites use a default of `user`). `onDenied` passes `locationDenied`, and auto-off passes its reason.
   - `AutoOffReason` gains `pausedTooLong`.
   - `AutoOff.reason` takes `activeTime: TimeInterval`, `pausedFor: TimeInterval?` (the length of the current pause, nil when active) and `batteryLevel`. The order is time limit (activeTime ≥ 14 400), then paused too long (pausedFor ≥ 3 600), then battery.
   - Active time is the time since the start, minus finished pauses, minus the current pause up to now.
8. **Stop detector on resume.** The controller keeps the run's stop spots in its own array (loaded at start, appended in `tellStop`) and builds `StopDetector(previousStops:)` from it on resume.
9. **Scene phase** is observed in the `App` scene (`MyGuideApp`) and forwarded to `WalkingController.noteScenePhase(_:)`, which writes `app` events only while a run is on.
10. **Buzz budget** keeps refilling while paused. Its capacity caps the burst.
11. **Decision call.**
    - `BuzzEngine.decide(...) -> BuzzDecision`, where `BuzzDecision` is `.buzz(Buzz)` or `.quiet(QuietReason, due: [DuePlace])`. `DuePlace` holds the id, name, tier, distance and `excluded`.
    - `due` lists every due place, excluded ones flagged, ordered by tier then distance.
    - The quiet reason is decided after the override check, so `budget` means the budget is spent and no override qualified. When an override qualifies but its 10-minute interval has not passed, the reason is still `budget`.
    - The `closest` update keeps running before the busy check, as today.
    - The order is `badAccuracy`, `noneDue`, `busy`, `skipQuiet`, `allExcluded`, `budget`. With `badAccuracy` the due list is empty, because the engine returns before updating it, as today.
    - The "set of due ids" is the sorted array of ids.
12. **Story hooks.** `WalkingStories` gains a `walkLog` hook (the app's `WalkLog`) and writes `storyPreparing`, `storyReady`, `storyFailed`, `busy` (on change only) and `stopStory` itself. `stopShown` means the Live Activity update or the notification was handed to iOS, not that the owner saw it.
13. **`fetched.places`** logs every place in the fetch (the map needs them), capped at 150 by tier then distance from the fetch position.
14. **Timer and transitions.**
    - One 15 s timer per run, with a tick counter. Every 4th tick runs auto-off and `refreshActivity`. Every tick runs the pause and resume check and the GPS lost check.
    - Pause and resume each go through one function (`enterPause`, `leavePause`). Each writes the log, switches the location mode, resets the detector and route, and pushes the activity.
15. **Config and APIs.**
    - `NSMotionUsageDescription` goes in `project.yml` with the 5.1 text.
    - `WalkingLocation.setPaused(_:)` switches between best/none and hundred-metres/50 m.
    - `CMMotionActivityManager.authorizationStatus()` gives the `started` motion field, or `unavailable` when `isActivityAvailable()` is false.
