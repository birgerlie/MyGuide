# Diary and Day Story Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A day-sectioned diary of everything the app told plus imported library photos, and a per-day "day story": one caption per photo and a short summary, shown as full-screen pages and shareable as images.

**Architecture:**
- **Core (`Packages/MyGuideCore`)** holds everything testable:
  - the new SwiftData entities, with a store version 3 and a lightweight migration;
  - the diary query and grouping;
  - matching photos to events;
  - the day-story prompt, schema and decoding;
  - a multi-image OpenAI call;
  - `DayStoryFlow`.
- **The app** holds the SwiftUI screens, PhotosPicker import, ImageRenderer sharing and wiring.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, PhotosUI/PhotoKit, Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-28-diary-and-day-story-design.md` (section 8 settles the builder-check questions).

## Global Constraints

- Swift 6 strict concurrency, iOS 26, no new dependencies.
- OpenAI only, `store: false`, key in the Keychain, never logged.
- The eight existing `@Model` classes stay unchanged. `MemorySchemaV2` lists those eight explicitly. `MemorySchemaV3` = the eight + `LibraryPhotoRecord` + `DayStoryRecord`. `MemoryMigrationPlan` gains `.lightweight(V2 → V3)`.
- Values from the spec:
  - Matching: ±10 min, 150 m. Upload cap: 12 photos (first and last kept, evenly spread). Upload size: 768 px, JPEG 0.7, `detail: "low"`.
  - Captions ≤ 40 words; summary 2–3 sentences. Cache key `"myguide-day-v1"`.
  - Import: up to 30 photos per pick; stored 1536 px + 400 px thumbnail, JPEG 0.7. Share pages: 1080 × 1920.
- Photo ids are `capture:<uuid>` and `library:<uuid>`. The day key is `yyyy-MM-dd` in the phone's time zone.
- Nothing is sent to any service on import.
- Core tests: `cd Packages/MyGuideCore && swift test`.
- App build (never into the repo dir; the watch target currently cannot be signed, so build without signing):

  ```
  xcodegen generate && xcodebuild -project MyGuide.xcodeproj -scheme MyGuide -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/claude-501/-Users-birger-code-MyGuide/43e8ac03-ea1c-4b4d-b907-cc5e890c10a9/scratchpad/dd-diary CODE_SIGNING_ALLOWED=NO -quiet build
  ```
- Each numeric assertion has its hand computation in a comment above it. Use `#require`, not force unwraps. Show RED evidence. Write complete code with no TODOs.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push.

## Review Focus

1. **Opening an existing V2 store** must migrate without data loss. Test `v2StoreOpensAsV3` in Task 1.
2. **Importing the same library photo twice** must store it once. Test `reimportIsSkipped` in Task 1.
3. **A day with more than 12 photos** must keep the first and last, spread the rest, and report "12 of N". Test `capKeepsFirstAndLastEvenlySpread` in Task 3.
4. **A caption for an unknown photo id, or a missing caption,** must not crash and must not mis-assign. Test `decodeDropsUnknownIDs` in Task 3.
5. **Unheard buzz stories** must not appear in the diary or in the events. Test `unheardBuzzIsHidden` in Task 2.

---

### Task 1: Store version 3 — library photos and day stories

