# Phase 2: Walking Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Walking mode. With the phone in a pocket, the watch buzzes for nearby places worth a story, at the owner's chosen pace. A tap plays the story in the AirPods, "More" goes deeper and "Skip" retires the place. After a minute standing still, a short story about the spot waits on the lock screen.

**Architecture:** All decision logic lives in `Packages/MyGuideCore` as pure value types tested with `swift test`:
- place tiers;
- buzz budget and buzz engine;
- buzz text;
- trips;
- the place feed;
- the stop detector;
- the playback state machine;
- prompts;
- log export;
- auto-off.

The phone app wires these to CoreLocation, notifications, audio, SwiftData and (when step 0 clears it) a Live Activity and a small watch app. The phone does all the work. The watch is buzzer, screen and remote, and it never holds the API key.

**Tech Stack:**
- Language: Swift 6 (strict concurrency).
- Apple frameworks: SwiftUI, SwiftData, CoreLocation (background), UserNotifications (time-sensitive, actions), AVFoundation, ActivityKit/WidgetKit, WatchKit/WatchConnectivity/HealthKit (path B), AppIntents.
- Tooling: Swift Testing, XcodeGen.

**Spec:**
- `docs/superpowers/specs/2026-10-27-phase-2-walking-mode-design.md` is the phase 2 design, and it wins for phase 2.
- `docs/superpowers/specs/2026-10-26-myguide-design.md` is the parent spec.

## Global Constraints

- **Platforms:**
  - iOS 26 and watchOS 26 floors.
  - Package `platforms: [.iOS(.v26), .macOS(.v26)]`, tools 6.2.
  - App `SWIFT_VERSION: "6.0"`.
- **Logic location:** core logic goes in `Packages/MyGuideCore`, tested with Swift Testing via `cd Packages/MyGuideCore && swift test`. App targets stay thin; anything with a rule in it belongs in the core with a test.
- **XcodeGen:** `project.yml` is the source of truth. After changing it, run `xcodegen generate` and commit `MyGuide.xcodeproj`.
- **Build check:** `xcodebuild -project MyGuide.xcodeproj -scheme MyGuide -destination 'generic/platform=iOS Simulator' build` ends in `** BUILD SUCCEEDED **` with no warnings from project sources.
- **Secrets:**
  - The OpenAI key lives only in the phone's Keychain (`AppServices.keychainService`, account `openai-api-key`).
  - Nothing key-related goes to the watch, the widget or the repo.
  - `Config/Local.xcconfig` stays git-ignored.
- **OpenAI:**
  - Responses API with strict `json_schema` and `"store": false`.
  - Models only from `OpenAIModels.current`.
  - Every OpenAI call's usage is recorded through `AppServices.recordUsage`.
- **Story style:** story style and levels are phase 1's: `PromptBuilder.systemInstructions(language:)` and `StoryLevel` (50/75/300 words).
- **Shared services:** OSM and Wikipedia are shared public services. Walking fetches use a 500 m radius, re-fetch only after 250 m, and retry a failure no sooner than 60 s.
- **Buzz rules** (design 7.3–7.4):

  | Rule | Value |
  |---|---|
  | Due radius | 60 m |
  | Drop radius | 120 m |
  | Buzzes per hour | 5…60, default 20 |
  | Budget | capacity 3, starts with 1 |
  | Tier-1 override | only when ≥ 90 m away and passing, at most once per 600 s |
  | While a story is playing or preparing | no buzz |
  | After a skip | no buzz for 60 s |
  | Fix accuracy | fixes worse than 50 m are ignored |
- **Stop rules** (design 7.6):
  - 60 s within 25 m, speed below 0.5 m/s (unknown speed is ignored);
  - not again within 100 m in the same trip.
- **Trips** (design 7.7): a different city than the trip's, or 3 days (259 200 s) without use.
- **Auto-off** (design 7.8): after 4 h (14 400 s), or when the battery is below 15%.
- **UI copy:** UI copy is English. Exact strings are given in the tasks and are used verbatim.
- **Cancellation:** keep phase 1's semantics. `URLError.cancelled` becomes `CancellationError`, and the app's own cancellation is silent.
- **Commits:** commit at the end of every task, on the feature branch, with the attribution trailer the harness supplies.
- **Privacy:** the owner's email address is never sent to any service.

## Review Focus

Most likely first:

1. **Phone locked in a pocket for an hour.** If background location is misconfigured or iOS pauses it, buzzes stop silently. Expected: location keeps arriving, or the app says "Waiting for GPS" in its status, and the walking-mode status never claims to be active while getting no fixes. *Pinned in Task 9 (`WalkingStatus` test) and the Gate 0/1 checks.*
2. **No network mid-walk** (a tunnel, roaming off). Expected:
   - a failed place fetch keeps the old places and retries no sooner than 60 s, with no tight retry loop;
   - a story that can't be fetched gives a "Couldn't get the story" notification with the phase 1 message instead of a silent tap.

   *Pinned in Task 8 (`PlaceFeed` failure tests) and Task 10 (`WalkingPlayback` failure test).*
3. **GPS jitter while standing still.** Fixes jumping ±20 m must not make a place flap in and out of range, fire false stops or trigger extra fetches. *Pinned in Task 6 (hysteresis and accuracy tests) and Task 12 (jitter test).*
4. **Tapping an old notification.** For example a "Tell me" from three buzzes ago, while another story plays, or after walking mode was switched off. Expected: the requested story plays, and the current one stops first. A story still being prepared plays when ready. A story that failed says so. *Pinned in Task 10 (`WalkingPlayback` tests).*
5. **Notifications off, "Always" location refused, or no API key when walking mode starts.** Expected: walking mode tells the owner exactly what is missing, instead of running with nothing able to reach them. *Pinned in Task 9 (`WalkingReadiness` tests).*

---

## Milestone 0: Platform check (design step 0)

This milestone builds the permanent capability pieces, plus a "Walking check" screen that lets the owner prove each risky platform behaviour on their own devices with the free team. Its results decide path A vs B (design 7.1) and Live Activity vs notification (design 7.6).

### Task 1: Background location, time-sensitive notifications, background audio, and the Walking check screen

**Files:**
- Modify: `project.yml` (iOS target `info.properties`, `entitlements`)
- Create: `MyGuide/MyGuide.entitlements` (generated by XcodeGen from `project.yml`)
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/TestTone.swift`
- Create: `MyGuide/WalkingCheck/WalkingCheckView.swift`, `MyGuide/WalkingCheck/WalkingCheckModel.swift`
- Create: `MyGuide/AppDelegate.swift` (notification delegate, `UIApplicationDelegateAdaptor` in `MyGuideApp`)
- Modify: `MyGuide/MyGuideApp.swift`, `MyGuide/Settings/SettingsView.swift` (link "Walking check" under "Device check")
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/TestToneTests.swift`

**Interfaces:**
- Produces:
  - `TestTone.wavData(frequency: Double, duration: Double, sampleRate: Int) -> Data` (16-bit mono PCM WAV).
  - `AppDelegate`, the `UNUserNotificationCenter` delegate. It forwards notification responses to `AppDelegate.responseHandler: (@MainActor (UNNotificationResponse) -> Void)?`; Task 9 replaces the check-screen handler with the walking controller's. It presents notifications in the foreground with `.banner, .sound`.

- [ ] **Step 1: Write the failing test**

```swift
@Suite struct TestToneTests {
    @Test func headerAndLength() {
        // 1 s at 8000 Hz, 16-bit mono: 8000 samples · 2 bytes = 16000 data bytes; file = 44 + 16000 = 16044
        // 0.5 s at 8000 Hz: 4000 samples · 2 = 8000; file = 8044
        let one = TestTone.wavData(frequency: 880, duration: 1, sampleRate: 8000)
        #expect(one.count == 16044)
        #expect(TestTone.wavData(frequency: 880, duration: 0.5, sampleRate: 8000).count == 8044)
        #expect(String(decoding: one[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: one[8..<12], as: UTF8.self) == "WAVE")
        // RIFF chunk size = file − 8 = 16036; data chunk size = 16000 (little-endian UInt32 at 4 and 40)
        #expect(one.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) } == 16036)
        #expect(one.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self) } == 16000)
        // Sample rate at 24, bits per sample at 34
        #expect(one.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self) } == 8000)
        #expect(one.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 34, as: UInt16.self) } == 16)
    }
    @Test func zeroOrNegativeDurationIsHeaderOnly() {
        #expect(TestTone.wavData(frequency: 880, duration: 0, sampleRate: 8000).count == 44)
        #expect(TestTone.wavData(frequency: 880, duration: -1, sampleRate: 8000).count == 44)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails.** Run `swift test --filter TestToneTests`. Expected: compile error, "cannot find 'TestTone'".
- [ ] **Step 3: Implement `TestTone.wavData`.** Use a sine wave at amplitude 0.3 of full scale. The sample count is `max(0, Int(duration * Double(sampleRate)))`.
- [ ] **Step 4: Update `project.yml` for the iOS target.**
  - `UIBackgroundModes: [audio, location]`.
  - Add `NSLocationAlwaysAndWhenInUseUsageDescription: "In walking mode MyGuide follows your position with the phone locked, so it can tell you about places you pass."`.
  - Add `NSSupportsLiveActivities: true`.
  - Add `entitlements: { path: MyGuide/MyGuide.entitlements, properties: { com.apple.developer.usernotifications.time-sensitive: true } }`.
  - Run `xcodegen generate`.
- [ ] **Step 5: Implement the Walking check screen.** It has three rows, each with a button, a status line and a result line (✓ / ✗ plus detail).
  1. **"Background location"**
     - Start: request When In Use, then Always. Start a `CLLocationManager` with `allowsBackgroundLocationUpdates = true`, `showsBackgroundLocationIndicator = true`, `pausesLocationUpdatesAutomatically = false` and `activityType = .fitness`, and hold a `CLBackgroundActivitySession`.
     - Show: the authorization status, the fixes received while the app was in the background, and the longest gap between fixes in seconds.
     - Stop: ends everything.
  2. **"Buzz from the watch"**
     - Asks for notification permission (alert, sound, time-sensitive).
     - After 10 s, posts a time-sensitive notification with title "MyGuide test", body "Tap Tell me on your watch", category `CHECK`, and actions "Tell me" (`CHECK_TELL`, no foreground option) and "Skip" (`CHECK_SKIP`).
     - On `CHECK_TELL`, while the app is in the background:
       - activate an `AVAudioSession` (`.playback`, `.spokenAudio`);
       - play a 2 s `TestTone` at 880 Hz written to the caches directory;
       - record "Played from background ✓", or the thrown error.
     - The response handler holds a `UIApplication` background task until playback ends.
  3. **"Live Activity"** is added in Task 2. Leave the row out until then.
- [ ] **Step 6: Run the tests and the build check.** Expected: `swift test` passes; `** BUILD SUCCEEDED **`.
- [ ] **Step 7: Commit.** `git add -A && git commit -m "feat(walking): background location, time-sensitive notifications and the Walking check screen"`

### Task 2: Live Activity widget extension and its check

**Files:**
- Modify: `project.yml` (new target `MyGuideWidgets`, `type: app-extension`, `platform: iOS`, sources `[MyGuideWidgets, Shared]`; the iOS app also gets `Shared` in its sources and depends on and embeds `MyGuideWidgets`)
- Create: `Shared/WalkingActivityAttributes.swift`
- Create: `MyGuideWidgets/MyGuideWidgetsBundle.swift`, `MyGuideWidgets/WalkingLiveActivity.swift`, `MyGuideWidgets/Info.plist` (generated)
- Modify: `MyGuide/WalkingCheck/WalkingCheckView.swift`, `MyGuide/WalkingCheck/WalkingCheckModel.swift`

**Interfaces:**
- Produces:

  ```swift
  struct WalkingActivityAttributes: ActivityAttributes {
      struct ContentState: Codable, Hashable { var headline: String; var body: String; var updatedAt: Date }
      var startedAt: Date
  }
  ```

  Task 13 uses this type. The widget shows `headline` (bold, one line) and `body` (up to 4 lines) on the lock screen. In the Dynamic Island, the compact view shows the `figure.walk` symbol and the expanded view shows `headline`.

- [ ] **Step 1: Add the extension target to `project.yml`.**
  - Bundle id `io.github.birgerlie.MyGuide.Widgets`.
  - `NSExtension: { NSExtensionPointIdentifier: com.apple.widgetkit-extension }`.
  - Deployment target iOS 26.
  - Run `xcodegen generate`.
- [ ] **Step 2: Implement `WalkingLiveActivity`** (an `ActivityConfiguration(for: WalkingActivityAttributes.self)`) and the bundle.
- [ ] **Step 3: Add the "Live Activity" check row.**
  - Start: request a `WalkingActivityAttributes` activity in the foreground, with headline "Walking", body "Live Activity check".
  - Update in 60 s:
    - The update is scheduled with `Task.sleep`. It needs the background location from row 1 running to keep the app alive.
    - After 60 s it updates the activity to headline "Updated from background", body = the time.
    - It records whether the update call succeeded and whether the app was in the background at that moment.
  - End: end the activity.
- [ ] **Step 4: Run the build check.** Expected: `** BUILD SUCCEEDED **`, with the widget extension embedded (`MyGuide.app/PlugIns/MyGuideWidgets.appex` exists in the build products).
- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(walking): Live Activity widget extension and its check"`

