# MyGuide: Guided walk controls (start, pause, stop) — design

**Status:** agreed in chat 2026-10-28. Items marked *(Claude's call)* are open for the owner to change.
**Builds on:** `main` at a7da837, which has walking mode, the walk log, auto-pause, Time Sensitive buzzes and the paid team. It fills in path B of the phase 2 design (7.1, "watch app with a walking workout session") as far as controls and status go.

## 1. Why

Owner, 2026-10-28:
- "la oss også lage start, pause og stop guided walk"
- "man kan gjerne registrere turen i apple som walk"
- "vi trenger ikke gps fra klokken for dette"

The watch app today is only the phase 2 test screen. Its "Start guided walk" button runs a 2-minute haptic test and does not start walking mode on the phone.

## 2. Goals, non-goals, anti-goals

**Goals**
1. Start, pause, resume and stop the guided walk from the watch. The phone's walking mode does the work.
2. The watch always shows the true state of the walk, wherever it was changed: on the phone, on the watch, by auto-pause or by auto-off.
3. A manual pause on the phone too, beside the existing on/off button.
4. Each guided walk is saved in Apple Health and Fitness as an **Outdoor Walk**, with the watch's heart rate, active energy and step-based distance. Its pauses are the walk's pauses.

**Non-goals**
- GPS on the watch, and a workout route map (owner: "bare tull"). The phone's walk log has the route.
- Buzzes, "Tell me", "More" or "Skip" on the watch app. Notifications mirrored from the phone stay as they are. That comes later.
- Starting walking mode when a permission is still undetermined (see 5.3).

**Anti-goals**
- The watch and the phone disagreeing about whether a walk is on.
- A workout left running on the watch after the walk has stopped, or a walk on the phone without one, when both apps are reachable.
- A watch command silently doing nothing. Every command ends in a visible state or a visible reason.

## 3. Constraints

- Swift 6 strict concurrency, iOS 26, watchOS 26.
  - WatchConnectivity and HealthKit call their handlers on their own queues. Handlers must not inherit main-actor isolation; see the crash fixed in a7da837.
- The phone holds all state. The watch is a remote and a mirror.
- Pure rules (the walk state, its labels, the message format, pause precedence) live in `MyGuideCore` with Swift Testing.
- HealthKit on the phone: only `HKHealthStore.startWatchApp(with:)`, which needs the HealthKit capability on the iPhone target. The phone reads or writes no health data.
- App UI text is in English.

## 4. The walk state (core, pure)

`GuidedWalkState`, sent from the phone to the watch:
- `phase`: `off`, `starting`, `walking`, `pausedAuto` or `pausedManual`;
- `buzzCount`;
- `startedAt` (nil when off);
- `problem` (nil, or one line saying why the last start or command failed).

**Labels** (exact):

| Phase | Label |
|---|---|
| `off` | "Off" |
| `starting` | "Starting…" |
| `walking` | "Walking · N buzz/buzzes" (singular for 1) |
| `pausedAuto` | "Paused · not moving" |
| `pausedManual` | "Paused" |

**Commands** from the watch: `walk.start`, `walk.pause`, `walk.resume`, `walk.stop`. Each is a WatchConnectivity message with `"type"`. The reply is the resulting state. State changes the phone makes on its own are sent with `updateApplicationContext`, so the watch gets the newest state even when it was not running.

**Manual pause rules** *(Claude's call: a manual pause holds until Resume)*:
- `pause` while walking or auto-paused gives `pausedManual`. Motion and GPS never resume a manual pause.
- `resume` from `pausedManual` gives `walking`. The auto-pause detector starts a fresh still stretch from that moment.
- `resume` from `pausedAuto` also gives `walking`, as if the walker had moved.
- `pause` while already `pausedManual`, or `resume` while `walking`, does nothing and replies with the current state.
- A command while `off` (other than `start`) does nothing and replies `off`.
- Time limits: a manual pause counts as paused time, like an auto-pause. One *continuous* pause of an hour turns walking mode off (reason `pausedTooLong`). An auto pause that becomes a manual one is the same pause: its start time is kept (10.1).

## 5. Phone

### 5.1 Walking controller

- `pause(source:)` and `resume(source:)` beside `start` and `stop(reason:)`. The source is `phone` or `watch`.
  - They reuse the auto-pause machinery: `enterPause` and `leavePause`, the location mode switch, the activity text, the stop-detector and route reset.
  - A manual pause tells the pause detector to hold. The detector's existing behaviour is otherwise unchanged.
- `guidedWalkState` is observable and recomputed on every change of `isOn`, start in progress, pause kind and buzz count. On change it is sent to the watch through `WatchLink`.
- **Walk log:** `paused` and `resumed` gain a reason `manual`, and they and `started`/`stopped` gain a `source` field (`phone`, `watch`, or absent for automatic). Old logs without `source` still read.

### 5.2 Phone UI

- Home screen: beside the existing walk on/off button, a pause/play button appears while walking mode is on.
- The status pill and the Live Activity show the phase label from section 4 ("Paused" for manual, "Paused · not moving" for auto).

### 5.3 Start from the watch

- The phone handles `walk.start` with the same start as its own button, except that it never shows a prompt. If location is undetermined or denied, notifications are undetermined or denied, or the API key is missing, it replies `off` with this problem: "Open MyGuide on your phone to finish setting up." Prompts for Always location and motion are skipped as well. Walking mode runs with what is already granted.
- From the background, the Live Activity cannot start (iOS allows it only in the foreground). The walk goes on without one, and stop stories come as notifications, as today when the activity fails.
- **Watch app launch on phone start** *(Claude's call)*: a walk started on the phone calls `HKHealthStore.startWatchApp(with:)` with an outdoor walking configuration. That launches the watch app, which begins the workout. A failure is logged as a walk log `failure` and changes nothing else.

## 6. Watch

### 6.1 Screen

- **Main screen "Guided walk":** the label, the time walked (active time, from `startedAt` minus pauses, shown as `h:mm:ss`), and the buttons:
  - off: **Start**;
  - walking: **Pause** and **Stop**;
  - paused (either kind): **Resume** and **Stop**.
- While a command waits for its reply, the buttons are disabled and the label shows "Starting…", "Pausing…", "Resuming…" or "Stopping…".
- A failed command shows its reason under the buttons, in orange. Examples: "Phone not reachable", the phone's `problem`.
- The test screen (ping and haptic test) moves behind a "Check" link at the bottom.

### 6.2 Workout

- One `HKWorkoutSession` per guided walk, with `activityType = .walking` and `locationType = .outdoor`. It uses no location permission on the watch, so it uses no GPS.
- The data source is the live workout data source, giving heart rate, active energy and distance (from steps).
- The session follows the phone's state:
  - `walking` with no session starts one;
  - `pausedAuto` and `pausedManual` pause it;
  - `walking` with a paused session resumes it;
  - `off` ends it and **saves** the workout (`finishWorkout`).
  - A workout shorter than 60 s is discarded instead *(Claude's call: a mis-tap leaves no entry in Fitness)*.
- The session also follows the watch's own commands at once, without waiting for the reply. If the reply then says otherwise, the state from the phone wins and the session is corrected.
- If the watch app is launched by `startWatchApp`, the workout begins from the configuration it is handed. Its state then comes from the application context.
- HealthKit permission: share workouts, and read heart rate, active energy and walking distance. It is asked the first time a workout starts. If it is refused, the guided walk still runs on the phone, and the watch shows "Not saved to Health" under the label.

### 6.3 Reachability

- `walk.*` commands need the phone to be reachable. When it is not: "Phone not reachable. Open MyGuide on your phone." The command is not queued: a pause that arrives ten minutes late is wrong.
- The application context brings the newest state whenever the watch app starts or becomes active.

## 7. Failure behaviour

- Phone app not running: watch messages wake it in the background (WatchConnectivity does this for `sendMessage`), and the reply carries the state.
- The phone stops walking mode on its own (auto-off, location denied): the context update tells the watch, and the watch ends and saves the workout.
- The watch app is killed during a walk: on the next launch, HealthKit's workout session recovery (`recoverActiveWorkoutSession`) picks the session up again, and the context brings the state.

## 8. Left to the builder

- Exact watch layout and button styles; SF Symbols.
- How the elapsed time is ticked on the watch (`TimelineView` is fine).

## 9. Device checks after install

1. Start from the watch with the phone locked in a pocket. Walking mode starts, and the watch shows "Walking · 0 buzzes".
2. Pause on the watch. The phone's Live Activity says "Paused". Walk around: it stays paused.
3. Resume, then Stop on the watch. The walk appears in Fitness as an Outdoor Walk, with the pause.
4. Start on the phone. The watch app opens with the walk running.
5. Stand still for 4 minutes. The watch shows "Paused · not moving". Walk on, and it resumes by itself.

## 10. Settled during the builder check *(Claude's calls)*

1. **Pause time.** `AutoOff` keeps judging the current pause only. Auto → manual keeps `pausedSince`. A resume ends the pause.
2. **Start from the watch** is `start(source: .watch, interactive: false)`.
   - It never awaits a prompt. It checks location, notifications and the key first and returns the problem at once.
   - It also needs location **Always**. Background location updates cannot start with When In Use, so without Always the problem is "Open MyGuide on your phone to finish setting up."
   - It skips the Always request and the motion request. Motion stays as granted; if undetermined, the walk is GPS-only.
   - The phone replies at once with `starting` and pushes the final state through the application context.
   - `WatchLink` gets an async handler: the reply is sent from a task, and the reply handler is `@Sendable`.
3. **Core pause detector.** `PauseDetector` gains:
   - `hold()`: every input then returns nil and changes nothing;
   - `release(now:)`: not paused, `stillStart = now`, anchors cleared.
   A manual pause calls `hold()`. A manual resume, and a resume from `pausedAuto` by command, call `release(now:)`. The controller's paused branch never acts on detector output while held.
4. **Pause kind in the controller.** `pauseKind: PauseKind?` (`auto` or `manual`), observable.
   - Auto → manual writes one `paused` line with reason `manual`, keeps `pausedSince`, and pushes the activity and the state.
   - `WalkLogSummary` counts a `paused` that directly follows another `paused` (with no `resumed` between) as the same pause, and does not split the path again.
5. **Walk-log codec.**
   - `paused` and `resumed` take a log-side `WalkPauseReason` (`motion`, `gps`, `manual`), separate from `PauseTrigger`.
   - `started`, `stopped`, `paused` and `resumed` gain an optional `source` (`phone` or `watch`), omitted when automatic.
   - Old lines without `source` still decode; this is tested. Lines with `manual` are unreadable in older builds. That is accepted: only newer builds read them.
6. **Phone relaunch.** At launch, once `WatchLink` is active, the phone always pushes its current state (`off` after a relaunch). Every state carries `sentAt`, the phone's clock at sending. The watch applies a state only when its `sentAt` is newer than the last one it applied, and both replies and contexts go through this rule. Because `sentAt` always differs, `updateApplicationContext` never drops a push as identical.
7. **One workout owner on the watch** (`GuidedWalkModel`). `WorkoutKeeper` becomes idempotent:
   - `ensureRunning()` awaits an in-progress start rather than returning early;
   - `pause()`, `resume()`, and `finish(save:)`.
8. **Watch app plumbing.**
   - `@WKApplicationDelegateAdaptor` with `handle(_ workoutConfiguration:)` and `handleActiveWorkoutRecovery()`, which calls `HKHealthStore.recoverActiveWorkoutSession`.
   - `PhoneLink` handles `didReceiveApplicationContext` and reads `receivedApplicationContext` at activation.
   - All WC and HK handlers are nonisolated `@Sendable` closures that hop to the main actor.
9. **iPhone HealthKit.**
   - `com.apple.developer.healthkit` goes in the phone's entitlements.
   - `startWatchApp(with:)` is called only for `source == .phone`. Its failure is logged as a walk log `failure`.
10. **Workout ended by the system or another app.** The phone walk goes on. The watch shows "Workout ended" under the label and does not restart a workout until the next Start.
11. **Labels.**
    - The phone keeps "Walking · waiting for GPS".
    - On the phone, paused texts become "Paused · N buzzes" for manual and "Paused · not moving · N buzzes" for auto. This changes `WalkingStatus` and its tests on purpose.
    - The watch uses the section 4 labels.
12. **Observable starting.** `WalkingController.isStarting`.
13. **The 60 s discard** uses the builder's `elapsedTime`, which excludes pauses.
14. **Health permission.** Share: workouts. Read: heart rate, active energy and walking distance. "Not saved to Health" keys off the share status for workouts.
15. **State fields.** `GuidedWalkState` also carries `pausedTotal` (seconds of finished pauses) and `pausedSince`, so the watch computes the active time after a relaunch.