**Files:**
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/Memory/MemoryModels.swift` (new models, V2 explicit list, V3, plan stage)
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Memory/DiaryMemory.swift` (MemoryStore extension)
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/DiaryMemoryTests.swift`; extend `MigrationTests`

**Interfaces (produces):**
```swift
@Model public final class LibraryPhotoRecord {
    @Attribute(.unique) public var id: UUID
    @Attribute(.unique) public var assetIdentifier: String
    public var takenAt: Date
    public var latitude: Double?
    public var longitude: Double?
    @Attribute(.externalStorage) public var photoJPEG: Data
    @Attribute(.externalStorage) public var thumbnailJPEG: Data
    public var importedAt: Date
}
@Model public final class DayStoryRecord {
    @Attribute(.unique) public var dayKey: String
    public var createdAt: Date
    public var language: String
    public var summary: String
    public var captionsJSON: Data        // [String: String] photo id → caption
    public var photoIDs: [String]        // page order
    public var totalPhotos: Int
}
public struct DayStory: Sendable, Equatable { dayKey, createdAt, language: StoryLanguage, summary, captions: [String: String], photoIDs: [String], totalPhotos: Int }
public enum MemorySchemaV3: VersionedSchema   // 3.0.0, eight models + the two new ones
extension MemoryStore {
    /// nil when assetIdentifier is already stored. Downscales to 1536/400 px JPEG 0.7.
    public func importLibraryPhoto(jpeg: Data, assetIdentifier: String, takenAt: Date, coordinate: Coordinate?) throws -> UUID?
    public func deleteLibraryPhoto(id: UUID) throws
    public func libraryPhoto(id: UUID) throws -> LibraryPhotoRecord?
    public func saveDayStory(_ story: DayStory) throws          // replaces same dayKey
    public func dayStory(dayKey: String) throws -> DayStory?
}
```
Live code must open the store through `MemorySchemaV3`; find where V2 is used (`AppServices`, tests) and switch it.

- [ ] Step 1: Write failing tests:
  - `importStoresDownscaledPhoto` (long side ≤ 1536, thumbnail ≤ 400);
  - `reimportIsSkipped` (the second import returns nil; count 1);
  - `deleteRemovesPhoto`;
  - `dayStoryRoundTripsAndReplaces`;
  - `v2StoreOpensAsV3`: create an on-disk store with `MemorySchemaV2` (Schema + ModelConfiguration at a temp URL), insert a `CaptureRecord` and a `WalkStoryRecord`, close it, reopen with `MemorySchemaV3` + `MemoryMigrationPlan`, and check that both records survive and a library photo can be inserted.
- [ ] Step 2: Run and confirm they FAIL. Step 3: Implement. Step 4: Run the full suite and confirm it passes. Step 5: Commit `feat(memory): store v3 with library photos and day stories`.

### Task 2: Diary query and grouping

**Files:**
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Diary/Diary.swift`
- Modify: `Memory/DiaryMemory.swift`
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/DiaryTests.swift`

**Interfaces (produces):**
```swift
public struct DiaryEntry: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case photoStory, buzz, stop, libraryPhoto }
    public var id: String              // "capture:<uuid>", "walk:<uuid>", "library:<uuid>"
    public var kind: Kind
    public var time: Date
    public var title: String           // capture title / walk title / "" for library photos
    public var placeName: String?      // buzz place name, capture subject
    public var coordinate: Coordinate? // spec 8.4: buzz → place coordinate; stop → story position; capture → capture coordinate; library → photo coordinate
    public var firstSentence: String?  // RecentStories.firstSentence of level 1; nil for library photos
    public var city: String?           // Address.city when known (walk addressJSON, capture grounding address)
    public var hasPhoto: Bool          // photo stories and library photos
}
public struct DiaryDay: Sendable, Equatable, Identifiable { public var id: String /* dayKey */; public var date: Date; public var city: String?; public var entries: [DiaryEntry] }
public enum Diary {
    public static func dayKey(_ date: Date, timeZone: TimeZone) -> String            // "yyyy-MM-dd"
    /// Newest day first; entries oldest first; ties by id. city = first entry (by time) with a city.
    public static func days(_ entries: [DiaryEntry], timeZone: TimeZone) -> [DiaryDay]
}
extension MemoryStore {
    /// Every capture, stop story, heard buzz story (BuzzRecord.deepestLevel ≥ 1) and library photo.
    public func diaryEntries() throws -> [DiaryEntry]
}
```
- [ ] Step 1: Write failing tests:
  - `daysGroupByLocalDateNewestFirst`: entries at 23:30 and 00:30 Oslo time fall on two days;
  - `entriesOldestFirstWithinDay`;
  - `cityIsFirstEntryWithCity`;
  - `unheardBuzzIsHidden`;
  - `heardBuzzUsesPlaceCoordinate`;
  - `stopUsesStoryPosition`;
  - `libraryPhotoEntry`.
- [ ] Steps 2–4: Run and confirm FAIL, implement, run and confirm PASS. Step 5: Commit `feat(diary): diary entries grouped by day`.

### Task 3: Day story matching, prompt and decoding

**Files:**
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Diary/DayStoryPlan.swift`
- Modify: `Story/PromptBuilder.swift` (day story section)
- Test: `DayStoryPlanTests.swift`, `DayStoryPromptTests.swift`