### Task 3: Minimal watch app: workout session, custom haptic, phone link, Action button intent

**Files:**
- Modify: `project.yml` (new target `MyGuideWatch`, `type: application`, `platform: watchOS`, deployment watchOS 26, sources `[MyGuideWatch]`; the iOS app embeds it as its companion watch app)
- Create: `MyGuideWatch/MyGuideWatchApp.swift`, `MyGuideWatch/WatchCheckView.swift`, `MyGuideWatch/WorkoutKeeper.swift`, `MyGuideWatch/PhoneLink.swift`, `MyGuideWatch/TellMeIntent.swift`, `MyGuideWatch/MyGuideWatch.entitlements`
- Create: `MyGuide/Watch/WatchLink.swift` (iOS side of WatchConnectivity)
- Modify: `MyGuide/WalkingCheck/WalkingCheckModel.swift`, `MyGuide/WalkingCheck/WalkingCheckView.swift`, `MyGuide/AppServices.swift` (owns the one `WatchLink`)

**Interfaces:**
- Produces:
  - **Message format** (both directions, `WCSession.sendMessage`): a `[String: Any]` dictionary with key `"type"` (String) plus fields. Types defined now: `"ping"` (watch→phone; the phone replies `["type": "pong"]`) and `"check.tell"` (watch→phone; the phone plays the check tone). Task 15 adds the walking types.
  - **iOS:** `@MainActor final class WatchLink: NSObject, WCSessionDelegate` with `var onMessage: (@MainActor ([String: Any]) -> [String: Any])?` and `func send(_ message: [String: Any])` (uses `sendMessage` when `isReachable`, else `transferUserInfo`).
  - **watchOS:** `WorkoutKeeper.start()/stop()` (an `HKWorkoutSession` with `.walking` and `.outdoor`, plus a live builder, so the app stays alive with the wrist down), and `PhoneLink.send(_:)`.
  - **watchOS:** `TellMeIntent: AppIntent` with title "Tell me". `perform()` sends `["type": "check.tell"]` (Task 15 changes it to `"walk.tell"`) and returns `.result()`.

- [ ] **Step 1: Add the watch target to `project.yml`.**
  - Bundle id `io.github.birgerlie.MyGuide.watchkitapp`.
  - `WKCompanionAppBundleIdentifier: io.github.birgerlie.MyGuide`.
  - `WKBackgroundModes: [workout-processing]`.
  - `NSHealthShareUsageDescription` and `NSHealthUpdateUsageDescription`: "MyGuide runs a walking workout so the watch can buzz you about places while your wrist is down."
  - Entitlements: `com.apple.developer.healthkit: true`.
  - The iOS target lists `MyGuideWatch` as a dependency with `embed: true`.
  - Run `xcodegen generate`.
- [ ] **Step 2: Implement the watch check screen.**
  - "Start workout": starts `WorkoutKeeper`, then plays `WKInterfaceDevice.current().play(.directionUp)` followed 0.3 s later by `.success` every 30 s for 2 minutes. That double tap is the "distinct buzz" candidate.
  - "Ping phone": shows the round-trip time, or the error.
  - "Stop".
- [ ] **Step 3: Implement the iOS `WatchLink`** and a "Watch" row on the Walking check screen. It shows paired / installed / reachable, the last message received, and whether the check tone played for a `check.tell` from the Action button.
- [ ] **Step 4: Run the build checks.**
  - `xcodebuild -project MyGuide.xcodeproj -scheme MyGuide -destination 'generic/platform=iOS Simulator' build`.
  - `xcodebuild -project MyGuide.xcodeproj -scheme MyGuideWatch -destination 'generic/platform=watchOS Simulator' build`.
  - Expected: both end in `** BUILD SUCCEEDED **`.
- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(watch): minimal watch app with workout session, haptic, phone link and Action button intent"`

- [ ] **Step 6: Gate 0 (owner, on the phone and watch).** Install from Xcode with the iPhone connected and the watch paired. Use Settings → Walking check, and the watch app.
  1. **Background location:** start it, lock the phone, walk for 30 minutes, then unlock. Expected: fixes kept arriving, and the longest gap is under 60 s.
  2. **Buzz from the watch:** with the phone locked in a pocket and AirPods in, the test notification appears on the watch. Tap "Tell me": the tone plays in the AirPods. **This decides path A.**
  3. **Live Activity:** start it, start background location, lock the phone, and wait 60 s. The lock screen shows "Updated from background". **This decides Live Activity vs. notification for the stop story.**
  4. **Watch app:**
     - It installs on the watch (the free team can sign it).
     - With the workout started and the wrist down, the double buzz arrives every 30 s.
     - "Ping phone" works while the phone is locked.
     - **This decides path B.**
  5. **Action button:**
     - Shortcuts on the watch → new shortcut → MyGuide "Tell me".
     - Settings → Action Button → Shortcut → choose it.
     - Press the button: the tone plays on the phone's AirPods.
  6. **Record the results:** the controller records the five results and the rulings below in the ledger before Task 4.

  | Result | Ruling |
  |---|---|
  | 2 ✓ | Path A as written in Tasks 9 and 11. |
  | 2 ✗ and 4/5 ✓ | Tasks 9 and 11 still post the notifications (they show on the watch). The story trigger is the watch app (Task 15) and the Action button intent; Task 15 moves before Task 12. |
  | 2 ✗ and 4 ✗ and 5 ✗ | The notification's default tap opens the app on the phone at the story (Task 11 Step 5), which is the design's last fallback. |
  | 3 ✓ | Task 13 updates the Live Activity, and posts the notification only if the update throws. |
  | 3 ✗ | Task 13 posts the time-sensitive notification only. Walking mode does not start a Live Activity. |
  | 4 ✗ | Task 15 is skipped and recorded as "waits for the paid account". |

---

## Milestone 1: Walking engine (design step 1)

### Task 4: Place tiers (OSM tags on candidates, Wikipedia limit)

**Files:**
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Grounding/Candidate.swift` (add `tags`)
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Grounding/OverpassClient.swift` (keep whitelisted tags)
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Grounding/CandidateRanker.swift` (merge keeps tags)
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Grounding/WikipediaClient.swift` (`limit` parameter)
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/PlaceTier.swift`
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/PlaceTierTests.swift`; extend `OverpassClientTests.swift`, `WikipediaClientTests.swift`, `GroundingTests.swift`

**Interfaces:**
- Produces:
  - `Candidate.tags: [String: String]?`: a new last property with default `nil` in `init`. Decoding JSON without it gives `nil`, so stored phase 1 groundings still decode.
  - `OverpassClient.keptTagKeys: Set<String> = ["historic", "tourism", "amenity", "building", "memorial", "man_made", "railway", "public_transport", "place", "office", "castle_type", "bridge", "highway"]`.
  - `WikipediaClient.articles(around:radius:language:limit: Int = 20)`. `ggslimit` and `colimit` = `limit`; `exlimit` stays 20, the API maximum for intro extracts.
  - `public enum PlaceTier: Int, Sendable, Codable, Comparable { case top = 1, good = 2, wikiOnly = 3 }`.
  - `public enum PlaceTiers { public static func tier(for candidate: Candidate) -> PlaceTier?; public static func hasArticle(_ candidate: Candidate) -> Bool }`. `nil` means never buzz.
  - `public struct WalkingPlace: Sendable, Equatable { public var candidate: Candidate; public var tier: PlaceTier }` with a memberwise public `init`.

**Rules** (design 7.3). The order of checks is fixed:
1. **No name:** an empty or whitespace-only name gives `nil`.
2. **Never, even with an article:** any of these gives `nil`:
   - tags with key `shop` or `office`;
   - `amenity` ∈ {restaurant, cafe, bar, pub, fast_food, ice_cream, biergarten, bank, atm, school, college, university, kindergarten, hospital, clinic, pharmacy, embassy, police, post_office, parking, fuel};
   - `tourism` ∈ {hotel, hostel, guest_house, motel, apartment, camp_site};
   - key `railway` ∈ {station, halt, stop, tram_stop, subway_entrance};
   - any `public_transport` key;
   - `building` ∈ {train_station, transportation, office, commercial, retail, hotel, school, university, hospital};
   - `highway` = `bus_stop`.
3. **`hasArticle`:** true when `wikipediaTitle` is non-empty, or `summary` is non-nil (summaries come only from Wikipedia), or `id` has prefix `"wiki:"`.
4. **Top:**
   - `historic` ∈ {castle, palace, city_gate, citywalls, ruins, archaeological_site, monument, fort, tower, battlefield};
   - `building` ∈ {cathedral, palace, castle};
   - `castle_type` = palace.
5. **Good:**
   - `amenity = place_of_worship`;
   - `tourism` ∈ {museum, attraction, gallery};
   - `historic` ∈ {memorial (unless `memorial = plaque`), manor, church, monastery, building with `heritage`, archaeological};
   - `place = square` together with any `historic` key.

   A Good place with an article becomes Top.
6. **Wiki-only:** everything else that passes 1–2 and has an article:
   - plaques, `historic` = yes or building;
   - `tourism = artwork`, fountains, bridges;
   - `place = square` without `historic`;
   - streets, theatres;
   - Wikipedia-only candidates (kind `"wikipedia"`, no tags).

   Without an article, these give `nil`. Wiki-only is never lifted.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct PlaceTierTests {
    static func c(_ tags: [String: String]?, kind: String = "x", name: String = "Place", wiki: String? = nil,
                  summary: String? = nil, id: String = "osm:node/1") -> Candidate {
        Candidate(id: id, name: name, coordinate: .init(latitude: 0, longitude: 0), kind: kind,
                  summary: summary, wikipediaTitle: wiki, wikidata: nil, tags: tags)
    }
    @Test func top() {
        #expect(PlaceTiers.tier(for: Self.c(["historic": "castle"])) == .top)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "city_gate"])) == .top)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "ruins"])) == .top)
        #expect(PlaceTiers.tier(for: Self.c(["amenity": "place_of_worship", "building": "cathedral"])) == .top)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "castle", "castle_type": "palace"])) == .top)
    }
    @Test func goodAndLift() {
        #expect(PlaceTiers.tier(for: Self.c(["amenity": "place_of_worship"])) == .good)
        #expect(PlaceTiers.tier(for: Self.c(["tourism": "museum"])) == .good)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "memorial"])) == .good)
        #expect(PlaceTiers.tier(for: Self.c(["tourism": "museum"], wiki: "en:Albertina")) == .top)
        #expect(PlaceTiers.tier(for: Self.c(["amenity": "place_of_worship"], summary: "A church.")) == .top)
    }
    @Test func wikiOnlyNeedsAnArticleAndIsNeverLifted() {
        #expect(PlaceTiers.tier(for: Self.c(["historic": "memorial", "memorial": "plaque"])) == nil)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "memorial", "memorial": "plaque"], wiki: "de:X")) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "yes"], wiki: "de:X")) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.c(["tourism": "artwork"])) == nil)
        #expect(PlaceTiers.tier(for: Self.c(["man_made": "bridge"], wiki: "en:Charles Bridge")) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.c(["place": "square"], wiki: "en:Graben")) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.c(nil, kind: "wikipedia", id: "wiki:en/123")) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.c(nil, kind: "wikipedia", wiki: "en:Y")) == .wikiOnly)
    }
    @Test func neverEvenWithAnArticle() {
        #expect(PlaceTiers.tier(for: Self.c(["shop": "books"], wiki: "en:X")) == nil)
        #expect(PlaceTiers.tier(for: Self.c(["amenity": "bank"], wiki: "en:X")) == nil)
        #expect(PlaceTiers.tier(for: Self.c(["railway": "station"], wiki: "en:Wien Mitte")) == nil)
        #expect(PlaceTiers.tier(for: Self.c(["public_transport": "station"], wiki: "en:X")) == nil)
        #expect(PlaceTiers.tier(for: Self.c(["tourism": "hotel"], wiki: "en:Hotel Sacher")) == nil)
        #expect(PlaceTiers.tier(for: Self.c(["amenity": "school"], wiki: "en:X")) == nil)
        #expect(PlaceTiers.tier(for: Self.c(["office": "government"], wiki: "en:X")) == nil)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "castle"], name: "  ")) == nil)
    }
}
```

  Also add these tests:
  - `OverpassClientTests.keepsOnlyWhitelistedTags`: an element with tags `{name, historic: memorial, memorial: plaque, addr:street: X, wikipedia: de:Y}` gives `tags == ["historic": "memorial", "memorial": "plaque"]`.
  - `WikipediaClientTests.urlUsesLimit`: `url(lang: "en", around: .init(latitude: 0, longitude: 0), radius: 500, limit: 50)` contains `ggslimit=50`, `colimit=50` and `exlimit=20`. The default call still contains `ggslimit=20`.
  - `GroundingTests.mergeKeepsOSMTags`: an OSM candidate with tags, merged with a matching wiki candidate, keeps its tags and gains the summary.
  - `GroundingTests.candidateDecodesWithoutTags`: phase 1 candidate JSON (no `tags` key) decodes with `tags == nil`.

- [ ] **Step 2: Run the tests to verify they fail.** Run `swift test --filter "PlaceTierTests|OverpassClientTests|WikipediaClientTests|GroundingTests"`. Expected: compile errors (`tags`, `PlaceTiers`, `limit`).
- [ ] **Step 3: Implement** `Candidate.tags`, the Overpass tag whitelist, tag-preserving merge, the Wikipedia `limit`, and `PlaceTiers` with the rules above in one file.
- [ ] **Step 4: Run the tests.** Run `swift test`. Expected: everything passes, including all phase 1 tests.
- [ ] **Step 5: Commit.** `git commit -am "feat(walking): place tiers from OSM tags and Wikipedia articles"` (plus `git add` for the new files).

### Task 5: Buzz budget

**Files:**
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/BuzzBudget.swift`
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/BuzzBudgetTests.swift`

**Interfaces:**
- Produces:

  ```swift
  public struct BuzzBudget: Sendable, Equatable {
      public static let capacity = 3.0
      public static let perHourRange = 5...60
      public static let defaultPerHour = 20
      public private(set) var perHour: Int          // clamped into perHourRange
      public init(perHour: Int, now: Date)          // starts with exactly 1 buzz available
      public func available(at now: Date) -> Double // never above capacity, never negative
      public func canSpend(at now: Date) -> Bool    // available ≥ 1
      public mutating func spend(at now: Date) -> Bool  // false (and no change) when it cannot spend
      public mutating func setPerHour(_ value: Int, at now: Date) // accrues at the old rate up to now first
  }
  ```

  A clock that goes backwards (`now` earlier than the last accrual) accrues nothing and does not move the accrual point back.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct BuzzBudgetTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    @Test func refillsAtTheSetRate() {
        // 20/h → one buzz per 3600/20 = 180 s. Start 1; spend → 0; +90 s → 0.5; +180 s → 1.0
        var b = BuzzBudget(perHour: 20, now: Self.t0)
        #expect(b.available(at: Self.t0) == 1)
        #expect(b.spend(at: Self.t0))
        #expect(abs(b.available(at: Self.t0 + 90) - 0.5) < 1e-9)
        #expect(!b.canSpend(at: Self.t0 + 90))
        #expect(b.canSpend(at: Self.t0 + 180))
        #expect(!b.spend(at: Self.t0 + 90) && abs(b.available(at: Self.t0 + 90) - 0.5) < 1e-9)
    }
    @Test func capsAtThree() {
        // 20/h, idle 1 h after spending: 3600/180 = 20 buzzes accrued, capped at 3
        var b = BuzzBudget(perHour: 20, now: Self.t0)
        _ = b.spend(at: Self.t0)
        #expect(b.available(at: Self.t0 + 3600) == 3)
    }
    @Test func otherRates() {
        // 60/h → 60 s each: from 0, +150 s → 2.5.   5/h → 720 s each: from 0, +720 s → 1.0
        var fast = BuzzBudget(perHour: 60, now: Self.t0); _ = fast.spend(at: Self.t0)
        #expect(abs(fast.available(at: Self.t0 + 150) - 2.5) < 1e-9)
        var slow = BuzzBudget(perHour: 5, now: Self.t0); _ = slow.spend(at: Self.t0)
        #expect(abs(slow.available(at: Self.t0 + 719) - 719.0 / 720) < 1e-9)
        #expect(slow.canSpend(at: Self.t0 + 720))
    }
    @Test func clampsTheRate() {
        #expect(BuzzBudget(perHour: 0, now: Self.t0).perHour == 5)
        #expect(BuzzBudget(perHour: 4, now: Self.t0).perHour == 5)
        #expect(BuzzBudget(perHour: 61, now: Self.t0).perHour == 60)
        #expect(BuzzBudget(perHour: -3, now: Self.t0).perHour == 5)
    }
    @Test func rateChangeAccruesAtTheOldRateFirst() {
        // 20/h, spent at t0; at t0+90 (0.5 accrued) switch to 60/h; at t0+120: 0.5 + 30/60 = 1.0
        var b = BuzzBudget(perHour: 20, now: Self.t0); _ = b.spend(at: Self.t0)
        b.setPerHour(60, at: Self.t0 + 90)
        #expect(abs(b.available(at: Self.t0 + 120) - 1.0) < 1e-9)
    }
    @Test func clockGoingBackwardsAccruesNothing() {
        var b = BuzzBudget(perHour: 20, now: Self.t0); _ = b.spend(at: Self.t0)
        #expect(b.available(at: Self.t0 - 600) == 0)
        #expect(abs(b.available(at: Self.t0 + 90) - 0.5) < 1e-9)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail.** Run `swift test --filter BuzzBudgetTests`. Expected: "cannot find 'BuzzBudget'".
- [ ] **Step 3: Implement `BuzzBudget`.** Store `tokens` and `accruedAt`, and compute `available` lazily from those.
- [ ] **Step 4: Run the tests.** Run `swift test --filter BuzzBudgetTests`. Expected: PASS.
- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(walking): buzz budget (average per hour, capacity 3)"`

### Task 6: Buzz engine and buzz text

**Files:**
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/BuzzEngine.swift`, `Packages/MyGuideCore/Sources/MyGuideCore/Walking/BuzzText.swift`
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/BuzzEngineTests.swift`, `Packages/MyGuideCore/Tests/MyGuideCoreTests/BuzzTextTests.swift`, `Packages/MyGuideCore/Tests/MyGuideCoreTests/Support/Metres.swift`

**Interfaces:**
- Consumes: `BuzzBudget` (Task 5), `WalkingPlace` and `PlaceTier` (Task 4), `GeoMath`.
- Produces:

  ```swift
  public struct Buzz: Sendable, Equatable {
      public var id: UUID
      public var place: WalkingPlace
      public var distance: Double
      public var bearing: Double
      public var title: String       // the place name
      public var detail: String      // BuzzText.detail(...)
      public var usedOverride: Bool
  }
  public struct BuzzEngine: Sendable {
      public static let dueRadius = 60.0, dropRadius = 120.0
      public static let overrideMinDistance = 90.0, overridePassingMargin = 10.0
      public static let overrideInterval: TimeInterval = 600, skipQuiet: TimeInterval = 60
      public static let maxFixAccuracy = 50.0
      public var isBusy: Bool
      public init(perHour: Int, now: Date, excluded: Set<String>, makeID: @escaping @Sendable () -> UUID = UUID.init)
      public mutating func setPerHour(_ value: Int, at now: Date)
      public mutating func exclude(_ placeID: String)
      public mutating func noteSkip(at now: Date)
      public mutating func evaluate(places: [WalkingPlace], position: Coordinate, accuracy: Double,
                                    course: Double?, now: Date) -> Buzz?
  }
  public enum BuzzText {
      public static func roundedDistance(_ metres: Double) -> Int
      public static func detail(distance: Double, bearing: Double, course: Double?) -> String
  }
  ```

**Algorithm for `evaluate`** (design 7.4):
1. If the accuracy is not finite, is negative, or is > 50: return `nil` and change no state.
2. For every place:
   - compute its distance and bearing;
   - it enters the due set when distance ≤ 60;
   - it leaves when distance > 120;
   - track its smallest distance while due.
3. If `isBusy`, or `now − lastSkip < 60`, return `nil` (step 2 still ran).
4. The candidates are the due places not excluded, sorted by `(tier.rawValue, distance)`.
5. If the budget can spend: buzz the first candidate, spend, exclude it, and return it.
6. Otherwise, try the override. The first **top**-tier candidate qualifies when all of these hold:
   - distance ≥ 90;
   - distance > closest + 10;
   - no override in the last 600 s.

   If one qualifies, buzz it with `usedOverride = true`. The budget is untouched; exclude the place and record the override time.
7. Otherwise return `nil`.

A place that leaves the due set without buzzing is not excluded. It can come due again later.

**`BuzzText.detail` rules:**
- Distance: rounded to the nearest 10 m, halves away from zero, minimum 10.
- Without a usable course (`nil`, negative or not finite): `"<d> m away"`.
- Otherwise, take r = bearing − course normalised into (−180, 180]:

  | r | Text |
  |---|---|
  | \|r\| ≤ 30 | `"<d> m ahead"` |
  | 30 < r ≤ 150 | `"<d> m right"` |
  | −150 ≤ r < −30 | `"<d> m left"` |
  | otherwise | `"<d> m behind you"` |

- [ ] **Step 1: Write the test helper and failing tests**