**Interfaces (produces):**
```swift
public struct DayStoryPhoto: Sendable, Equatable { public var id: String; public var time: Date; public var coordinate: Coordinate?; public var storyTitle: String? /* photo-story photos */ }
public struct DayStoryPlan: Sendable, Equatable {
    public static let matchWindow: TimeInterval = 600, matchDistance = 150.0, photoCap = 12
    public var photos: [DayStoryPhoto]        // chosen, time order, ≤ 12
    public var matches: [String: DiaryEntry]  // library photo id → matched event
    public var events: [DiaryEntry]           // non-photo-library entries of the day, time order
    public var totalPhotos: Int
    public static func make(day: DiaryDay) -> DayStoryPlan
    /// First and last always; the rest at indices round(i·(n−1)/(cap−1)).
    static func choose(_ photos: [DayStoryPhoto], cap: Int) -> [DayStoryPhoto]
    /// Smallest time gap within ±10 min; when both have positions also ≤ 150 m.
    static func match(_ photo: DayStoryPhoto, events: [DiaryEntry]) -> DiaryEntry?
}
extension PromptBuilder {
    public static let dayStoryInstructions: String   // the guide-voice HONESTY section verbatim + task rules from spec 5.2
    public static let dayPromptCacheKey = "myguide-day-v1"
    static func dayStoryInput(plan: DayStoryPlan, day: DiaryDay, language: StoryLanguage, timeZone: TimeZone) -> String
    static let dayStorySchema: JSONValue
    /// Unknown photo ids are dropped; an empty or blank summary throws OpenAIError.malformedResponse.
    static func decodeDayStory(_ json: Data, photoIDs: [String]) throws -> (summary: String, captions: [String: String])
}
```
- Photo lines in the input:
  - `- [p1] 12:03, matches 11:58 Akershus Fortress`
  - `- [p2] 12:41, photo story: Oslo Cathedral`
  - `- [p3] 13:10, no matching event`
- The model sees short ids `p1…pN`. Map them back to the real photo ids in `decodeDayStory`, or have the flow do it; pick one and test it.
- Event lines: `- HH:mm <kind words>: <title or place> (<kind tag>) — "<first sentence>"`.
- Day line: `Day: Wednesday 28 October 2026, Oslo`. Use English, from `en_US_POSIX`.

- [ ] Step 1: Write failing tests:
  - `matchPicksSmallestGapWithinWindow`, with the boundaries 600 s inside and 601 s outside;
  - `matchRequiresDistanceWhenBothHavePositions`, with the boundaries 150 m and 151 m;
  - `matchByTimeOnlyWithoutPosition`;
  - `capKeepsFirstAndLastEvenlySpread`: from 30 photos, the indices are [0,3,5,8,11,13,16,18,21,24,26,29]. Compute these by hand in a comment as round(i·29/11);
  - `under cap keeps all`;
  - `inputFieldOrderAndLines`;
  - `instructionsContainHonestySectionVerbatim`: compare against the HONESTY block cut from `systemInstructions`;
  - `decodeDropsUnknownIDs`;
  - `decodeBlankSummaryThrows`.
- [ ] Steps 2–4: Run and confirm FAIL, implement, run and confirm PASS. Step 5: Commit `feat(diary): day story plan, prompt and decoding`.

### Task 4: Multi-image request and DayStoryFlow

**Files:**
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/OpenAI/OpenAIClient.swift`
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/Diary/DayStoryFlow.swift`
- Test: `OpenAIClientTests`, `DayStoryFlowTests.swift`

**Interfaces (produces):**
```swift
// OpenAIClient: new overload; the existing single-image respond is unchanged.
public func respond(model: String, reasoningEffort: String?, instructions: String, text: String,
                    images: [Data], imageDetail: String, schemaName: String, schema: JSONValue,
                    promptCacheKey: String?) async throws -> (json: Data, usage: TokenUsage)
public struct DayStoryFlow: Sendable {
    public static let uploadLongSide = 768
    public init(openAI: OpenAIClient, models: OpenAIModels = .current, timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = Date.init,
                photoData: @escaping @Sendable (String) async -> Data?)   // full JPEG for a photo id; nil = skipped
    /// Throws when the day has no photos (DayStoryError.noPhotos).
    public func write(day: DiaryDay, language: StoryLanguage) async throws -> (DayStory, [UsageEntry])
}
public enum DayStoryError: Error, Equatable { case noPhotos }
```
- Photos whose data is nil, or that fail to downscale, are skipped. They are not sent and are counted only in `totalPhotos`.
- If every chosen photo is skipped, throw `.noPhotos`.
- Images are attached in plan order with `detail: "low"`.