```swift
// Support/Metres.swift — metres per degree on the equator = 6 371 000 · π / 180 = 111 194.93
extension Coordinate {
    static func at(north: Double = 0, east: Double = 0) -> Coordinate {
        Coordinate(latitude: north / 111_194.93, longitude: east / 111_194.93)
    }
}

@Suite struct BuzzTextTests {
    @Test func rounding() {
        // nearest 10, halves up, minimum 10: 44→40, 45→50, 119→120, 4→10, 0→10
        #expect(BuzzText.roundedDistance(44) == 40)
        #expect(BuzzText.roundedDistance(45) == 50)
        #expect(BuzzText.roundedDistance(119) == 120)
        #expect(BuzzText.roundedDistance(4) == 10)
        #expect(BuzzText.roundedDistance(0) == 10)
    }
    @Test func sectors() {
        // r = bearing − course in (−180, 180]
        #expect(BuzzText.detail(distance: 50, bearing: 10, course: 0) == "50 m ahead")     // r = 10
        #expect(BuzzText.detail(distance: 50, bearing: 30, course: 0) == "50 m ahead")     // r = 30, boundary
        #expect(BuzzText.detail(distance: 50, bearing: 31, course: 0) == "50 m right")     // r = 31
        #expect(BuzzText.detail(distance: 50, bearing: 150, course: 0) == "50 m right")    // r = 150, boundary
        #expect(BuzzText.detail(distance: 90, bearing: 151, course: 0) == "90 m behind you")
        #expect(BuzzText.detail(distance: 50, bearing: 330, course: 0) == "50 m ahead")    // r = −30
        #expect(BuzzText.detail(distance: 50, bearing: 300, course: 0) == "50 m left")     // r = −60
        #expect(BuzzText.detail(distance: 50, bearing: 210, course: 0) == "50 m left")     // r = −150
        #expect(BuzzText.detail(distance: 50, bearing: 200, course: 0) == "50 m behind you") // r = −160
        #expect(BuzzText.detail(distance: 50, bearing: 180, course: 0) == "50 m behind you") // r = 180
        #expect(BuzzText.detail(distance: 50, bearing: 10, course: 350) == "50 m ahead")   // r = 20 (wrap)
    }
    @Test func noCourse() {
        #expect(BuzzText.detail(distance: 52, bearing: 10, course: nil) == "50 m away")
        #expect(BuzzText.detail(distance: 52, bearing: 10, course: -1) == "50 m away")
        #expect(BuzzText.detail(distance: 52, bearing: 10, course: .nan) == "50 m away")
    }
}

@Suite struct BuzzEngineTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static func place(_ id: String, _ tier: PlaceTier, north: Double = 0, east: Double = 0) -> WalkingPlace {
        WalkingPlace(candidate: Candidate(id: id, name: id, coordinate: .at(north: north, east: east), kind: "x"),
                     tier: tier)
    }
    static func engine(perHour: Int = 20, excluded: Set<String> = []) -> BuzzEngine {
        BuzzEngine(perHour: perHour, now: t0, excluded: excluded)
    }

    @Test func firstBuzzIsImmediate() {
        var e = Self.engine()
        let b = e.evaluate(places: [Self.place("castle", .top, north: 50)], position: .at(), accuracy: 5, course: 0, now: Self.t0)
        #expect(b?.place.candidate.id == "castle")
        #expect(b?.detail == "50 m ahead")
        #expect(b?.usedOverride == false)
    }
    @Test func notDueBeyondSixtyMetres() {
        var e = Self.engine()
        let castle = Self.place("castle", .top, north: 70)
        #expect(e.evaluate(places: [castle], position: .at(), accuracy: 5, course: 0, now: Self.t0) == nil)
        #expect(e.evaluate(places: [castle], position: .at(north: 15), accuracy: 5, course: 0, now: Self.t0 + 10)?.place == castle) // 55 m
    }
    @Test func budgetSpacesBuzzes() {
        // 20/h: second buzz no sooner than 180 s after the first
        var e = Self.engine()
        let a = Self.place("a", .good, north: 40), b = Self.place("b", .good, north: 50)
        #expect(e.evaluate(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == a)
        #expect(e.evaluate(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 179) == nil)
        #expect(e.evaluate(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 180)?.place == b)
    }
    @Test func tierBeatsDistance() {
        var e = Self.engine()
        let church = Self.place("church", .good, north: 20), castle = Self.place("castle", .top, north: 55)
        #expect(e.evaluate(places: [church, castle], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == castle)
        var f = Self.engine()
        let plaque = Self.place("plaque", .wikiOnly, north: 10), museum = Self.place("museum", .good, north: 59)
        #expect(f.evaluate(places: [plaque, museum], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == museum)
    }
    @Test func staysDueUntilDropRadius() {
        // Spend the budget on "a" at t0; "late" (55 m) is due but must wait. At t0+180 the walker has moved
        // 55 m south (late is now 110 m behind) → it still buzzes, "110 m behind you" (course 180 = walking south).
        var e = Self.engine()
        let a = Self.place("a", .top, north: 10), late = Self.place("late", .good, north: 55)
        #expect(e.evaluate(places: [a, late], position: .at(), accuracy: 5, course: 180, now: Self.t0)?.place == a)
        let b = e.evaluate(places: [a, late], position: .at(north: -55), accuracy: 5, course: 180, now: Self.t0 + 180)
        #expect(b?.place == late)
        #expect(b?.detail == "110 m behind you")
    }
    @Test func droppedBeyondDropRadius() {
        var e = Self.engine()
        let a = Self.place("a", .top, north: 10), late = Self.place("late", .good, north: 55)
        _ = e.evaluate(places: [a, late], position: .at(), accuracy: 5, course: 180, now: Self.t0)
        _ = e.evaluate(places: [a, late], position: .at(north: -70), accuracy: 5, course: 180, now: Self.t0 + 60) // 125 m: dropped
        #expect(e.evaluate(places: [a, late], position: .at(north: -64), accuracy: 5, course: 180, now: Self.t0 + 180) == nil) // 119 m, not due again
    }
    @Test func topTierOverrideWhilePassing() {
        // 20/h. t0: "a" (top, 5 m) buzzes and spends the budget. t0+10: castle due, closest 30 m.
        // t0+60 at 125 m north: castle 95 m away (≥ 90, > 30 + 10), budget 60/180 = 0.33 → override.
        // t0+180: budget 180/180 = 1.0 (the override spent nothing) → "g" (good, 50 m) buzzes normally.
        var e = Self.engine()
        let a = Self.place("a", .top, north: 5), castle = Self.place("castle", .top, north: 30)
        let g = Self.place("g", .good, north: 300)
        #expect(e.evaluate(places: [a, castle, g], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == a)
        #expect(e.evaluate(places: [a, castle, g], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 10) == nil)
        let o = e.evaluate(places: [a, castle, g], position: .at(north: 125), accuracy: 5, course: 0, now: Self.t0 + 60)
        #expect(o?.place == castle && o?.usedOverride == true)
        let n = e.evaluate(places: [a, castle, g], position: .at(north: 250), accuracy: 5, course: 0, now: Self.t0 + 180)
        #expect(n?.place == g && n?.usedOverride == false)
    }
    @Test func overrideIntervalIsSixHundredSeconds() {
        // 5/h = 720 s per buzz, so the budget stays below 1 until t0+720.
        // t0: "a" (top, 5 m) buzzes. t0+10: p1 due (closest 30). t0+60 at 125 N: p1 95 m, passing → override #1.
        // t0+500 at 1000 N: p2 due (closest 30). t0+600 at 1125 N: p2 95 m, passing, but 540 s since override #1 → nil.
        // t0+660: 600 s since override #1 → override #2 (budget 660/720 = 0.92, so it is an override).
        var e = Self.engine(perHour: 5)
        let a = Self.place("a", .top, north: 5)
        let p1 = Self.place("p1", .top, north: 30), p2 = Self.place("p2", .top, north: 1030)
        #expect(e.evaluate(places: [a, p1, p2], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == a)
        #expect(e.evaluate(places: [a, p1, p2], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 10) == nil)
        #expect(e.evaluate(places: [p1, p2], position: .at(north: 125), accuracy: 5, course: 0, now: Self.t0 + 60)?.usedOverride == true)
        #expect(e.evaluate(places: [p2], position: .at(north: 1000), accuracy: 5, course: 0, now: Self.t0 + 500) == nil)
        #expect(e.evaluate(places: [p2], position: .at(north: 1125), accuracy: 5, course: 0, now: Self.t0 + 600) == nil)
        #expect(e.evaluate(places: [p2], position: .at(north: 1125), accuracy: 5, course: 0, now: Self.t0 + 660)?.usedOverride == true)
    }
    @Test func noOverrideForGoodTier() {
        var e = Self.engine(perHour: 5)
        let a = Self.place("a", .good, north: 5), church = Self.place("church", .good, north: 30)
        _ = e.evaluate(places: [a, church], position: .at(), accuracy: 5, course: 0, now: Self.t0)
        _ = e.evaluate(places: [a, church], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 10)
        #expect(e.evaluate(places: [church], position: .at(north: 125), accuracy: 5, course: 0, now: Self.t0 + 60) == nil)
    }
    @Test func busyAndSkipQuiet() {
        var e = Self.engine()
        let castle = Self.place("castle", .top, north: 20)
        e.isBusy = true
        #expect(e.evaluate(places: [castle], position: .at(), accuracy: 5, course: 0, now: Self.t0) == nil)
        e.isBusy = false
        e.noteSkip(at: Self.t0 + 1)
        #expect(e.evaluate(places: [castle], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 60) == nil)  // 59 s
        #expect(e.evaluate(places: [castle], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 61)?.place == castle)
    }
    @Test func excludedNeverBuzz() {
        var e = Self.engine(excluded: ["castle"])
        #expect(e.evaluate(places: [Self.place("castle", .top, north: 10)], position: .at(), accuracy: 5, course: 0, now: Self.t0) == nil)
        e.exclude("church")
        #expect(e.evaluate(places: [Self.place("church", .good, north: 10)], position: .at(), accuracy: 5, course: 0, now: Self.t0) == nil)
    }
    @Test func inaccurateFixesChangeNothing() {
        // Review Focus 3: a 51 m fix must not put a place into the due set.
        var e = Self.engine(perHour: 5)
        let a = Self.place("a", .good, north: 5), castle = Self.place("castle", .top, north: 50)
        _ = e.evaluate(places: [a], position: .at(), accuracy: 5, course: 0, now: Self.t0)               // spend
        #expect(e.evaluate(places: [castle], position: .at(), accuracy: 51, course: 0, now: Self.t0 + 1) == nil)
        #expect(e.evaluate(places: [castle], position: .at(), accuracy: .nan, course: 0, now: Self.t0 + 2) == nil)
        // castle never entered the due set, so at 100 m with the budget refilled (720 s) it does not buzz
        #expect(e.evaluate(places: [castle], position: .at(north: -50), accuracy: 5, course: 0, now: Self.t0 + 800) == nil)
    }
    @Test func jitterDoesNotFlap() {
        // Review Focus 3: a place that entered at 59 m stays due at 61 m (no flapping at the 60 m edge).
        // 5/h: "a" spends the budget at t0; at t0+720 the budget is 1.0 and the castle, still due at 61 m, buzzes.
        var e = Self.engine(perHour: 5)
        let a = Self.place("a", .good, north: 1), castle = Self.place("castle", .good, north: 59)
        _ = e.evaluate(places: [a, castle], position: .at(), accuracy: 5, course: 0, now: Self.t0)    // a buzzes, castle due
        _ = e.evaluate(places: [castle], position: .at(north: -2), accuracy: 5, course: 0, now: Self.t0 + 5)  // 61 m: still due
        #expect(e.evaluate(places: [castle], position: .at(north: -2), accuracy: 5, course: 0, now: Self.t0 + 720)?.place == castle)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail.** Run `swift test --filter "BuzzEngineTests|BuzzTextTests"`. Expected: "cannot find 'BuzzEngine'".
- [ ] **Step 3: Implement `BuzzText` and `BuzzEngine`** following the algorithm above.
- [ ] **Step 4: Run the tests.** Run `swift test`. Expected: all pass.
- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(walking): buzz engine (due window, pace, tier-1 override) and buzz text"`

### Task 7: Memory V2: trips, buzz log, track, walk stories, place flags

**Files:**
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Memory/MemoryModels.swift`
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Memory/MemorySchemaV1.swift` (frozen V1 copies), `Packages/MyGuideCore/Sources/MyGuideCore/Memory/WalkMemory.swift` (MemoryStore extension), `Packages/MyGuideCore/Sources/MyGuideCore/Walking/TripRule.swift`, `Packages/MyGuideCore/Sources/MyGuideCore/Walking/WalkStory.swift`
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Memory/MemoryStore.swift` (priors include walk stories)
- Modify: `MyGuide/MyGuideApp.swift` (open with `MemorySchemaV2`)
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/TripRuleTests.swift`, `Packages/MyGuideCore/Tests/MyGuideCoreTests/WalkMemoryTests.swift`, `Packages/MyGuideCore/Tests/MyGuideCoreTests/MigrationTests.swift`

**Interfaces:**
- Consumes: `Buzz` (Task 6), `PlaceTier` (Task 4).
- Produces:

  ```swift
  public enum TripRule {
      public static let idleGap: TimeInterval = 259_200
      public static func startsNewTrip(lastUsedAt: Date?, tripCity: String?, now: Date, city: String?) -> Bool
  }
  public enum BuzzOutcome: String, Sendable, Codable { case pending, heard, skipped, ignored }
  public struct BuzzLogEntry: Sendable, Equatable {
      public var id: UUID; public var at: Date; public var placeID: String; public var placeName: String
      public var kind: String; public var tier: Int; public var distance: Double
      public var outcome: BuzzOutcome; public var deepestLevel: Int
  }
  public struct WalkStory: Sendable, Equatable, Identifiable {
      public enum Kind: String, Sendable, Codable { case buzz, stop }
      public var id: UUID; public var kind: Kind; public var place: Candidate?   // nil for .stop
      public var position: Coordinate; public var course: Double?; public var language: StoryLanguage
      public var title: String; public var levels: [String]; public var createdAt: Date
      public var nextLevel: StoryLevel? { StoryLevel(rawValue: levels.count + 1) }
  }
  public struct TrackSample: Sendable, Equatable { public var at: Date; public var coordinate: Coordinate }
  ```

  New `@Model` types:
  - `TripRecord { @Attribute(.unique) id: UUID; startedAt: Date; city: String?; lastUsedAt: Date }`
  - `BuzzRecord { @Attribute(.unique) id: UUID; at: Date; tripID: UUID; placeID: String; placeName: String; kind: String; tier: Int; distance: Double; outcome: String; deepestLevel: Int = 0 }`
  - `TrackPoint { at: Date; latitude: Double; longitude: Double; tripID: UUID }`
  - `WalkStoryRecord { @Attribute(.unique) id: UUID; kind: String; placeID: String?; title: String; latitude: Double; longitude: Double; language: String; createdAt: Date; tripID: UUID; @Relationship(deleteRule: .cascade, inverse: \StoryRecord.walkStory) stories: [StoryRecord] = [] }`

  Changed models:
  - `StoryRecord` gains `walkStory: WalkStoryRecord?`.
  - `PlaceRecord` gains `skippedAt: Date?`, `lastBuzzedAt: Date?` and `lastBuzzTripID: UUID?`, and its doc comment becomes "A known place: photographed, buzzed or heard."
  - All new attributes are optional or defaulted, so the migration is lightweight.

  Schema and migration:
  - `MemorySchemaV1` holds nested frozen copies of the four phase 1 models, exactly as they are today.
  - `MemorySchemaV2` (version 2.0.0) lists the live models: the 4 changed ones and the 4 new ones.
  - `MemoryMigrationPlan.schemas = [MemorySchemaV1.self, MemorySchemaV2.self]`, `stages = [.lightweight(fromVersion: MemorySchemaV1.self, toVersion: MemorySchemaV2.self)]`.
  - `MemorySchema.models` = the V2 list.

  `MemoryStore` additions (`@MainActor`; each saves at once and rolls back and rethrows on failure):

  ```swift
  public func touchTrip(now: Date, city: String?) throws -> TripRecord   // rule above; fills a nil trip city; updates lastUsedAt
  public func retiredPlaceIDs() throws -> Set<String>                    // deepestLevelHeard ≥ 1 or skippedAt != nil
  public func placeIDsBuzzed(tripID: UUID) throws -> Set<String>
  public func recordBuzz(_ buzz: Buzz, tripID: UUID, at: Date) throws    // BuzzRecord id = buzz.id, outcome pending; upserts PlaceRecord (deepestLevelHeard 0 if new), sets lastBuzzedAt / lastBuzzTripID
  public func setBuzzOutcome(_ id: UUID, _ outcome: BuzzOutcome, deepestLevel: Int) throws // only from pending, except heard → heard with a deeper level; deepestLevel never decreases
  public func markSkipped(placeID: String, at: Date) throws
  public func closePendingBuzzes() throws                                // every pending → ignored
  public func saveWalkStory(_ story: WalkStory, tripID: UUID) throws     // upsert by id; appends unsaved levels as StoryRecords (placeID = story.place?.id); for .buzz upserts the place as heard at levels.count
  public func walkStory(id: UUID) throws -> WalkStory?
  public func appendTrack(_ samples: [TrackSample], tripID: UUID) throws
  public func buzzLog() throws -> [BuzzLogEntry]                         // newest first
  ```

  `priorStories` also returns stop-story levels (`WalkStoryRecord` with `placeID == nil`) within `priorRadius` of `near`. `excludingSession` also excludes a walk story with that id.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct TripRuleTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    @Test func rules() {
        #expect(TripRule.startsNewTrip(lastUsedAt: nil, tripCity: nil, now: Self.t0, city: nil))
        // 3 days = 259 200 s: 259 199 s later → same trip; 259 200 s → new trip
        #expect(!TripRule.startsNewTrip(lastUsedAt: Self.t0, tripCity: "Vienna", now: Self.t0 + 259_199, city: "Vienna"))
        #expect(TripRule.startsNewTrip(lastUsedAt: Self.t0, tripCity: "Vienna", now: Self.t0 + 259_200, city: "Vienna"))
        #expect(TripRule.startsNewTrip(lastUsedAt: Self.t0, tripCity: "Vienna", now: Self.t0 + 60, city: "Rome"))
        #expect(!TripRule.startsNewTrip(lastUsedAt: Self.t0, tripCity: "Wien", now: Self.t0 + 60, city: "wien"))
        #expect(!TripRule.startsNewTrip(lastUsedAt: Self.t0, tripCity: "Vienna", now: Self.t0 + 60, city: nil))
        #expect(!TripRule.startsNewTrip(lastUsedAt: Self.t0, tripCity: nil, now: Self.t0 + 60, city: "Rome"))
    }
}
```

  `WalkMemoryTests` use an in-memory `ModelContainer(for: Schema(MemorySchema.models), configurations: .init(isStoredInMemoryOnly: true))` and must cover:
  - **`touchTrip`:** the first call creates a trip. A second call 60 s later in the same city returns the same id with `lastUsedAt` updated. A call at +259 200 s creates a new trip. A trip with a nil city adopts "Rome" without starting a new trip.
  - **`recordBuzz`:** then `placeIDsBuzzed(tripID:)` = {place id}. For another trip id the set is empty.
  - **`retiredPlaceIDs`:**
    - a buzzed-only place is **not** retired;
    - after `markSkipped` it is;
    - a place heard via `saveWalkStory(.buzz)` is;
    - a place saved by phase 1's `save(_ session:)` is (the photographed counts as heard).
  - **`setBuzzOutcome`:**
    - pending→heard(1), then heard(2) is stored as heard with deepest 2;
    - heard(2) then heard(1) keeps 2;
    - skipped stays skipped when set to heard;
    - `closePendingBuzzes` turns only pending entries into ignored.
  - **`saveWalkStory`:** saving levels [L1], then [L1, L2], stores exactly two `StoryRecord`s with levels 1 and 2. `walkStory(id:)` round-trips all fields.
  - **Priors:**
    - `priorStories(placeIDs: [buzzPlaceID], ...)` includes the buzz story's levels;
    - a stop story 50 m away is included for `near`, and one 80 m away is not (priorRadius 75 m);
    - `excludingSession: stopStory.id` excludes it.
  - **Track and log:** `appendTrack` of 3 samples stores 3 points for the trip. `buzzLog()` returns entries newest first, with outcome and deepest level.

  `MigrationTests.v1StoreOpensAsV2`:
  1. Create a store file in a temp dir with `ModelContainer(for: Schema(versionedSchema: MemorySchemaV1.self), configurations: .init(url: tmp))`.
  2. Insert a V1 `PlaceRecord` and a V1 `CaptureRecord` with one `StoryRecord`, save, and release the container.
  3. Reopen with `ModelContainer(for: Schema(versionedSchema: MemorySchemaV2.self), migrationPlan: MemoryMigrationPlan.self, configurations: .init(url: tmp))`.
  4. Expected: the place exists with `skippedAt == nil` and `lastBuzzedAt == nil`; the capture still has 1 story with `walkStory == nil`; there are 0 `TripRecord`s.

- [ ] **Step 2: Run the tests to verify they fail.** Run `swift test --filter "TripRuleTests|WalkMemoryTests|MigrationTests"`. Expected: compile errors.
- [ ] **Step 3: Implement** the models, the frozen V1 schema, V2, the plan, `TripRule`, the `MemoryStore` additions and the priors change. Switch `MyGuideApp` to open the store with `MemorySchemaV2` (its in-memory fallback too).
- [ ] **Step 4: Run all tests and the build check.** Expected: `swift test` passes everything, including all phase 1 memory tests; `** BUILD SUCCEEDED **`.
- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(memory): schema V2 with trips, buzz log, track, walk stories and place flags"`

### Task 8: Walking place source and place feed

**Files:**
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/WalkingPlaceSource.swift`, `Packages/MyGuideCore/Sources/MyGuideCore/Walking/PlaceFeed.swift`
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/PlaceFeedTests.swift`, `Packages/MyGuideCore/Tests/MyGuideCoreTests/WalkingPlaceSourceTests.swift`

**Interfaces:**
- Consumes: `OverpassClient`, `WikipediaClient` (`limit`), `CandidateRanker.merge`, `PlaceTiers` (Task 4).
- Produces:

  ```swift
  public struct WalkingPlaceSource: Sendable {
      public static let radius = 500
      public static let wikiLimit = 50
      public init(overpass: OverpassClient, wikipedia: WikipediaClient)
      /// Both sources concurrently. One failing → the other's places; both failing → the OSM error is thrown.
      /// CancellationError always propagates. Places with a nil tier are dropped.
      public func places(around: Coordinate, language: StoryLanguage) async throws -> [WalkingPlace]
  }
  public struct PlaceFeed: Sendable {
      public static let refetchDistance = 250.0
      public static let retryInterval: TimeInterval = 60
      public private(set) var places: [WalkingPlace]
      public private(set) var isFetching: Bool
      public init()
      public func shouldFetch(at position: Coordinate, now: Date) -> Bool
      public mutating func fetchStarted(now: Date)
      public mutating func fetchSucceeded(_ places: [WalkingPlace], at center: Coordinate, now: Date)
      public mutating func fetchFailed(now: Date)   // keeps the old places
      public mutating func fetchCancelled()         // clears isFetching, no retry delay
  }
  ```

  **`shouldFetch` rules:**
  - false while fetching;
  - false within 60 s of the last failure;
  - true when there has never been a successful fetch;
  - otherwise true when ≥ 250 m from the last successful centre.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct PlaceFeedTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    @Test func firstFetchThenDistance() {
        var f = PlaceFeed()
        #expect(f.shouldFetch(at: .at(), now: Self.t0))
        f.fetchStarted(now: Self.t0)
        #expect(!f.shouldFetch(at: .at(north: 900), now: Self.t0 + 1))        // in flight
        f.fetchSucceeded([], at: .at(), now: Self.t0 + 2)
        #expect(!f.shouldFetch(at: .at(north: 249), now: Self.t0 + 3))
        #expect(f.shouldFetch(at: .at(north: 250), now: Self.t0 + 3))
    }
    @Test func failureKeepsPlacesAndBacksOff() {
        // Review Focus 2
        var f = PlaceFeed()
        let castle = WalkingPlace(candidate: Candidate(id: "c", name: "C", coordinate: .at(), kind: "x"), tier: .top)
        f.fetchStarted(now: Self.t0); f.fetchSucceeded([castle], at: .at(), now: Self.t0)
        f.fetchStarted(now: Self.t0 + 100); f.fetchFailed(now: Self.t0 + 100)
        #expect(f.places == [castle])
        #expect(!f.shouldFetch(at: .at(north: 400), now: Self.t0 + 159))
        #expect(f.shouldFetch(at: .at(north: 400), now: Self.t0 + 160))
    }
    @Test func failureBeforeAnySuccessRetriesAfterSixtySeconds() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0); f.fetchFailed(now: Self.t0)
        #expect(!f.shouldFetch(at: .at(), now: Self.t0 + 59))
        #expect(f.shouldFetch(at: .at(), now: Self.t0 + 60))
    }
    @Test func cancelledFetchCanRestartAtOnce() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0); f.fetchCancelled()
        #expect(f.shouldFetch(at: .at(), now: Self.t0))
    }
}
```

  `WalkingPlaceSourceTests` use `StubHTTPClient`, with Overpass JSON containing a castle, a bank with a wikipedia tag, and a plain `historic=yes` with no article:
  - **Happy path:** the result is exactly the castle (`.top`).
  - **Overpass HTTP 500:** the Wikipedia articles still come back as `.wikiOnly`.
  - **Both failing:** throws `GroundingFetchError.http(500)`.
  - **Request parameters:** the Overpass request body contains `around:500,` and the Wikipedia URL contains `ggsradius=500` and `ggslimit=50`.
  - **Cancellation:** a handler that throws `URLError(.cancelled)` makes `places` throw `CancellationError`.

- [ ] **Step 2: Run the tests to verify they fail.** Run `swift test --filter "PlaceFeedTests|WalkingPlaceSourceTests"`. Expected: compile errors.
- [ ] **Step 3: Implement both types.**
- [ ] **Step 4: Run the tests.** Run `swift test`. Expected: PASS.
- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(walking): place source (500 m) and feed (250 m refetch, 60 s backoff)"`

### Task 9: Walking mode on the phone: location, buzz notifications, status, skip

**Files:**
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/WalkingReadiness.swift`, `Packages/MyGuideCore/Sources/MyGuideCore/Walking/WalkingStatus.swift`
- Create: `MyGuide/Walking/WalkingController.swift`, `MyGuide/Walking/WalkingLocation.swift`, `MyGuide/Walking/BuzzNotifier.swift`, `MyGuide/Walking/WalkingStatusPill.swift`
- Modify: `MyGuide/AppServices.swift` (owns the one `WalkingController`; `makeWalkingSource()`), `MyGuide/AppDelegate.swift` (routes `BUZZ` responses to the controller), `MyGuide/Capture/CaptureScreen.swift` (walk toggle and status pill), `MyGuide/Story/StoryViewModel.swift` (on save of a session with a matched place, call `services.walking.noteHeard(placeID:)`)
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/WalkingReadinessTests.swift`, `Packages/MyGuideCore/Tests/MyGuideCoreTests/WalkingStatusTests.swift`