- [ ] Step 1: Write failing tests:
  - the request body has N `input_image` parts, each with `"detail":"low"`, plus `prompt_cache_key` and `store:false`;
  - the flow sends ≤ 12 images for a 20-photo day, and the resulting `DayStory.totalPhotos` is 20;
  - a skipped photo is not sent;
  - a day with no photos throws `.noPhotos`;
  - usage is recorded with kind `.story` and the story model.
- [ ] Steps 2–4: Run and confirm FAIL, implement, run and confirm PASS. Step 5: Commit `feat(diary): multi-image request and day story flow`.

### Task 5: App — diary screen and import

**Files:**
- Create: `MyGuide/Diary/DiaryView.swift`, `MyGuide/Diary/DiaryRows.swift`, `MyGuide/Diary/LibraryImport.swift`
- Modify: `MyGuide/Home/HomeScreen.swift` (Diary button + route), `MyGuide/AppServices.swift` (store V3 if not done in Task 1)

**Behaviour:** spec 4.
- Sections come from `Diary.days(try memory.diaryEntries(), timeZone: .current)`. Reload when the view appears and after import or delete.
- Rows per kind:
  - Tapping a photo story opens the existing `StoryView` via `memory.session(for:)`, the same way `HistoryView` does.
  - Tapping a buzz or stop story opens the existing walk story route.
  - Tapping a library photo opens a full-screen image.
  - Swiping deletes library photos only.
- "Add photos": `PhotosPicker(selection:, maxSelectionCount: 30, matching: .images)`. For each item:
  1. load `Data`;
  2. take the time from `PhotoMetadata.read(from:)?.takenAt`, else from the `PHAsset` creation date (request read access like `PhotoImport`), else skip;
  3. take the position from EXIF, else from the `PHAsset` location;
  4. if there is no `itemIdentifier`, skip;
  5. call `memory.importLibraryPhoto`.

  Afterwards, show one summary alert: "Added N photos" plus "M skipped (no date)" or "already added" when any were skipped.
- The day header shows the weekday, date and city, and a "Day story" button enabled when any entry has `hasPhoto`. It opens Task 6's screen.

- [ ] Step 1: Implement. Step 2: Run the app build; it must succeed with no new warnings. Step 3: Run the core suite and confirm it passes. Step 4: Commit `feat(app): diary screen with library photo import`.

### Task 6: App — day story pages and sharing

**Files:**
- Create: `MyGuide/Diary/DayStoryView.swift`, `MyGuide/Diary/DayStoryModel.swift`
- Modify: `MyGuide/AppServices.swift` (`makeDayStoryFlow()`; `photoData` closure: `capture:` loads `CaptureRecord.photoJPEG`, `library:` loads `LibraryPhotoRecord.photoJPEG`, on the main actor)

**Behaviour:** spec 5.4–5.6.
- **Opening:** if `memory.dayStory(dayKey:)` exists, show it. Otherwise write a new one, with a progress view.
- **Writing:**
  - Errors show an alert with `UserFacingMessage.message(for:)`.
  - A missing key shows the existing missing-key text.
  - Record usage with `services.recordUsage`, and save with `memory.saveDayStory`.
- **Pages:**
  - Full-screen `TabView(.page)`.
  - Page 1 shows the summary over the first photo, plus "12 of N photos" when `totalPhotos > photoIDs.count`.
  - Then one page per photo id whose photo still exists: the image, the caption at the bottom on a dark gradient, and the time in the corner.
- **Toolbar:** Close, Share, and "Write again", which confirms and then replaces the story.
- **Share:** render each page with `ImageRenderer` at 1080 × 1920 into `UIImage`s, then offer them with `ShareLink(items:)` (or a `UIActivityViewController` wrapper).

- [ ] Step 1: Implement. Step 2: Run the app build and the core suite; both must pass. Step 3: Commit `feat(app): day story pages and sharing`.