**Interfaces:**
- Consumes: Tasks 4–8.
- Produces:

  ```swift
  public enum WalkingReadiness {
      public enum Location: Sendable { case always, whenInUse, denied, notDetermined }
      public enum Notifications: Sendable { case allowed, timeSensitiveOff, denied, notDetermined }
      /// Exact messages, in this order, for whatever is missing. Empty → ready.
      public static func problems(location: Location, notifications: Notifications, hasAPIKey: Bool) -> [String]
  }
  public enum WalkingStatus {
      public static let staleAfter: TimeInterval = 120
      public static func text(isOn: Bool, lastFixAt: Date?, buzzCount: Int, now: Date) -> String?
  }
  ```

  **`problems` messages** (verbatim):
  - location `.denied`: `"Location is off for MyGuide. Turn it on in Settings to use walking mode."`
  - location `.whenInUse`: `"Allow location “Always” so walking mode keeps working with the phone locked."` (curly quotes as shown)
  - notifications `.denied`: `"Notifications are off, so MyGuide can't buzz you. Turn them on in Settings."`
  - notifications `.timeSensitiveOff`: `"Turn on Time Sensitive notifications for MyGuide so buzzes get through Focus."`
  - no key: `"Add your OpenAI API key in Settings first."`
  - `.notDetermined` for either gives no message; the controller asks first.

  **`WalkingStatus.text` rules:**
  - off → `nil`;
  - on with no fix, or the last fix older than 120 s → `"Walking · waiting for GPS"`;
  - otherwise `"Walking · 1 buzz"` or `"Walking · <n> buzzes"` (0 → `"Walking · 0 buzzes"`).

  **iOS:**
  - `@MainActor @Observable final class WalkingController` with:
    - `isOn: Bool`, `problems: [String]`, `buzzCount: Int`, `lastFixAt: Date?`;
    - `func start() async` and `func stop()`;
    - `func handle(_ command: WalkingCommand)`;
    - `func noteHeard(placeID: String)`.
  - `enum WalkingCommand { case skip(buzzID: UUID) }`. Task 11 adds `.tellMe(buzzID: UUID)`, `.more(buzzID: UUID)` and `.open(buzzID: UUID)`.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct WalkingReadinessTests {
    @Test func readyWhenEverythingIsAllowed() {
        #expect(WalkingReadiness.problems(location: .always, notifications: .allowed, hasAPIKey: true).isEmpty)
    }
    @Test func listsEveryProblemInOrder() {
        #expect(WalkingReadiness.problems(location: .whenInUse, notifications: .denied, hasAPIKey: false) == [
            "Allow location “Always” so walking mode keeps working with the phone locked.",
            "Notifications are off, so MyGuide can't buzz you. Turn them on in Settings.",
            "Add your OpenAI API key in Settings first.",
        ])
        #expect(WalkingReadiness.problems(location: .denied, notifications: .timeSensitiveOff, hasAPIKey: true) == [
            "Location is off for MyGuide. Turn it on in Settings to use walking mode.",
            "Turn on Time Sensitive notifications for MyGuide so buzzes get through Focus.",
        ])
        #expect(WalkingReadiness.problems(location: .notDetermined, notifications: .notDetermined, hasAPIKey: true).isEmpty)
    }
}
@Suite struct WalkingStatusTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    @Test func text() {
        #expect(WalkingStatus.text(isOn: false, lastFixAt: Self.t0, buzzCount: 3, now: Self.t0) == nil)
        #expect(WalkingStatus.text(isOn: true, lastFixAt: nil, buzzCount: 0, now: Self.t0) == "Walking · waiting for GPS")
        // Review Focus 1: 120 s is still fresh, 121 s is stale
        #expect(WalkingStatus.text(isOn: true, lastFixAt: Self.t0, buzzCount: 1, now: Self.t0 + 120) == "Walking · 1 buzz")
        #expect(WalkingStatus.text(isOn: true, lastFixAt: Self.t0, buzzCount: 1, now: Self.t0 + 121) == "Walking · waiting for GPS")
        #expect(WalkingStatus.text(isOn: true, lastFixAt: Self.t0, buzzCount: 0, now: Self.t0) == "Walking · 0 buzzes")
        #expect(WalkingStatus.text(isOn: true, lastFixAt: Self.t0, buzzCount: 7, now: Self.t0) == "Walking · 7 buzzes")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail.** Run `swift test --filter "WalkingReadinessTests|WalkingStatusTests"`. Expected: compile errors.
- [ ] **Step 3: Implement the core types.** Run `swift test`. Expected: PASS.
- [ ] **Step 4: Implement the app side.**
  - **`WalkingLocation`:**
    - configured as in Task 1's check;
    - `distanceFilter = 5`;
    - delivers `CLLocation` to the controller;
    - asks for When In Use, then Always.
  - **`WalkingController.start()`:**
    - Compute the readiness problems. Ask for location or notification permission while either is `.notDetermined`, then recompute.
    - Start anyway when only "Always" is missing. Refuse to start for any other problem, and keep `problems` set for the UI.
    - Close pending buzzes from earlier runs.
    - Call `memory.touchTrip(now:city:)` with the city from `MapKitReverseGeocoder` (8 s timeout). A nil city is fine.
    - Build `BuzzEngine(perHour: <AppStorage "buzzesPerHour", default 20>, now:, excluded: retired ∪ buzzed this trip)`.
  - **On each location:**
    1. Update `lastFixAt`.
    2. Buffer a `TrackSample`, flushing every 20 samples and on stop.
    3. If `feed.shouldFetch`, start a `WalkingPlaceSource.places` task (story language at that moment).
    4. Call `engine.evaluate(places: feed.places, position:, accuracy: horizontalAccuracy, course: course ≥ 0 ? course : nil, now:)`.
    5. On a buzz: `memory.recordBuzz`, `buzzCount += 1`, then `BuzzNotifier.post(buzz)`.
  - **`BuzzNotifier`:**
    - registers category `BUZZ` with the single action `SKIP` titled "Skip";
    - posts with identifier `buzz.id.uuidString`, title `buzz.title`, body `buzz.detail`;
    - `interruptionLevel = .timeSensitive`, `threadIdentifier = "walk"`, sound `.default`;
    - `userInfo = ["buzzID": id, "placeID": placeID]`.
  - **`.skip`:**
    - `memory.markSkipped` and `setBuzzOutcome(.skipped, deepestLevel: 0)`;
    - `engine.noteSkip(at: now)`, and the place stays excluded.
  - **`stop()`:**
    - stops location;
    - flushes the track;
    - `closePendingBuzzes`;
    - cancels the fetch task;
    - removes delivered `BUZZ` notifications.
  - **`noteHeard(placeID:)`:** calls `engine.exclude`.
  - **`CaptureScreen`:**
    - a bottom-right button (the empty 56×56 slot in `controlRow`) shows `figure.walk` when off and `figure.walk.motion` in yellow when on, with accessibility label "Walking mode";
    - under the HUD, `WalkingStatusPill` shows `WalkingStatus.text(...)` (a `TimelineView` refreshed every second) and the first `problems` entry in orange, if any.
  - **Location coexistence:** while walking, the capture screen's `LocationProvider` keeps running as before. The two managers coexist.
- [ ] **Step 5: Run the build check.** Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 6: Commit.** `git add -A && git commit -m "feat(walking): walking mode with background location, buzz notifications, skip and status"`

- [ ] **Step 7: Gate 1 (owner, a real walk in an old town, phone locked in a pocket).**
  1. Turn on walking mode; the status reads "Walking · 0 buzzes".
  2. **Buzz quality:** buzzes arrive on the watch with the place name and "50 m left" style text. The direction matches reality for at least 4 of 5 buzzes.
  3. **Pace:** at the default 20 per hour, buzzes are at least about 3 minutes apart, except in short clusters after quiet stretches.
  4. **Exclusions:** no buzz names a shop, café, restaurant, hotel, bank or station.
  5. **Skip:** "Skip" on one buzz means that place never buzzes again, even when walking past it again.
  6. **Status:** after 30 minutes the status still counts buzzes. It never read "waiting for GPS" while you were walking outdoors.
  7. **Report back:** report the buzzes that felt boring. The controller records them in the ledger for tuning `PlaceTiers` in Task 14.

---

## Milestone 2: Walking story (design step 2)

### Task 10: Walking story flow and playback state machine

**Files:**
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/WalkingStoryFlow.swift`, `Packages/MyGuideCore/Sources/MyGuideCore/Walking/WalkingPlayback.swift`
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Story/PromptBuilder.swift` (walk inputs and schema)
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/WalkingStoryFlowTests.swift`, `Packages/MyGuideCore/Tests/MyGuideCoreTests/WalkingPlaybackTests.swift`, `Packages/MyGuideCore/Tests/MyGuideCoreTests/WalkPromptTests.swift`

**Interfaces:**
- Consumes: `WalkStory` (Task 7), `Buzz` and `WalkingPlace` (Tasks 4 and 6), `OpenAIClient.respond`, `PriorStoryLookup`, `PromptBuilder.systemInstructions`, `UsageEntry`.
- Produces:

  ```swift
  public struct WalkingStoryFlow: Sendable {
      public static let factLimit = 5
      public static let stopFactRadius = 150.0
      public init(openAI: OpenAIClient, models: OpenAIModels = .current, priors: @escaping PriorStoryLookup = { _, _, _ in [] },
                  now: @escaping @Sendable () -> Date = Date.init, makeID: @escaping @Sendable () -> UUID = UUID.init)
      public func buzzStory(_ buzz: Buzz, position: Coordinate, course: Double?, nearby: [WalkingPlace],
                            language: StoryLanguage) async throws -> (WalkStory, [UsageEntry])
      public func stopStory(position: Coordinate, address: Address?, nearby: [WalkingPlace],
                            language: StoryLanguage) async throws -> (WalkStory, [UsageEntry])
      public func continueStory(_ story: WalkStory) async throws -> (WalkStory, [UsageEntry])  // PhotoStoryError.noFurtherLevel after 3
  }
  extension PromptBuilder {
      static let walkStorySchema: JSONValue      // strict: { "title": string, "story": string }, both required, no extras
      static func walkBuzzInput(buzz: Buzz, course: Double?, facts: [WalkingPlace], position: Coordinate, priors: [PriorStory]) -> String
      static func walkStopInput(address: Address?, facts: [WalkingPlace], position: Coordinate, priors: [PriorStory]) -> String
      static func walkContinuationInput(story: WalkStory, level: StoryLevel, priors: [PriorStory]) -> String
  }
  public struct WalkingPlayback: Sendable, Equatable {
      public enum Event: Sendable, Equatable {
          case buzzSent(UUID), storyReady(UUID), storyFailed(UUID), moreReady(UUID, level: Int), moreFailed(UUID)
          case tellMe(UUID), more(UUID), skip(UUID), finished(UUID, level: Int), stoppedExternally
      }
      public enum Effect: Sendable, Equatable {
          case play(UUID, level: Int), stopAudio, fetchMore(UUID), offerMore(UUID), retire(UUID), reportFailure(UUID)
      }
      public init()
      public var isBusy: Bool { get }        // preparing any story, fetching more, or playing
      public var playing: (id: UUID, level: Int)? { get }
      public mutating func handle(_ event: Event) -> [Effect]
  }
  ```

**`walkBuzzInput` must contain these lines verbatim** (the parts in angle brackets are filled in):
- `"The listener is walking, not looking at a photo. Tell the story of the place they are passing."`
- `"Place: <name> (<kind>), <detail>."` For example: `Place: Michaelertor (historic=city_gate), 50 m left.`
- The place's summary as `"Summary: <summary>"` when present.
- `"Other places nearby:"`, then up to 4 of `facts` (excluding the buzzed place, sorted by tier then distance from `position`) as `"- <name> (<kind>), <rounded distance> m"`.
- The priors block in phase 1's format.
- `"Write the first story in about 50 words."` (from `StoryLevel.first.lengthPhrase`).

**`walkStopInput` must contain:**
- `"The listener has stopped walking and is standing here for a while. Tell a short story about this spot."`
- `"Where: <address.display>"`, or `"Where: unknown street"` when the address is nil or empty.
- `"Places within 150 m:"` followed by up to 5 of `facts` within 150 m.
- The priors block.
- The 50-word length line.

**`walkContinuationInput`:** gives the levels told so far, the place line (or `"Where: ..."` for a stop story), and the requested level's length phrase.

**Flow:**
- Responses use `schemaName: "walk_story"`, `imageJPEG: nil`, and the story model and reasoning effort from `OpenAIModels`.
- An empty or whitespace-only story throws `OpenAIError.malformedResponse`.
- Priors:
  - for a buzz story: `priors([buzz.place.candidate.id] + fact ids, position, nil)`;
  - for a stop story: `priors(fact ids, position, nil)`;
  - for a continuation: `priors(ids, story.position, story.id)`.
- One `UsageEntry(kind: .story)` per call.

**`WalkingPlayback` rules:**
- **`buzzSent(id)`:** marks it preparing (busy).
- **`storyReady(id)`:** marks it ready. If `tellMe` came earlier, emit `[.stopAudio?, .play(id, 1)]`. `.stopAudio` is included only when something else is playing.
- **`storyFailed(id)`:** marks it failed. If `tellMe` came earlier, emit `[.reportFailure(id)]`.
- **`tellMe(id)`:**
  - ready → `[.stopAudio (if another is playing), .play(id, 1)]`;
  - preparing → remember the request, no effects;
  - failed → `[.reportFailure(id)]`;
  - unknown id → `[.reportFailure(id)]`. This happens when the app was relaunched and the prepared story is gone; the app then re-prepares from memory, see Task 11.
- **`more(id)`:** `[.fetchMore(id)]` and marks fetching (busy), unless it is already at level 3 (then no effects).
- **`moreReady(id, level)`:** `[.stopAudio (if another is playing), .play(id, level)]`.
- **`moreFailed(id)`:** `[.reportFailure(id)]`.
- **`skip(id)`:** `[.stopAudio]` if `id` is playing, plus `[.retire(id)]` in all cases. It also clears any remembered `tellMe`.
- **`finished(id, level)`:** `playing = nil`. If level < 3, emit `[.offerMore(id)]`.
- **`stoppedExternally`** (a phone call or AirPods removed): `playing = nil`, no effects.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct WalkingPlaybackTests {
    static let a = UUID(), b = UUID()
    @Test func tapAfterReadyPlays() {
        var p = WalkingPlayback()
        #expect(p.handle(.buzzSent(Self.a)).isEmpty && p.isBusy)
        #expect(p.handle(.storyReady(Self.a)).isEmpty && !p.isBusy)
        #expect(p.handle(.tellMe(Self.a)) == [.play(Self.a, level: 1)])
        #expect(p.isBusy && p.playing?.id == Self.a)
    }
    @Test func tapWhilePreparingPlaysWhenReady() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a))
        #expect(p.handle(.tellMe(Self.a)).isEmpty)
        #expect(p.handle(.storyReady(Self.a)) == [.play(Self.a, level: 1)])
    }
    @Test func failedStoryReportsOnTap() {
        // Review Focus 2
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.tellMe(Self.a))
        #expect(p.handle(.storyFailed(Self.a)) == [.reportFailure(Self.a)])
        #expect(p.handle(.tellMe(Self.a)) == [.reportFailure(Self.a)])
        #expect(!p.isBusy)
    }
    @Test func oldNotificationInterruptsCurrentStory() {
        // Review Focus 4
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a))
        _ = p.handle(.buzzSent(Self.b)); _ = p.handle(.storyReady(Self.b))
        _ = p.handle(.tellMe(Self.b))
        #expect(p.handle(.tellMe(Self.a)) == [.stopAudio, .play(Self.a, level: 1)])
        #expect(p.playing?.id == Self.a)
    }
    @Test func unknownIDReportsFailure() {
        var p = WalkingPlayback()
        #expect(p.handle(.tellMe(Self.a)) == [.reportFailure(Self.a)])
    }
    @Test func moreLevels() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a)); _ = p.handle(.tellMe(Self.a))
        #expect(p.handle(.finished(Self.a, level: 1)) == [.offerMore(Self.a)])
        #expect(p.handle(.more(Self.a)) == [.fetchMore(Self.a)] && p.isBusy)
        #expect(p.handle(.moreReady(Self.a, level: 2)) == [.play(Self.a, level: 2)])
        #expect(p.handle(.finished(Self.a, level: 2)) == [.offerMore(Self.a)])
        _ = p.handle(.more(Self.a)); _ = p.handle(.moreReady(Self.a, level: 3))
        #expect(p.handle(.finished(Self.a, level: 3)).isEmpty)
        #expect(p.handle(.more(Self.a)).isEmpty)
    }
    @Test func skip() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a)); _ = p.handle(.tellMe(Self.a))
        #expect(p.handle(.skip(Self.a)) == [.stopAudio, .retire(Self.a)])
        #expect(p.playing == nil && !p.isBusy)
        _ = p.handle(.buzzSent(Self.b))
        #expect(p.handle(.skip(Self.b)) == [.retire(Self.b)])
        #expect(p.handle(.storyReady(Self.b)).isEmpty)   // a skipped story never plays
    }
    @Test func externalStopFreesTheEngine() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a)); _ = p.handle(.tellMe(Self.a))
        #expect(p.handle(.stoppedExternally).isEmpty && !p.isBusy)
    }
}
```

  `WalkPromptTests` assert each verbatim line above. Use one buzz: Michaelertor, `historic=city_gate`, detail "50 m left", summary "Gate of the palace.". Use facts: the buzzed place; a church at 80 m (`.good`); a plaque at 30 m (`.wikiOnly`); a castle at 200 m (`.top`).
  - The "Other places nearby" lines are, in order: the castle (200 m), the church (80 m), the plaque (30 m). The order is tier then distance, and the buzzed place is excluded.
  - In the stop input with the same facts around `position`, "Places within 150 m:" lists the church and the plaque but not the castle.
  - A nil address gives `"Where: unknown street"`.

  `WalkingStoryFlowTests` use `StubHTTPClient` returning `{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"title\":\"T\",\"story\":\"S\"}"}]}],"usage":{"input_tokens":10,"output_tokens":5},"status":"completed"}`. Match the response shape the existing `OpenAIClientTests` use; copy their stub helper. Cover:
  - **Request body:** it has no `input_image`; it contains `"name":"walk_story"` and `"store":false`.
  - **Buzz story:** `(story.title, story.levels, story.kind, story.place?.id) == ("T", ["S"], .buzz, buzz.place.candidate.id)`, with usage 10/5.
  - **Empty story:** a story text of `" "` throws `OpenAIError.malformedResponse`.
  - **Priors:** the priors closure is called with the buzzed place's id first.
  - **Continuation:** `continueStory` appends level 2, and after 3 levels throws `PhotoStoryError.noFurtherLevel`.
  - **Stop story:** `stopStory` gives `kind == .stop` and `place == nil`.

- [ ] **Step 2: Run the tests to verify they fail.** Run `swift test --filter "WalkingPlaybackTests|WalkPromptTests|WalkingStoryFlowTests"`. Expected: compile errors.
- [ ] **Step 3: Implement** the prompt builders, `WalkingStoryFlow` and `WalkingPlayback`.
- [ ] **Step 4: Run the tests.** Run `swift test`. Expected: PASS.
- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(walking): walking and stop story flow, playback state machine"`

### Task 11: Walking story on the phone: prepare at buzz, Tell me, More, Skip, open

**Files:**
- Create: `MyGuide/Walking/WalkStoryView.swift`, `MyGuide/Walking/WalkingPanel.swift`
- Modify: `MyGuide/Walking/WalkingController.swift`, `MyGuide/Walking/BuzzNotifier.swift`, `MyGuide/AppDelegate.swift`, `MyGuide/AppServices.swift` (`makeWalkingFlow()`), `MyGuide/Capture/CaptureScreen.swift` (panel and navigation to `WalkStoryView`), `MyGuide/Story/AudioPlayer.swift` (only if it needs an `onFinish` hook it lacks; keep its interruption handling)

**Interfaces:**
- Consumes: `WalkingStoryFlow`, `WalkingPlayback` (Task 10), `SpeechService.audioFile(text:language:cacheKey:)`, `MemoryStore.saveWalkStory/setBuzzOutcome/markSkipped/walkStory(id:)` (Task 7), `UserFacingMessage.message(for:)`.
- Produces:
  - `WalkingCommand` gains `.tellMe`, `.more` and `.open`.
  - `BuzzNotifier` categories:
    - `BUZZ` with actions `TELL_ME` "Tell me" and `SKIP` "Skip";
    - `MORE` with actions `MORE` "More" and `SKIP` "Skip";
    - `STORY_FAILED` with no actions.
  - Speech cache key: `"\(story.id.uuidString)-\(level)-\(language.rawValue)"`.

- [ ] **Step 1: Prepare at buzz.**
  1. Right after posting a buzz, feed `.buzzSent(id)` to the playback machine and set `engine.isBusy = playback.isBusy`.
  2. Start a task that runs `flow.buzzStory`, then `speech.audioFile` for level 1. It records usage, `saveWalkStory` into the current trip, then `.storyReady(id)`.
  3. On error: `.storyFailed(id)`. A `CancellationError` is silent.
  4. Hold a `UIApplication` background task for the duration.
  5. Keep the prepared `WalkStory` and its level audio URLs in a dictionary keyed by buzz id. Keep at most the 5 newest, dropping the oldest.
  6. After every playback event, set `engine.isBusy = playback.isBusy`.
- [ ] **Step 2: Effects.**
  - **`.play(id, level)`:** activate the audio session (`.playback`, `.spokenAudio`) and play the level's file with `AudioPlayer`. When it finishes, feed `.finished(id, level)`. On an interruption or route loss, feed `.stoppedExternally`. Then `setBuzzOutcome(.heard, deepestLevel: level)`.
  - **`.fetchMore(id)`:** run `flow.continueStory`, then `audioFile` for the new level, `saveWalkStory`, then `.moreReady`. On error: `.moreFailed`.
  - **`.offerMore(id)`:** post category `MORE` with title = the story title, body `"Tap More for the next part."`, identifier `"\(id)-more"`, and thread `"walk"`.
  - **`.retire(id)`:** `markSkipped`, `setBuzzOutcome(.skipped, deepestLevel: <current>)`, `engine.noteSkip`.
  - **`.reportFailure(id)`:** post category `STORY_FAILED` with title "Couldn't get the story" and body = `UserFacingMessage.message(for: error)`. When there is no error (unknown id), the body is "That story is no longer available.".
  - **`.stopAudio`:** stop `AudioPlayer`.
- [ ] **Step 3: Unknown id after a relaunch.** Before feeding `.tellMe(id)`, check whether the id is unknown to the playback machine but `memory.walkStory(id:)` returns a story. If so:
  1. Rebuild the entry: feed `.buzzSent`.
  2. Fetch speech for level 1 (cached on disk if it's still there).
  3. Feed `.storyReady`, then `.tellMe`.

  Only report a failure when memory has nothing either.
- [ ] **Step 4: Routing.**
  - `AppDelegate` maps actions to commands: `TELL_ME` → `.tellMe`, `MORE` → `.more`, `SKIP` → `.skip`, and the default action (a tap on the notification body) → `.open`.
  - All handling runs on the main actor, and the completion handler is called after the command is dispatched.
- [ ] **Step 5: `.open(id)`.**
  - It brings the app forward to `WalkStoryView` for that story (`CaptureScreen` navigation destination).
  - The view shows the title, every level's text, a speaker button per level (as in phase 1's `StoryView`), "Tell me more" while `nextLevel != nil`, and "Skip this place".
  - Its buttons send the same commands. This is also the design's last-fallback path.
- [ ] **Step 6: `WalkingPanel`.**
  - It sits on `CaptureScreen` above the controls while a walk story is playing or ready.
  - It shows the title, plus Play/Stop, More and Skip buttons with accessibility labels "Play story", "Stop story", "More" and "Skip".
- [ ] **Step 7: Run the build check.** Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 8: Commit.** `git add -A && git commit -m "feat(walking): prepared walking stories with Tell me, More, Skip and in-app story view"`

- [ ] **Step 9: Gate 2 (owner, a walk, phone locked, AirPods in).**
  1. **Tell me:** on a buzz, "Tell me" from the watch plays the story in the AirPods within about 2 s. It is about the right place and doesn't talk as if there were a photo.
  2. **More:** when it ends, a "More" notification arrives. "More" plays the next part, which continues the story rather than restarting it.
  3. **Skip:** stops the audio at once, and that place never buzzes again.
  4. **Old notification:** tap "Tell me" on a buzz from 10 minutes ago. Its story plays, and any story already playing stops first.
  5. **Open in the app:** tap a buzz notification itself. The app opens at that story, with text and speaker buttons.
  6. **No network:** turn on aeroplane mode and wait for a buzz (it can still come from places already fetched). Tap "Tell me": you get "Couldn't get the story" with "No connection…".
  7. **Cost:** the counter in Settings shows the walk's cost. Report it, for comparison with the design's "about a cent per buzz".

---

## Milestone 3: Stop story (design step 3)

### Task 12: Stop detector

**Files:**
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/StopDetector.swift`
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/StopDetectorTests.swift`

**Interfaces:**
- Produces:

  ```swift
  public struct StopDetector: Sendable {
      public static let radius = 25.0, duration: TimeInterval = 60, maxSpeed = 0.5
      public static let repeatRadius = 100.0, maxFixAccuracy = 50.0
      public init(previousStops: [Coordinate])
      /// Returns the stop spot (the anchor) once, the first time the owner has stayed within 25 m of it for 60 s.
      public mutating func update(position: Coordinate, accuracy: Double, speed: Double, now: Date) -> Coordinate?
  }
  ```

**Algorithm:**
1. Ignore fixes with accuracy that is not finite, negative or > 50.
2. Re-anchor at this fix (anchor = position, anchorAt = now, fired = false) when any of these hold:
   - there is no anchor;
   - the distance to the anchor is > 25;
   - speed ≥ 0 and speed > 0.5.

   A negative speed means unknown and is ignored.
3. If not fired, `now − anchorAt ≥ 60`, and no previous stop is within 100 m of the anchor: set fired, append the anchor to the previous stops, and return the anchor.
4. Otherwise return `nil`.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct StopDetectorTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    @Test func firesAfterSixtySecondsWithJitter() {
        // Review Focus 3: fixes jitter up to ±10 m around the anchor; fires at t0+60, not t0+59
        var d = StopDetector(previousStops: [])
        let jitter: [(Double, Double)] = [(0, 0), (8, -3), (-6, 9), (10, 0), (-9, -5), (4, 7)]
        for (i, (n, e)) in jitter.enumerated() {
            #expect(d.update(position: .at(north: n, east: e), accuracy: 8, speed: 0.2, now: Self.t0 + Double(i) * 10) == nil)
        }   // last fix at t0+50
        #expect(d.update(position: .at(north: 3), accuracy: 8, speed: 0.1, now: Self.t0 + 59) == nil)
        #expect(d.update(position: .at(north: -2), accuracy: 8, speed: 0.1, now: Self.t0 + 60) == .at())
        #expect(d.update(position: .at(), accuracy: 8, speed: 0, now: Self.t0 + 120) == nil)   // once per anchor
    }
    @Test func walkingNeverFires() {
        // 1.4 m/s for 5 minutes
        var d = StopDetector(previousStops: [])
        for s in stride(from: 0.0, through: 300, by: 5) {
            #expect(d.update(position: .at(north: s * 1.4), accuracy: 5, speed: 1.4, now: Self.t0 + s) == nil)
        }
    }
    @Test func movingAwayResets() {
        // moves 30 m at t0+40 → new anchor; fires at t0+100
        var d = StopDetector(previousStops: [])
        _ = d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0)
        _ = d.update(position: .at(north: 30), accuracy: 5, speed: 0, now: Self.t0 + 40)
        #expect(d.update(position: .at(north: 30), accuracy: 5, speed: 0, now: Self.t0 + 99) == nil)
        #expect(d.update(position: .at(north: 30), accuracy: 5, speed: 0, now: Self.t0 + 100) == .at(north: 30))
    }
    @Test func notAgainWithinOneHundredMetres() {
        var near = StopDetector(previousStops: [.at()])
        _ = near.update(position: .at(north: 80), accuracy: 5, speed: 0, now: Self.t0)
        #expect(near.update(position: .at(north: 80), accuracy: 5, speed: 0, now: Self.t0 + 60) == nil)
        var far = StopDetector(previousStops: [.at()])
        _ = far.update(position: .at(north: 120), accuracy: 5, speed: 0, now: Self.t0)
        #expect(far.update(position: .at(north: 120), accuracy: 5, speed: 0, now: Self.t0 + 60) == .at(north: 120))
    }
    @Test func unknownSpeedAndBadFixes() {
        var d = StopDetector(previousStops: [])
        _ = d.update(position: .at(), accuracy: 5, speed: -1, now: Self.t0)
        #expect(d.update(position: .at(north: 200), accuracy: 60, speed: -1, now: Self.t0 + 30) == nil)  // ignored
        #expect(d.update(position: .at(), accuracy: 5, speed: -1, now: Self.t0 + 60) == .at())
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail.** Run `swift test --filter StopDetectorTests`. Expected: "cannot find 'StopDetector'".
- [ ] **Step 3: Implement** `StopDetector` following the algorithm above.
- [ ] **Step 4: Run the tests.** Run `swift test`. Expected: PASS.
- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(walking): stop detector (60 s within 25 m, once per 100 m per trip)"`

### Task 13: Stop story on the lock screen

**Files:**
- Modify: `MyGuide/Walking/WalkingController.swift`, `MyGuide/Walking/BuzzNotifier.swift`, `MyGuide/AppDelegate.swift`
- Create: `MyGuide/Walking/WalkingActivityController.swift` (only if the Gate 0 ruling is "Live Activity")
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Memory/WalkMemory.swift` (add `stopSpots(tripID: UUID) throws -> [Coordinate]`), plus its test in `WalkMemoryTests` (two stop stories in the trip return both coordinates; another trip's are excluded)

**Interfaces:**
- Consumes: `StopDetector` (Task 12), `WalkingStoryFlow.stopStory` (Task 10), `MapKitReverseGeocoder` (8 s timeout, as in phase 1), `WalkingActivityAttributes` (Task 2).

- [ ] **Step 1: Write the failing `stopSpots` test**, run it (expected: fails), implement, and run it again (expected: passes).
- [ ] **Step 2: Detector wiring.**
  - At walking start: `StopDetector(previousStops: memory.stopSpots(tripID:))`.
  - On each location: `update(position:accuracy:speed:now:)`.
- [ ] **Step 3: On a stop spot.**
  1. Reverse-geocode the spot. A failure or timeout gives a nil address.
  2. Facts = `feed.places`.
  3. Run `flow.stopStory`, record usage, and `saveWalkStory(kind .stop)`.
  4. Deliver it:
     - **Notification:** category `STOP`, title = story title, body = the story text, interruption `.timeSensitive`, thread `"walk"`, identifier = the story id. Sound `.default`, or `nil` while a walk story is playing.
     - **Live Activity** (if Gate 0 cleared it): walking start also starts the activity with headline "Walking", body = `WalkingStatus.text`. A stop updates it to headline = title, body = story text, and posts the notification only if the update throws.
  5. A failure is silent apart from a log line. It is a lock-screen extra, not something the owner asked for.
- [ ] **Step 4: Opening the stop story.** A tap on the `STOP` notification or the Live Activity (`widgetURL` `myguide://walk/<id>`; register the `myguide` URL scheme in `project.yml`) opens `WalkStoryView` for that story. "Tell me more" and speech work there.
- [ ] **Step 5: Ending the activity.** Walking stop ends the Live Activity with dismissal policy `.immediate`.
- [ ] **Step 6: Run the tests and the build check.** Expected: `swift test` passes; `** BUILD SUCCEEDED **`.
- [ ] **Step 7: Commit.** `git add -A && git commit -m "feat(walking): stop story on the lock screen"`

- [ ] **Step 8: Gate 3 (owner).**
  1. **Stop story:** walk with the phone locked, then stand still in a square for a minute. Within about 30 s after that, a short story about that spot is on the lock screen (and on the watch).
  2. **Open it:** tap it. The app opens at the story, and "Tell me more" works.
  3. **No repeat:** stand still again within 100 m. There is no second stop story.
  4. **Not on the move:** waiting at a pedestrian crossing (under a minute) never gives a stop story.

---

## Milestone 4: Log, settings, auto-off, watch app (design step 4)

### Task 14: Buzz log, buzzes-per-hour setting, auto-off, README

**Files:**
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/BuzzLogExport.swift`, `Packages/MyGuideCore/Sources/MyGuideCore/Walking/AutoOff.swift`
- Create: `MyGuide/Settings/BuzzLogView.swift`
- Modify: `MyGuide/Settings/SettingsView.swift`, `MyGuide/Walking/WalkingController.swift`, `README.md`
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/PlaceTier.swift`, but only for the tier changes the owner asked for at Gate 1 and the ledger recorded, each with a test.
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/BuzzLogExportTests.swift`, `Packages/MyGuideCore/Tests/MyGuideCoreTests/AutoOffTests.swift`

**Interfaces:**
- Produces:

  ```swift
  public struct KindCount: Sendable, Equatable { public var kind: String; public var buzzes, heard, skipped, ignored: Int }
  public enum BuzzLogExport {
      public static let header = "time,place,kind,tier,distance_m,outcome,level"
      public static func counts(_ entries: [BuzzLogEntry]) -> [KindCount]   // pending counts as a buzz only; sorted by buzzes desc, then kind asc
      public static func csv(_ entries: [BuzzLogEntry]) -> String          // header + one line per entry, "\n" endings, trailing newline
  }
  public enum AutoOffReason: Sendable, Equatable { case timeLimit, lowBattery }
  public enum AutoOff {
      public static let maxDuration: TimeInterval = 14_400
      public static let minBattery: Float = 0.15
      public static func reason(startedAt: Date, now: Date, batteryLevel: Float) -> AutoOffReason?  // batteryLevel < 0 = unknown
      public static func message(_ reason: AutoOffReason) -> String
  }
  ```

  **CSV fields:**
  - `time`: ISO 8601 UTC (`2026-10-27T09:15:00Z`);
  - `distance_m`: a rounded integer;
  - `outcome`: the raw value;
  - quoting per RFC 4180: a field containing a comma, a quote or a newline is wrapped in quotes, with inner quotes doubled.

  **`message` strings:** `.timeLimit` → `"Walking mode turned off after 4 hours."`, `.lowBattery` → `"Walking mode turned off: battery below 15%."`

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct AutoOffTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    @Test func limits() {
        // 4 h = 14 400 s: 14 399 → nil, 14 400 → timeLimit
        #expect(AutoOff.reason(startedAt: Self.t0, now: Self.t0 + 14_399, batteryLevel: 0.8) == nil)
        #expect(AutoOff.reason(startedAt: Self.t0, now: Self.t0 + 14_400, batteryLevel: 0.8) == .timeLimit)
        // battery: 0.15 → nil, 0.149 → lowBattery, −1 (unknown) → nil
        #expect(AutoOff.reason(startedAt: Self.t0, now: Self.t0, batteryLevel: 0.15) == nil)
        #expect(AutoOff.reason(startedAt: Self.t0, now: Self.t0, batteryLevel: 0.149) == .lowBattery)
        #expect(AutoOff.reason(startedAt: Self.t0, now: Self.t0, batteryLevel: -1) == nil)
        #expect(AutoOff.message(.timeLimit) == "Walking mode turned off after 4 hours.")
        #expect(AutoOff.message(.lowBattery) == "Walking mode turned off: battery below 15%.")
    }
}
@Suite struct BuzzLogExportTests {
    // 2026-10-27T09:00:00Z: 1970–2025 = 56·365 + 14 leap days = 20 454 days; Jan–Sep 2026 = 273, + 26 → 299;
    // 20 753 days · 86 400 = 1 793 059 200 s; + 9 h (32 400 s) = 1 793 091 600.
    static func e(_ kind: String, _ outcome: BuzzOutcome, name: String = "P", level: Int = 0, at: TimeInterval = 0) -> BuzzLogEntry {
        BuzzLogEntry(id: UUID(), at: Date(timeIntervalSince1970: 1_793_091_600 + at), placeID: "osm:node/1", placeName: name,
                     kind: kind, tier: 2, distance: 47.6, outcome: outcome, deepestLevel: level)
    }
    @Test func counts() {
        let log = [Self.e("historic=memorial", .skipped), Self.e("historic=memorial", .heard, level: 1),
                   Self.e("amenity=place_of_worship", .ignored), Self.e("historic=memorial", .pending)]
        #expect(BuzzLogExport.counts(log) == [
            KindCount(kind: "historic=memorial", buzzes: 3, heard: 1, skipped: 1, ignored: 0),
            KindCount(kind: "amenity=place_of_worship", buzzes: 1, heard: 0, skipped: 0, ignored: 1),
        ])
        #expect(BuzzLogExport.counts([]).isEmpty)
    }
    @Test func csv() {
        // 1 793 091 600 s = 2026-10-27T09:00:00Z (see helper); distance 47.6 → 48
        let csv = BuzzLogExport.csv([Self.e("historic=castle", .heard, name: "Hofburg, \"old\" palace", level: 2)])
        #expect(csv == "time,place,kind,tier,distance_m,outcome,level\n2026-10-27T09:00:00Z,\"Hofburg, \"\"old\"\" palace\",historic=castle,2,48,heard,2\n")
        #expect(BuzzLogExport.csv([]) == "time,place,kind,tier,distance_m,outcome,level\n")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail.** Run `swift test --filter "AutoOffTests|BuzzLogExportTests"`. Expected: compile errors.
- [ ] **Step 3: Implement** `BuzzLogExport` and `AutoOff`. Run `swift test`. Expected: PASS.
- [ ] **Step 4: Settings.**
  - Add a "Walking" section with "Buzzes per hour" (a `Stepper`, 5…60 in steps of 5, `@AppStorage("buzzesPerHour")`, default 20, showing the value). A change while walking calls `engine.setPerHour(_, at: .now)`.
  - Add "Buzz log" → `BuzzLogView`:
    - the per-kind counts table;
    - the newest 200 entries (time, place, kind, outcome);
    - a `ShareLink` exporting `MyGuide-buzz-log.csv` written to the temporary directory.
- [ ] **Step 5: Auto-off.**
  - Check on every location update and on a 60 s timer while walking. Battery level comes from `UIDevice.current.batteryLevel`, with `isBatteryMonitoringEnabled` on while walking.
  - On a reason: stop walking mode and post a notification with title "MyGuide" and body = `AutoOff.message(reason)`.
- [ ] **Step 6: README.** Add a "Walking mode" section:
  - how to start it;
  - "Always" location;
  - Time Sensitive notifications;
  - the buzz-log export;
  - auto-off;
  - the watch notes from Gate 0.
- [ ] **Step 7: Run the tests and the build check.** Expected: `swift test` passes; `** BUILD SUCCEEDED **`.
- [ ] **Step 8: Commit.** `git add -A && git commit -m "feat(walking): buzz log with export, buzzes-per-hour setting, auto-off"`

### Task 15: Watch app (path B), only if Gate 0 cleared it

Skip this task (and record why in the ledger) when the Gate 0 ruling is "waits for the paid account".

**Files:**
- Create: `MyGuideWatch/WalkScreen.swift`, `MyGuideWatch/WalkModel.swift`
- Modify: `MyGuideWatch/MyGuideWatchApp.swift`, `MyGuideWatch/PhoneLink.swift`, `MyGuideWatch/TellMeIntent.swift`, `MyGuideWatch/WorkoutKeeper.swift`, `MyGuide/Watch/WatchLink.swift`, `MyGuide/Walking/WalkingController.swift`, `MyGuide/WalkingCheck/*` (remove the check-only tone handling of `check.tell` only if the owner agrees; otherwise keep it)
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Walking/WatchMessage.swift`
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/WatchMessageTests.swift`

**Interfaces:**
- Produces: `WatchMessage` is the codec for the WatchConnectivity dictionaries. It lives in MyGuideCore, and the watch target also depends on the MyGuideCore package. Add watchOS 26 to the package platforms.

  ```swift
  public enum WatchMessage: Sendable, Equatable {
      case walkStarted, walkStopped
      case buzz(id: UUID, title: String, detail: String, bearing: Double?)   // bearing relative to walking direction, for the arrow
      case playing(id: UUID, level: Int), finished(id: UUID, level: Int)
      case tell(id: UUID?), more(id: UUID), skip(id: UUID)                    // tell(nil) = the newest buzz (Action button)
      public var dictionary: [String: Any] { get }
      public init?(dictionary: [String: Any])
  }
  ```

  Keys: `"type"` is one of `walk.started`, `walk.stopped`, `walk.buzz`, `walk.playing`, `walk.finished`, `walk.tell`, `walk.more` and `walk.skip`, plus `"id"` (a UUID string), `"title"`, `"detail"`, `"bearing"` (Double) and `"level"` (Int). An unknown type, a missing required field or a malformed UUID gives `nil`.

- [ ] **Step 1: Write the failing tests.**
  - Round-trip each case through `dictionary` and `init?(dictionary:)`.
  - `["type": "walk.buzz", "id": "not-a-uuid", ...]` gives `nil`.
  - `["type": "walk.nope"]` gives `nil`.
  - `walk.tell` without `"id"` gives `.tell(id: nil)`.
  - `walk.buzz` without `"bearing"` gives `bearing: nil`.
- [ ] **Step 2: Run the tests to verify they fail**, then implement, then run them again. Run `swift test --filter WatchMessageTests`. Expected: FAIL, then PASS.
- [ ] **Step 3: Phone side.**
  - On walking start, send `.walkStarted`; the watch starts `WorkoutKeeper` when it receives it, or when the owner opens the watch app while walking is on.
  - For each buzz, when `WatchLink.isReachable`, send `.buzz` **and** post the notification with `sound = nil`. When it's not reachable, post the notification as before.
  - Map `.tell(nil)` to the newest buzz id.
  - `.tell`, `.more` and `.skip` become the corresponding `WalkingCommand`.
  - Send `.playing`, `.finished` and `.walkStopped` as they happen.
- [ ] **Step 4: Watch side.**
  - `WalkScreen` shows the latest buzz: the title, `detail` and an arrow rotated by `bearing`.
  - Buttons:
    - "Tell me" while not playing;
    - "More" after `.finished` with level < 3;
    - "Skip" while playing or after a buzz.
  - On `.buzz`, play the distinct pattern: `.directionUp`, then `.success` 0.3 s later.
  - `TellMeIntent` sends `.tell(id: nil)`.
- [ ] **Step 5: Run the build checks** (iOS and watchOS schemes, as in Task 3). Expected: both `** BUILD SUCCEEDED **`.
- [ ] **Step 6: Commit.** `git add -A && git commit -m "feat(watch): walking screen with distinct buzz, Tell me / More / Skip and Action button"`

- [ ] **Step 7: Gate 4 (owner).**
  1. **Distinct buzz:** start walking mode. The watch app starts its workout, and buzzes now feel like the double tap, distinct from other notifications.
  2. **Watch screen:** it shows the title, the distance and an arrow pointing at the place.
  3. **Tell me:** "Tell me" on the watch, or the Action button, plays the newest buzz's story. "More" and "Skip" work.
  4. **Settings:** changing "Buzzes per hour" to 60 makes buzzes come noticeably more often in a dense area.
  5. **Buzz log:** export the CSV and send it to Claude for tuning the tiers.
  6. **Auto-off:** after 4 hours (or at 15% battery), walking mode switches itself off with a notification.
