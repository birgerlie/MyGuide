# Phase 1: Photo Story Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An iPhone app where the owner takes (or picks) a photo and gets a short, true, people-first story about it. The story is grounded in GPS position, compass heading, OpenStreetMap and Wikipedia, shown as text and spoken aloud, with deeper levels, memory, Norwegian, "then" images and a cost counter.

**Architecture:** All logic that can be tested lives in a local Swift package, `MyGuideCore`, tested with `swift test` on macOS. It covers geo math, EXIF, image scaling, the HTTP clients, prompt building, the story flow, the SwiftData memory and pricing. The iOS app target, `MyGuide`, is a thin SwiftUI shell plus platform code that needs a device: camera, CoreLocation, MapKit reverse geocoding and audio playback. XcodeGen generates the Xcode project from `project.yml`. The generated `.xcodeproj` is committed, so the owner only opens it and presses Run.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, SwiftData, AVFoundation, CoreLocation, MapKit, ImageIO, Swift Testing, XcodeGen. No third-party Swift dependencies.

**Spec:** `docs/superpowers/specs/2026-10-26-myguide-design.md` (sections 6, 7, 8.1, 8.2, 9 step 1, 10, 11)

## Global Constraints

- Deployment floor: iOS 26.0 for the app; the package declares `.iOS(.v26), .macOS(.v26)`, swift-tools-version 6.2. Spec 11: "Minimum iOS/watchOS version: the newest versions the owner's devices run, unless that blocks something." Task 1 checks the phone's version.
- One AI provider: OpenAI for vision, text, speech and images (spec 6). No other AI service.
- The API key is stored only in the iOS Keychain and never appears in source, logs or the repo (spec 7).
- Story lengths: level 1 = 20 s ≈ 50 words, level 2 = +30 s ≈ 75 words, level 3 = +2 min ≈ 300 words, at 150 spoken words per minute (spec 6).
- Story voice: people and scenes first; dates and architecture only in support; legend and uncertainty labelled; never invent history (spec 5, 6, 10).
- Language: English by default; Norwegian (Bokmål) as a setting (spec 6).
- Every generated image is labelled exactly `AI reconstruction — not a real photo` wherever it is shown (spec 5).
- No shops, restaurants or cafés as candidate places (spec 5, 8.3).
- Requests to OSM and Wikipedia send `User-Agent: MyGuide/0.1 (https://github.com/birgerlie/MyGuide)` (spec 11: "respecting service usage policies").
- OpenAI requests set `"store": false` (spec 7, privacy).
- Phase 1 builds in spec steps 0–4. Each milestone ends with the app running on the owner's iPhone before the next starts (spec 9).
- Themes are phase 4. Phase 1 prompts carry no theme (YAGNI).
- Test command: `swift test --package-path Packages/MyGuideCore`. App build check: `xcodebuild -project MyGuide.xcodeproj -scheme MyGuide -destination 'generic/platform=iOS Simulator' build`.

## Review Focus

1. **Compass heading wrong when the phone is held upright to take a photo** (device-orientation or reference-frame mistakes, or magnetic disturbance). The app must name the building in front, not the one behind. Pinned by the `CompassReading` tests in Task 2 and the landmark check on the device in Task 10.
2. **Overpass down or slow** (429/504 are common). The story must still come, grounded on Wikipedia, flagged "map data unavailable", and the app must not hang. Pinned by the GroundingService failure tests in Task 7 and the request-timeout assertion in Task 5.
3. **Device locale with decimal commas (Norwegian).** Coordinates in Overpass and Wikipedia URLs must always use `.` decimals. Pinned by exact-string query assertions in Tasks 5 and 6.
4. **No key, bad key, no credit, or offline in the middle of the flow.** The app must show a plain message, keep the photo, and offer retry. Pinned by the error-mapping tests in Task 4, the `UserFacingMessage` tests in Task 9, and the retry check in Task 10.
5. **The model refuses, or returns an ID for a place that does not exist.** No crash, no fake story, no false place match. Pinned by the refusal test in Task 4 and the matched-ID validation test in Task 8.

---

## File Structure

```
project.yml                              XcodeGen project definition
Config/Signing.xcconfig                  includes optional Local.xcconfig
Config/Local.xcconfig.example            template: DEVELOPMENT_TEAM
MyGuide/                                 iOS app target
  MyGuideApp.swift                       app entry, ModelContainer, AppServices
  AppServices.swift                      builds clients/flow from Keychain + settings
  SelfCheck/SelfCheckView.swift          device capability check (milestone 0)
  Capture/LocationProvider.swift         CLLocationManager: location + heading
  Capture/CameraController.swift         AVCaptureSession + photo output + FOV
  Capture/CameraPreview.swift            UIViewRepresentable preview layer
  Capture/CaptureScreen.swift            camera UI, shutter, library picker, HUD
  Story/StoryViewModel.swift             @Observable state machine for one session
  Story/StoryView.swift                  text, levels, play, more, then-image
  Story/AudioPlayer.swift                AVAudioSession + AVAudioPlayer
  History/HistoryView.swift              past sessions (milestone 3)
  Settings/SettingsView.swift            API key, language, usage, device check
  Platform/MapKitReverseGeocoder.swift   ReverseGeocoding via MKReverseGeocodingRequest
Packages/MyGuideCore/
  Package.swift
  Sources/MyGuideCore/
    Secrets/KeychainStore.swift
    Geo/Coordinate.swift                 Coordinate, GeoMath
    Geo/FieldOfView.swift                FOV, cone, CompassReading, compass points
    Capture/CaptureContext.swift
    Capture/PhotoMetadata.swift          EXIF GPS/heading/date
    Capture/ImageProcessing.swift        downscale with orientation
    Net/HTTPClient.swift                 protocol + URLSession impl
    Net/JSONValue.swift
    OpenAI/OpenAIClient.swift            responses, speech, images
    OpenAI/OpenAIError.swift
    OpenAI/OpenAIModels.swift
    Grounding/Candidate.swift            Candidate, RankedCandidate, Address, Grounding
    Grounding/OverpassClient.swift
    Grounding/WikipediaClient.swift
    Grounding/CandidateRanker.swift      merge + rank
    Grounding/GroundingService.swift
    Story/StoryTypes.swift               StoryLevel, StoryLanguage, IdentifiedStory, PriorStory, StorySession
    Story/PromptBuilder.swift            instructions, inputs, schemas, then-image prompt
    Story/PhotoStoryFlow.swift
    Story/SpeechService.swift
    Story/UserFacingMessage.swift
    Memory/MemoryModels.swift            SwiftData @Model types + schema
    Memory/MemoryStore.swift
    Usage/UsageEntry.swift
    Usage/PriceTable.swift
  Tests/MyGuideCoreTests/
    Support/StubHTTPClient.swift
    Support/TestImages.swift             makes JPEGs with given size/EXIF
    (one *Tests.swift per source unit, named in each task)
```

---

## Milestone 0: Signing check (spec 9, step 0)

### Task 1: Project scaffold, Keychain store, device self-check

Spec 7: "Verify before any feature work in phase 1: a minimal app signed with the free Personal Team installs and runs on the owner's iPhone with camera, location ("when in use") and Keychain access, and can save to a local SwiftData store."

**Files:**
- Create: `project.yml`, `Config/Signing.xcconfig`, `Config/Local.xcconfig.example`, `Packages/MyGuideCore/Package.swift`, `Packages/MyGuideCore/Sources/MyGuideCore/Secrets/KeychainStore.swift`, `MyGuide/MyGuideApp.swift`, `MyGuide/SelfCheck/SelfCheckView.swift`
- Modify: `.gitignore` (add `Config/Local.xcconfig`), `README.md` (add "Run it on your iPhone")
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/KeychainStoreTests.swift`

**Interfaces:**
- Produces: `public struct KeychainStore: Sendable { public init(service: String); public func read(_ account: String) throws -> String?; public func write(_ value: String, account: String) throws; public func delete(_ account: String) throws }`, `public enum KeychainError: Error, Equatable { case unexpectedStatus(Int32) }`. App constants: service `"io.github.birgerlie.MyGuide"`, account `"openai-api-key"`.

- [ ] **Step 1: Write `Package.swift`** with swift-tools-version 6.2, platforms `.iOS(.v26), .macOS(.v26)`, library product `MyGuideCore`, target `MyGuideCore`, test target `MyGuideCoreTests`.

- [ ] **Step 2: Write the failing Keychain tests**

```swift
import Testing
import Foundation
@testable import MyGuideCore

@Suite struct KeychainStoreTests {
    let store = KeychainStore(service: "io.github.birgerlie.MyGuide.tests.\(UUID().uuidString)")

    @Test func readMissingReturnsNil() throws {
        #expect(try store.read("absent") == nil)
    }
    @Test func writeThenReadRoundTrips() throws {
        try store.write("sk-test-123", account: "k")
        #expect(try store.read("k") == "sk-test-123")
        try store.delete("k")
    }
    @Test func writeOverwritesExisting() throws {
        try store.write("one", account: "k")
        try store.write("two", account: "k")
        #expect(try store.read("k") == "two")
        try store.delete("k")
    }
    @Test func deleteMissingDoesNotThrow() throws {
        try store.delete("never-written")
    }
    @Test func emptyStringIsStoredAsEmpty() throws {
        try store.write("", account: "k")
        #expect(try store.read("k") == "")
        try store.delete("k")
    }
}
```

- [ ] **Step 3: Run and confirm failure.** Run `swift test --package-path Packages/MyGuideCore`. Expected: compile error, `KeychainStore` not found.

- [ ] **Step 4: Implement `KeychainStore`.** Use `kSecClassGenericPassword` keyed on service + account, with `kSecAttrAccessibleAfterFirstUnlock`. `write` tries `SecItemUpdate` first and falls back to `SecItemAdd` on `errSecItemNotFound`. `delete` treats `errSecItemNotFound` as success. Any other status throws `.unexpectedStatus`.

- [ ] **Step 5: Run the tests.** Expected: 5 pass.

- [ ] **Step 6: Write `project.yml`**

```yaml
name: MyGuide
options:
  bundleIdPrefix: io.github.birgerlie
  deploymentTarget: { iOS: "26.0" }
configFiles:
  Debug: Config/Signing.xcconfig
  Release: Config/Signing.xcconfig
packages:
  MyGuideCore: { path: Packages/MyGuideCore }
targets:
  MyGuide:
    type: application
    platform: iOS
    sources: [MyGuide]
    dependencies: [{ package: MyGuideCore }]
    info:
      path: MyGuide/Info.plist
      properties:
        CFBundleDisplayName: MyGuide
        UILaunchScreen: {}
        UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]
        NSCameraUsageDescription: "MyGuide uses the camera to photograph what you want a story about."
        NSLocationWhenInUseUsageDescription: "MyGuide uses your exact position and compass heading to work out what you are looking at."
        NSPhotoLibraryUsageDescription: "MyGuide reads where a picked photo was taken so it can tell its story."
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: io.github.birgerlie.MyGuide
        SWIFT_VERSION: "6.0"
        CODE_SIGN_STYLE: Automatic
        TARGETED_DEVICE_FAMILY: "1"
```

`Config/Signing.xcconfig` contains exactly `#include? "Local.xcconfig"`. `Config/Local.xcconfig.example` contains `DEVELOPMENT_TEAM = YOUR_TEAM_ID`, plus a comment saying the team ID is shown in Xcode → Settings → Accounts → (Personal Team).

- [ ] **Step 7: Implement `SelfCheckView`** and make it the root view in `MyGuideApp`. It runs four checks and shows each with ✓/✗ and a detail line:
  1. Camera: `AVCaptureDevice.requestAccess(for: .video)` is granted.
  2. Location: when-in-use authorisation is granted, one fix arrives within 15 s (shows its ±accuracy), and `CLLocationManager.headingAvailable()` is true.
  3. Keychain: write, read and delete account `"selfcheck"` under the app service.
  4. SwiftData: an on-disk `ModelContainer` for a `@Model final class SelfCheckProbe { var createdAt: Date }`, stored in its own file `selfcheck.store` in Application Support. Insert, save, fetch count ≥ 1, delete.

  The view stays in the app; Task 10 moves it under Settings → Device check.

- [ ] **Step 8: Generate and build.** Run `xcodegen generate`, then the app build check. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Update `README.md`** with a section titled "Run it on your iPhone":
  1. Install Xcode.
  2. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set the team ID.
  3. Open `MyGuide.xcodeproj`, plug in the iPhone and press Run.
  4. On the phone, trust the developer in Settings → General → VPN & Device Management.
  5. Re-run from Xcode every 7 days (free account).
  6. Check that the phone runs iOS 26 or newer (Settings → General → About).

- [ ] **Step 10: Commit**

```bash
git add project.yml Config/Signing.xcconfig Config/Local.xcconfig.example .gitignore README.md MyGuide MyGuide.xcodeproj Packages docs
git commit -m "feat: project scaffold, Keychain store and device self-check"
```

- [ ] **Step 11: Milestone 0 gate (owner, on the phone).** All four rows show ✓. If any row fails, stop and report it; spec 7 says blocked capabilities wait for the paid account. Do not start Task 2 until this passes.

---

## Milestone 1: Photo + grounding + first story as text (spec 9, step 1)

### Task 2: Geo math, field of view, compass reading

Spec 8.1.3: "the field-of-view cone widens with the reported heading accuracy (the cone is the camera's horizontal field of view plus twice the heading accuracy on each side). If heading accuracy is unavailable or worse than 45°, the heading is treated as unknown."

**Files:**
- Create: `Sources/MyGuideCore/Geo/Coordinate.swift`, `Sources/MyGuideCore/Geo/FieldOfView.swift`
- Test: `Tests/MyGuideCoreTests/GeoMathTests.swift`, `Tests/MyGuideCoreTests/FieldOfViewTests.swift`

**Interfaces:**
- Produces:
  - `public struct Coordinate: Sendable, Equatable, Hashable, Codable { public var latitude: Double; public var longitude: Double }`
  - `public enum GeoMath { static let earthRadius = 6_371_000.0; static func distance(_ a: Coordinate, _ b: Coordinate) -> Double /* metres, haversine */; static func bearing(from: Coordinate, to: Coordinate) -> Double /* 0..<360 */; static func angularDifference(_ a: Double, _ b: Double) -> Double /* 0...180 */ }`
  - `public enum FieldOfView { static let maxUsableHeadingAccuracy = 45.0; static let landscapeFOV = 69.4; static func portraitHorizontalFOV(landscapeFOV: Double) -> Double; static func assumedHorizontalFOV(pixelWidth: Int, pixelHeight: Int) -> Double; static func coneHalfWidth(horizontalFOV: Double, headingAccuracy: Double) -> Double; static func usableHeading(_ heading: Double?, accuracy: Double?) -> Double?; static func isInView(bearing: Double, heading: Double, halfWidth: Double) -> Bool; static func compassPoint(_ degrees: Double) -> String }`
  - `public struct CompassReading: Sendable, Equatable { public var heading: Double; public var accuracy: Double?; public init(trueHeading: Double, magneticHeading: Double, headingAccuracy: Double) }`

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct GeoMathTests {
    let origin = Coordinate(latitude: 0, longitude: 0)

    @Test func bearingCardinals() {
        // θ = atan2(sinΔλ·cosφ2, cosφ1·sinφ2 − sinφ1·cosφ2·cosΔλ)
        // (0,0)->(0,1):  atan2(sin1°, 0)   = 90°
        // (0,0)->(1,0):  atan2(0, sin1°)   = 0°
        // (0,0)->(-1,0): atan2(0, −sin1°)  = 180°
        // (0,0)->(0,-1): atan2(−sin1°, 0)  = −90° → 270°
        #expect(abs(GeoMath.bearing(from: origin, to: .init(latitude: 0, longitude: 1)) - 90) < 1e-9)
        #expect(abs(GeoMath.bearing(from: origin, to: .init(latitude: 1, longitude: 0)) - 0) < 1e-9)
        #expect(abs(GeoMath.bearing(from: origin, to: .init(latitude: -1, longitude: 0)) - 180) < 1e-9)
        #expect(abs(GeoMath.bearing(from: origin, to: .init(latitude: 0, longitude: -1)) - 270) < 1e-9)
    }
    @Test func distanceHaversine() {
        // Equator, Δλ=1°: d = R·π/180 = 6_371_000·0.0174532925 = 111_194.93 m
        #expect(abs(GeoMath.distance(origin, .init(latitude: 0, longitude: 1)) - 111_194.93) < 0.5)
        // Lat 60°, Δλ=1°: sin(c/2) = cos60°·sin(0.5°) = 0.5·0.00872654 = 0.00436327
        // c = 2·asin(0.00436327) = 0.00872657 rad; d = 0.00872657·6_371_000 = 55_596.97 m
        #expect(abs(GeoMath.distance(.init(latitude: 60, longitude: 0), .init(latitude: 60, longitude: 1)) - 55_596.97) < 1)
        #expect(GeoMath.distance(origin, origin) == 0)
    }
    @Test func angularDifferenceWraps() {
        // |350−10| = 340 → 360−340 = 20; symmetric; opposite = 180
        #expect(GeoMath.angularDifference(350, 10) == 20)
        #expect(GeoMath.angularDifference(10, 350) == 20)
        #expect(GeoMath.angularDifference(90, 270) == 180)
        #expect(GeoMath.angularDifference(0, 0) == 0)
    }
}

@Suite struct FieldOfViewTests {
    @Test func portraitFOVFromLandscape() {
        // portrait hFOV = 2·atan(tan(F/2)·3/4)
        // F=69.4: tan(34.7°)=0.6924; ·0.75=0.5193; atan=27.44°; ·2 = 54.88°
        // F=90:   tan(45°)=1;        ·0.75=0.75;   atan=36.87°; ·2 = 73.74°
        #expect(abs(FieldOfView.portraitHorizontalFOV(landscapeFOV: 69.4) - 54.88) < 0.05)
        #expect(abs(FieldOfView.portraitHorizontalFOV(landscapeFOV: 90) - 73.74) < 0.05)
    }
    @Test func assumedFOVByAspect() {
        #expect(FieldOfView.assumedHorizontalFOV(pixelWidth: 4032, pixelHeight: 3024) == 69.4)
        #expect(abs(FieldOfView.assumedHorizontalFOV(pixelWidth: 3024, pixelHeight: 4032) - 54.88) < 0.05)
    }
    @Test func coneHalfWidth() {
        // fov/2 + 2·acc: 55/2 + 2·10 = 47.5;  54.88/2 + 2·0 = 27.44
        #expect(FieldOfView.coneHalfWidth(horizontalFOV: 55, headingAccuracy: 10) == 47.5)
        #expect(abs(FieldOfView.coneHalfWidth(horizontalFOV: 54.88, headingAccuracy: 0) - 27.44) < 1e-9)
    }
    @Test func usableHeadingRules() {
        #expect(FieldOfView.usableHeading(120, accuracy: 10) == 120)
        #expect(FieldOfView.usableHeading(120, accuracy: 45) == 120)   // boundary: 45 is usable
        #expect(FieldOfView.usableHeading(120, accuracy: 45.1) == nil)
        #expect(FieldOfView.usableHeading(120, accuracy: nil) == nil)
        #expect(FieldOfView.usableHeading(120, accuracy: -1) == nil)   // CoreLocation "invalid"
        #expect(FieldOfView.usableHeading(nil, accuracy: 5) == nil)
    }
    @Test func inViewAcrossNorth() {
        // heading 350, half 47.5: bearing 30 → diff 40 ≤ 47.5 in; bearing 40 → diff 50 out
        #expect(FieldOfView.isInView(bearing: 30, heading: 350, halfWidth: 47.5))
        #expect(!FieldOfView.isInView(bearing: 40, heading: 350, halfWidth: 47.5))
        #expect(FieldOfView.isInView(bearing: 37.5, heading: 350, halfWidth: 47.5)) // exactly on edge
    }
    @Test func compassPoints() {
        // index = Int((deg + 22.5) / 45) % 8
        // 312 → 334.5/45 = 7.43 → 7 = north-west;  350 → 372.5/45 = 8.28 → 8%8 = 0 = north
        #expect(FieldOfView.compassPoint(312) == "north-west")
        #expect(FieldOfView.compassPoint(350) == "north")
        #expect(FieldOfView.compassPoint(22.4) == "north")
        #expect(FieldOfView.compassPoint(22.5) == "north-east")
        #expect(FieldOfView.compassPoint(180) == "south")
    }
    @Test func compassReadingPrefersTrueHeading() {
        #expect(CompassReading(trueHeading: 12, magneticHeading: 15, headingAccuracy: 5) == .init(heading: 12, accuracy: 5))
        // trueHeading < 0 means "no true heading" (no location yet) → use magnetic
        #expect(CompassReading(trueHeading: -1, magneticHeading: 15, headingAccuracy: 5) == .init(heading: 15, accuracy: 5))
        // headingAccuracy < 0 means invalid → accuracy nil (→ usableHeading nil)
        #expect(CompassReading(trueHeading: 12, magneticHeading: 15, headingAccuracy: -1).accuracy == nil)
    }
}
```

Also add a memberwise `CompassReading.init(heading:accuracy:)` for tests and equality.

- [ ] **Step 2: Run the tests.** Expected: compile failure.
- [ ] **Step 3: Implement both files.** Compass point names, in order: `north, north-east, east, south-east, south, south-west, west, north-west`. `bearing` normalises with `(θ + 360).truncatingRemainder(dividingBy: 360)`.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: Commit** with `git commit -m "feat(core): geo math, field of view and compass reading"`.

### Task 3: Capture context, EXIF metadata, image downscaling

Spec 8.1.1: "Library photos often carry GPS but no direction, and sometimes neither." Spec 8.1.3 exception: EXIF headings get an assumed accuracy of 20°.

**Files:**
- Create: `Sources/MyGuideCore/Capture/CaptureContext.swift`, `Sources/MyGuideCore/Capture/PhotoMetadata.swift`, `Sources/MyGuideCore/Capture/ImageProcessing.swift`, `Tests/MyGuideCoreTests/Support/TestImages.swift`
- Test: `Tests/MyGuideCoreTests/PhotoMetadataTests.swift`, `Tests/MyGuideCoreTests/ImageProcessingTests.swift`

**Interfaces:**
- Consumes: `Coordinate`, `FieldOfView` (Task 2).
- Produces:
  - `public enum CaptureSource: String, Sendable, Codable { case camera, library }`
  - `public struct CaptureContext: Sendable, Equatable, Codable { var coordinate: Coordinate?; var horizontalAccuracy: Double?; var heading: Double?; var headingAccuracy: Double?; var horizontalFOV: Double; var takenAt: Date; var source: CaptureSource; var usableHeading: Double? { FieldOfView.usableHeading(heading, accuracy: headingAccuracy) }; func withCoordinate(_ c: Coordinate, accuracy: Double?) -> CaptureContext /* also clears heading + headingAccuracy */ }`
  - `public struct PhotoMetadata: Sendable, Equatable { var coordinate: Coordinate?; var heading: Double?; var takenAt: Date?; var pixelWidth: Int; var pixelHeight: Int; static let assumedHeadingAccuracy = 20.0; static func read(from jpeg: Data) -> PhotoMetadata?; func captureContext(fallbackDate: Date) -> CaptureContext }`
  - `public enum ImageProcessing { static func targetSize(width: Int, height: Int, maxLongSide: Int) -> (width: Int, height: Int); static func downscaledJPEG(_ data: Data, maxLongSide: Int, quality: Double) throws -> Data; static func pixelSize(of data: Data) -> (width: Int, height: Int)? }`, `public enum ImageProcessingError: Error { case unreadableImage, encodeFailed }`
  - Test helper: `TestImages.jpeg(width: Int, height: Int, orientation: Int = 1, gps: [CFString: Any]? = nil, exif: [CFString: Any]? = nil) -> Data`

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct PhotoMetadataTests {
    @Test func readsSouthernGPSHeadingAndDate() throws {
        let data = TestImages.jpeg(width: 40, height: 30,
            gps: [kCGImagePropertyGPSLatitude: 33.8688, kCGImagePropertyGPSLatitudeRef: "S",
                  kCGImagePropertyGPSLongitude: 151.2093, kCGImagePropertyGPSLongitudeRef: "E",
                  kCGImagePropertyGPSImgDirection: 270.5, kCGImagePropertyGPSImgDirectionRef: "T"],
            exif: [kCGImagePropertyExifDateTimeOriginal: "2025:05:14 10:30:00",
                   kCGImagePropertyExifOffsetTimeOriginal: "+10:00"])
        let m = try #require(PhotoMetadata.read(from: data))
        #expect(m.coordinate == Coordinate(latitude: -33.8688, longitude: 151.2093))
        #expect(m.heading == 270.5)
        // 10:30 at +10:00 = 00:30 UTC
        #expect(m.takenAt == ISO8601DateFormatter().date(from: "2025-05-14T00:30:00Z"))
        #expect(m.pixelWidth == 40 && m.pixelHeight == 30)
    }
    @Test func westLongitudeIsNegative() throws {
        let data = TestImages.jpeg(width: 4, height: 4,
            gps: [kCGImagePropertyGPSLatitude: 48.2082, kCGImagePropertyGPSLatitudeRef: "N",
                  kCGImagePropertyGPSLongitude: 16.3738, kCGImagePropertyGPSLongitudeRef: "W"])
        #expect(try #require(PhotoMetadata.read(from: data)).coordinate == Coordinate(latitude: 48.2082, longitude: -16.3738))
    }
    @Test func noGPSGivesNilCoordinateAndHeading() throws {
        let m = try #require(PhotoMetadata.read(from: TestImages.jpeg(width: 4, height: 4)))
        #expect(m.coordinate == nil && m.heading == nil && m.takenAt == nil)
    }
    @Test func notAnImageReturnsNil() {
        #expect(PhotoMetadata.read(from: Data("hello".utf8)) == nil)
    }
    @Test func captureContextAssumesHeadingAccuracyOnlyWithHeading() {
        let fallback = Date(timeIntervalSince1970: 1_000)
        let withHeading = PhotoMetadata(coordinate: .init(latitude: 1, longitude: 2), heading: 90, takenAt: nil, pixelWidth: 3024, pixelHeight: 4032)
        let ctx = withHeading.captureContext(fallbackDate: fallback)
        #expect(ctx.headingAccuracy == 20 && ctx.usableHeading == 90 && ctx.source == .library && ctx.takenAt == fallback)
        #expect(abs(ctx.horizontalFOV - 54.88) < 0.05)
        let noHeading = PhotoMetadata(coordinate: nil, heading: nil, takenAt: nil, pixelWidth: 10, pixelHeight: 10)
        #expect(noHeading.captureContext(fallbackDate: fallback).headingAccuracy == nil)
    }
    @Test func withCoordinateClearsHeading() {
        let ctx = CaptureContext(coordinate: nil, horizontalAccuracy: nil, heading: 90, headingAccuracy: 20,
                                 horizontalFOV: 60, takenAt: .now, source: .library)
        let moved = ctx.withCoordinate(.init(latitude: 1, longitude: 1), accuracy: 8)
        #expect(moved.coordinate != nil && moved.horizontalAccuracy == 8 && moved.heading == nil && moved.headingAccuracy == nil)
    }
}

@Suite struct ImageProcessingTests {
    @Test func targetSizeScalesLongSide() {
        // 4032x3024 → scale 1536/4032 = 0.380952; short 3024·0.380952 = 1152
        #expect(ImageProcessing.targetSize(width: 4032, height: 3024, maxLongSide: 1536) == (1536, 1152))
        #expect(ImageProcessing.targetSize(width: 3024, height: 4032, maxLongSide: 1536) == (1152, 1536))
        // never upscale
        #expect(ImageProcessing.targetSize(width: 1000, height: 800, maxLongSide: 1536) == (1000, 800))
    }
    @Test func downscaleProducesTargetPixels() throws {
        let out = try ImageProcessing.downscaledJPEG(TestImages.jpeg(width: 4032, height: 3024), maxLongSide: 1536, quality: 0.7)
        #expect(ImageProcessing.pixelSize(of: out)! == (1536, 1152))
    }
    @Test func downscaleAppliesEXIFOrientation() throws {
        // iPhone portrait photos are stored landscape with orientation 6 (rotate 90° CW)
        let out = try ImageProcessing.downscaledJPEG(TestImages.jpeg(width: 4032, height: 3024, orientation: 6), maxLongSide: 1536, quality: 0.7)
        #expect(ImageProcessing.pixelSize(of: out)! == (1152, 1536))
    }
    @Test func garbageThrows() {
        #expect(throws: ImageProcessingError.unreadableImage) { try ImageProcessing.downscaledJPEG(Data([1, 2, 3]), maxLongSide: 100, quality: 0.7) }
    }
}
```

(`pixelSize` returns a tuple, so compare components or wrap it in a small `Equatable` struct; the implementer chooses.)

- [ ] **Step 2: Run the tests.** Expected: compile failure.
- [ ] **Step 3: Implement.** `downscaledJPEG` uses `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize = targetSize long side`, `kCGImageSourceCreateThumbnailFromImageAlways = true` and `kCGImageSourceCreateThumbnailWithTransform = true`, then encodes JPEG via `CGImageDestination` with lossy quality. `PhotoMetadata.read` parses `DateTimeOriginal` with format `yyyy:MM:dd HH:mm:ss` in the zone from `OffsetTimeOriginal`. If no offset is present, use the current time zone. `pixelSize` reports post-orientation dimensions; swap width and height for orientations 5–8.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: Commit** with `git commit -m "feat(core): capture context, EXIF metadata and image downscaling"`.

### Task 4: HTTP client, JSON values, OpenAI Responses client

Spec 11: "keep the provider behind a small interface so models can be swapped."

**Files:**
- Create: `Sources/MyGuideCore/Net/HTTPClient.swift`, `Sources/MyGuideCore/Net/JSONValue.swift`, `Sources/MyGuideCore/OpenAI/OpenAIClient.swift`, `Sources/MyGuideCore/OpenAI/OpenAIError.swift`, `Sources/MyGuideCore/OpenAI/OpenAIModels.swift`, `Tests/MyGuideCoreTests/Support/StubHTTPClient.swift`
- Test: `Tests/MyGuideCoreTests/OpenAIClientTests.swift`

**Interfaces:**
- Produces:
  - `public protocol HTTPClient: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }`. `public struct URLSessionHTTPClient: HTTPClient` maps any `URLError` to `OpenAIError.network(error.localizedDescription)`. (The error is used for all hosts; the name is historical. Grounding clients catch everything anyway.)
  - `public enum JSONValue: Sendable, Equatable, Codable` with cases `string, number(Double), bool, null, array([JSONValue]), object([String: JSONValue])` and conformance to the `ExpressibleBy…Literal` protocols.
  - `public struct TokenUsage: Sendable, Equatable { var inputTokens: Int; var outputTokens: Int }`
  - `public enum OpenAIError: Error, Equatable { case missingAPIKey, invalidAPIKey, quotaExceeded, rateLimited(String), server(Int), refused(String), malformedResponse, network(String) }`
  - `public struct OpenAIModels: Sendable { var story = "gpt-5-mini"; var storyReasoningEffort: String? = "low"; var speech = "gpt-4o-mini-tts"; var voice = "coral"; var image = "gpt-image-1"; static let current = OpenAIModels() }`
  - `public struct OpenAIClient: Sendable { init(apiKey: String, http: HTTPClient, baseURL: URL = URL(string: "https://api.openai.com/v1")!); func respond(model: String, reasoningEffort: String?, instructions: String, text: String, imageJPEG: Data?, schemaName: String, schema: JSONValue) async throws -> (json: Data, usage: TokenUsage) }`. Task 12 adds `speech` and Task 15 adds `image` to this type.
  - Test helper: `final class StubHTTPClient: HTTPClient, @unchecked Sendable { init(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)); var requests: [URLRequest] { get } }` (lock-protected), plus `extension URLRequest { var jsonBody: [String: Any] }` for assertions.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct OpenAIClientTests {
    static let okBody = Data(#"""
    {"id":"resp_1","output":[{"type":"reasoning","summary":[]},
     {"type":"message","role":"assistant","content":[{"type":"output_text","text":"{\"story\":\"Hi\"}"}]}],
     "usage":{"input_tokens":1200,"output_tokens":400}}
    """#.utf8)
    static let schema: JSONValue = ["type": "object", "properties": ["story": ["type": "string"]], "required": ["story"], "additionalProperties": false]

    func call(_ client: OpenAIClient, image: Data? = Data([0xFF, 0xD8])) async throws -> (json: Data, usage: TokenUsage) {
        try await client.respond(model: "m", reasoningEffort: "low", instructions: "sys", text: "hello",
                                 imageJPEG: image, schemaName: "s", schema: Self.schema)
    }

    @Test func buildsResponsesRequest() async throws {
        let http = StubHTTPClient { _ in (200, Self.okBody) }
        _ = try await call(OpenAIClient(apiKey: "sk-test", http: http))
        let r = try #require(http.requests.first)
        #expect(r.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(r.timeoutInterval == 60)
        let b = r.jsonBody
        #expect(b["model"] as? String == "m")
        #expect(b["store"] as? Bool == false)
        #expect(b["instructions"] as? String == "sys")
        #expect((b["reasoning"] as? [String: Any])?["effort"] as? String == "low")
        let format = ((b["text"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format?["type"] as? String == "json_schema")
        #expect(format?["strict"] as? Bool == true)
        #expect(format?["name"] as? String == "s")
        let content = (((b["input"] as? [[String: Any]])?.first)?["content"] as? [[String: Any]]) ?? []
        #expect(content.first?["type"] as? String == "input_text")
        #expect((content.last?["image_url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
    }
    @Test func omitsImageAndReasoningWhenNil() async throws {
        let http = StubHTTPClient { _ in (200, Self.okBody) }
        _ = try await OpenAIClient(apiKey: "k", http: http).respond(model: "m", reasoningEffort: nil, instructions: "s",
            text: "t", imageJPEG: nil, schemaName: "s", schema: Self.schema)
        let b = http.requests[0].jsonBody
        #expect(b["reasoning"] == nil)
        let content = (((b["input"] as? [[String: Any]])?.first)?["content"] as? [[String: Any]]) ?? []
        #expect(content.count == 1)
    }
    @Test func parsesOutputTextAndUsage() async throws {
        let r = try await call(OpenAIClient(apiKey: "k", http: StubHTTPClient { _ in (200, Self.okBody) }))
        #expect(String(decoding: r.json, as: UTF8.self) == #"{"story":"Hi"}"#)
        #expect(r.usage == TokenUsage(inputTokens: 1200, outputTokens: 400))
    }
    @Test func refusalThrowsRefused() async {
        let body = Data(#"{"output":[{"type":"message","content":[{"type":"refusal","refusal":"I can't help"}]}],"usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)
        await #expect(throws: OpenAIError.refused("I can't help")) { try await call(OpenAIClient(apiKey: "k", http: StubHTTPClient { _ in (200, body) })) }
    }
    @Test func missingMessageIsMalformed() async {
        let body = Data(#"{"output":[],"usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)
        await #expect(throws: OpenAIError.malformedResponse) { try await call(OpenAIClient(apiKey: "k", http: StubHTTPClient { _ in (200, body) })) }
    }
    @Test func emptyKeyThrowsWithoutSending() async {
        let http = StubHTTPClient { _ in (200, Self.okBody) }
        await #expect(throws: OpenAIError.missingAPIKey) { try await call(OpenAIClient(apiKey: "  ", http: http)) }
        #expect(http.requests.isEmpty)
    }
    @Test(arguments: [
        (401, #"{"error":{"message":"bad key","code":"invalid_api_key"}}"#, OpenAIError.invalidAPIKey),
        (429, #"{"error":{"message":"no money","code":"insufficient_quota"}}"#, OpenAIError.quotaExceeded),
        (429, #"{"error":{"message":"slow down","code":"rate_limit_exceeded"}}"#, OpenAIError.rateLimited("slow down")),
        (500, "oops", OpenAIError.server(500)),
    ])
    func mapsHTTPErrors(status: Int, body: String, expected: OpenAIError) async {
        await #expect(throws: expected) { try await call(OpenAIClient(apiKey: "k", http: StubHTTPClient { _ in (status, Data(body.utf8)) })) }
    }
}
```

- [ ] **Step 2: Run the tests.** Expected: compile failure.
- [ ] **Step 3: Implement.** `apiKey` is trimmed of whitespace; empty throws `.missingAPIKey`. The image goes as `{"type":"input_image","image_url":"data:image/jpeg;base64,…"}`. The output text is the first `output[]` item with `type == "message"`, then its first content item of type `output_text`; a content item of type `refusal` throws `.refused`. A non-2xx response with a JSON `error.message` uses that message for `.rateLimited`.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: Commit** with `git commit -m "feat(core): HTTP client and OpenAI Responses client"`.

### Task 5: Overpass client

Spec 8.1.3: "nearby named historic places and buildings from OpenStreetMap". Spec 5: no shops or restaurants.

**Files:**
- Create: `Sources/MyGuideCore/Grounding/Candidate.swift`, `Sources/MyGuideCore/Grounding/OverpassClient.swift`
- Test: `Tests/MyGuideCoreTests/OverpassClientTests.swift`

**Interfaces:**
- Consumes: `HTTPClient`, `Coordinate`, `StoryLanguage` (define `StoryLanguage` here in `Story/StoryTypes.swift`: `public enum StoryLanguage: String, Sendable, Codable, CaseIterable { case english = "en", norwegian = "nb"; var wikipediaCode: String /* "en" | "no" */; var promptName: String /* "English" | "Norwegian Bokmål" */ }`).
- Produces:
  - `public struct Candidate: Sendable, Equatable, Codable, Identifiable { var id: String /* "osm:node/1" | "wiki:en/123" */; var name: String; var coordinate: Coordinate; var kind: String; var summary: String?; var wikipediaTitle: String? /* "de:Michaelertor" */; var wikidata: String? }`
  - `public enum GroundingFetchError: Error, Equatable { case http(Int), malformed }`
  - `public struct OverpassClient: Sendable { static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!; static let userAgent = "MyGuide/0.1 (https://github.com/birgerlie/MyGuide)"; init(http: HTTPClient); static func query(around: Coordinate, radius: Int) -> String; func places(around: Coordinate, radius: Int, language: StoryLanguage) async throws -> [Candidate] }`

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct OverpassClientTests {
    let vienna = Coordinate(latitude: 48.2082, longitude: 16.3738)

    @Test func queryIsExactAndLocaleIndependent() {
        let a = "around:250,48.208200,16.373800"
        #expect(OverpassClient.query(around: vienna, radius: 250) == """
        [out:json][timeout:10];
        (
          nwr(\(a))["historic"]["name"];
          nwr(\(a))["tourism"~"^(attraction|museum|artwork|viewpoint|gallery)$"]["name"];
          nwr(\(a))["amenity"="place_of_worship"]["name"];
          nwr(\(a))["building"]["name"]["wikidata"];
          nwr(\(a))["wikipedia"]["name"];
        );
        out center tags 200;
        """)
    }
    @Test func requestShape() async throws {
        let http = StubHTTPClient { _ in (200, Data(#"{"elements":[]}"#.utf8)) }
        _ = try await OverpassClient(http: http).places(around: vienna, radius: 250, language: .english)
        let r = http.requests[0]
        #expect(r.url == OverpassClient.endpoint && r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(r.value(forHTTPHeaderField: "User-Agent") == OverpassClient.userAgent)
        #expect(r.timeoutInterval == 12)
        #expect(String(decoding: r.httpBody!, as: UTF8.self).hasPrefix("data=%5Bout%3Ajson%5D"))
    }
    @Test func parsesFiltersAndPrefersLocalName() async throws {
        let body = #"""
        {"elements":[
         {"type":"node","id":1,"lat":48.2086,"lon":16.3671,"tags":{"name":"Michaelertor","historic":"building","wikidata":"Q1","wikipedia":"de:Michaelertor"}},
         {"type":"way","id":2,"center":{"lat":48.2087,"lon":16.3675},"tags":{"name":"Hofburg","name:nb":"Hofburg slott","tourism":"attraction"}},
         {"type":"node","id":3,"lat":48.2,"lon":16.3,"tags":{"name":"Café Central","amenity":"cafe","historic":"yes"}},
         {"type":"node","id":4,"lat":48.2,"lon":16.3,"tags":{"name":"Souvenirs","shop":"gift","tourism":"attraction"}},
         {"type":"node","id":5,"lat":48.2,"lon":16.3,"tags":{"historic":"memorial"}},
         {"type":"relation","id":6,"tags":{"name":"No centre","historic":"yes"}}
        ]}
        """#
        let http = StubHTTPClient { _ in (200, Data(body.utf8)) }
        let en = try await OverpassClient(http: http).places(around: vienna, radius: 250, language: .english)
        #expect(en.map(\.id) == ["osm:node/1", "osm:way/2"])
        #expect(en[0] == Candidate(id: "osm:node/1", name: "Michaelertor", coordinate: .init(latitude: 48.2086, longitude: 16.3671),
                                   kind: "historic=building", summary: nil, wikipediaTitle: "de:Michaelertor", wikidata: "Q1"))
        #expect(en[1].kind == "tourism=attraction" && en[1].name == "Hofburg")
        let nb = try await OverpassClient(http: http).places(around: vienna, radius: 250, language: .norwegian)
        #expect(nb[1].name == "Hofburg slott")
    }
    @Test func httpErrorThrows() async {
        await #expect(throws: GroundingFetchError.http(504)) {
            try await OverpassClient(http: StubHTTPClient { _ in (504, Data()) }).places(around: vienna, radius: 250, language: .english)
        }
    }
}
```

- [ ] **Step 2: Run the tests.** Expected: compile failure.
- [ ] **Step 3: Implement.** Format coordinates with `String(format: "%.6f", …)`, which is POSIX and not locale-dependent. Form-encode the body with an allowed set of `alphanumerics` plus `-._~`. Exclusion rule: drop an element if any `shop` tag is present, or if `amenity` is one of `restaurant, cafe, bar, pub, fast_food, ice_cream, biergarten`. Also drop elements with no name and elements with no coordinate (neither `lat`/`lon` nor `center`). Name: `name:<language.wikipediaCode>` for Norwegian (try `name:nb`, then `name:no`), `name:en` for English, else `name`. `kind` is the first present of `historic`, `tourism`, `amenity=place_of_worship`, `building`, formatted `key=value`.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: Commit** with `git commit -m "feat(core): Overpass client for nearby historic places"`.

### Task 6: Wikipedia geosearch client

Spec 8.1.3: "nearby Wikipedia articles (geosearch) with their short summaries, in the story language where available".

**Files:**
- Create: `Sources/MyGuideCore/Grounding/WikipediaClient.swift`
- Test: `Tests/MyGuideCoreTests/WikipediaClientTests.swift`

**Interfaces:**
- Consumes: `HTTPClient`, `Candidate`, `StoryLanguage`, `OverpassClient.userAgent`.
- Produces: `public struct WikipediaClient: Sendable { static let summaryLimit = 600; init(http: HTTPClient); static func url(lang: String, around: Coordinate, radius: Int) -> URL; func articles(around: Coordinate, radius: Int, language: StoryLanguage) async throws -> [Candidate] }`. Also `public enum TextTrim { static func truncate(_ s: String, maxCharacters: Int) -> String }`, which cuts at the last whitespace at or before the limit and appends `…`. Task 8 reuses it.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct WikipediaClientTests {
    let vienna = Coordinate(latitude: 48.2082, longitude: 16.3738)
    static func page(_ id: Int, _ title: String, q: String?, coord: Bool = true) -> String {
        #"{"pageid":\#(id),"title":"\#(title)","extract":"\#(title) is old.""#
        + (coord ? #","coordinates":[{"lat":48.2086,"lon":16.3671}]"# : "")
        + (q.map { #","pageprops":{"wikibase_item":"\#($0)"}"# } ?? "") + "}"
    }
    static func body(_ pages: [String]) -> Data { Data(#"{"query":{"pages":[\#(pages.joined(separator: ","))]}}"#.utf8) }

    @Test func urlIsExact() {
        #expect(WikipediaClient.url(lang: "no", around: vienna, radius: 400).absoluteString ==
            "https://no.wikipedia.org/w/api.php?action=query&format=json&formatversion=2&generator=geosearch"
          + "&ggscoord=48.208200%7C16.373800&ggsradius=400&ggslimit=20&prop=coordinates%7Cextracts%7Cpageprops"
          + "&exintro=1&explaintext=1&exsentences=4&exlimit=20&ppprop=wikibase_item&colimit=20")
    }
    @Test func parsesPagesSkipsUncoordinated() async throws {
        let http = StubHTTPClient { _ in (200, Self.body([Self.page(1, "Hofburg", q: "Q2"), Self.page(2, "Nowhere", q: nil, coord: false),
                                                          Self.page(3, "Michaelerkirche", q: nil), Self.page(4, "Stephansdom", q: "Q4")])) }
        let c = try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .english)
        #expect(c.map(\.id) == ["wiki:en/1", "wiki:en/3", "wiki:en/4"])
        #expect(c[0] == Candidate(id: "wiki:en/1", name: "Hofburg", coordinate: .init(latitude: 48.2086, longitude: 16.3671),
                                  kind: "wikipedia", summary: "Hofburg is old.", wikipediaTitle: "en:Hofburg", wikidata: "Q2"))
        #expect(http.requests.count == 1)  // 3 results ≥ 3 → no English fallback needed anyway
        #expect(http.requests[0].value(forHTTPHeaderField: "User-Agent") == OverpassClient.userAgent)
    }
    @Test func norwegianFallsBackToEnglishWhenFewerThanThree() async throws {
        let http = StubHTTPClient { r in
            r.url!.host == "no.wikipedia.org"
              ? (200, Self.body([Self.page(10, "Hofburg", q: "Q2"), Self.page(11, "Stefansdomen", q: "Q4")]))
              : (200, Self.body([Self.page(1, "Hofburg", q: "Q2"), Self.page(3, "Michaelerkirche", q: "Q3")]))
        }
        let c = try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .norwegian)
        // Norwegian entries win on equal wikidata; English-only Q3 is added
        #expect(c.map(\.id) == ["wiki:no/10", "wiki:no/11", "wiki:en/3"])
        #expect(http.requests.count == 2)
    }
    @Test func truncateAtWordBoundary() {
        #expect(TextTrim.truncate("one two three", maxCharacters: 9) == "one two…")
        #expect(TextTrim.truncate("short", maxCharacters: 9) == "short")
        #expect(TextTrim.truncate("abcdefghijk", maxCharacters: 5) == "abcde…")  // no space: hard cut
    }
}
```

- [ ] **Step 2: Run the tests.** Expected: compile failure.
- [ ] **Step 3: Implement.** Build the URL with `URLComponents` and `percentEncodedQuery` so that `|` becomes `%7C`. Use a 10 s timeout. Truncate summaries to `summaryLimit`. A failure of the English fallback is swallowed; the result is the story-language results alone. A failure of the primary request propagates.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: Commit** with `git commit -m "feat(core): Wikipedia geosearch client with language fallback"`.

### Task 7: Candidate merge, ranking, grounding service

Spec 8.1.3–4: "emphasis on those within the camera's field of view given the heading"; "identify what is in the photo, preferring candidates that match position and heading".

**Files:**
- Create: `Sources/MyGuideCore/Grounding/CandidateRanker.swift`, `Sources/MyGuideCore/Grounding/GroundingService.swift`; add `RankedCandidate`, `Address`, `GroundingSource`, `Grounding` to `Candidate.swift`
- Test: `Tests/MyGuideCoreTests/GroundingTests.swift`

**Interfaces:**
- Consumes: `OverpassClient`, `WikipediaClient`, `CaptureContext`, `FieldOfView`, `GeoMath`.
- Produces:
  - `public struct RankedCandidate: Sendable, Equatable, Codable { var candidate: Candidate; var distance: Double; var bearing: Double; var inView: Bool? }`
  - `public struct Address: Sendable, Equatable, Codable { var line: String?; var city: String?; var country: String?; var display: String /* non-nil parts joined ", " */ }`
  - `public enum GroundingSource: String, Sendable, Codable { case openStreetMap, wikipedia, geocoder }`
  - `public struct Grounding: Sendable, Equatable, Codable { var candidates: [RankedCandidate]; var address: Address?; var failedSources: [GroundingSource] }`
  - `public protocol ReverseGeocoding: Sendable { func address(for: Coordinate) async throws -> Address }`
  - `public enum CandidateRanker { static let maxCandidates = 15; static let duplicateRadius = 50.0; static func merge(osm: [Candidate], wiki: [Candidate]) -> [Candidate]; static func rank(_ candidates: [Candidate], capture: CaptureContext, limit: Int = maxCandidates) -> [RankedCandidate] }`
  - `public enum GroundingError: Error, Equatable { case noPosition }`
  - `public struct GroundingService: Sendable { static let osmRadius = 250; static let wikiRadius = 400; init(overpass: OverpassClient, wikipedia: WikipediaClient, geocoder: ReverseGeocoding); func ground(_ capture: CaptureContext, language: StoryLanguage) async throws -> Grounding }`

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct GroundingTests {
    // Offsets at the equator: 1 m ≈ 1/111_195 degree (R·π/180 = 111_194.93 m per degree)
    static let m = 1.0 / 111_195
    static func cand(_ id: String, n: Double, e: Double, name: String? = nil, wiki: String? = nil, q: String? = nil, summary: String? = nil) -> Candidate {
        Candidate(id: id, name: name ?? id, coordinate: .init(latitude: n * m, longitude: e * m), kind: "historic=yes",
                  summary: summary, wikipediaTitle: wiki, wikidata: q)
    }
    static func capture(heading: Double?, acc: Double?) -> CaptureContext {
        CaptureContext(coordinate: .init(latitude: 0, longitude: 0), horizontalAccuracy: 5, heading: heading,
                       headingAccuracy: acc, horizontalFOV: 55, takenAt: .now, source: .camera)
    }

    @Test func mergeByWikidataThenTitleAndDedupeByName() {
        let osm = [Self.cand("osm:node/1", n: 0, e: 0, name: "Michaelertor", q: "Q1"),
                   Self.cand("osm:way/2", n: 10, e: 0, name: "Hofburg", wiki: "en:Hofburg"),
                   Self.cand("osm:node/3", n: 20, e: 0, name: "hofburg")]          // 10 m from way/2, same name → dropped
        let wiki = [Self.cand("wiki:en/9", n: 0, e: 1, name: "St Michael's Gate", q: "Q1", summary: "Gate story."),
                    Self.cand("wiki:en/8", n: 10, e: 1, name: "Hofburg", wiki: "en:Hofburg", summary: "Palace story."),
                    Self.cand("wiki:en/7", n: 90, e: 0, name: "Loos House", summary: "Plain facade.")]
        let merged = CandidateRanker.merge(osm: osm, wiki: wiki)
        #expect(merged.map(\.id) == ["osm:node/1", "osm:way/2", "wiki:en/7"])
        #expect(merged[0].summary == "Gate story." && merged[1].summary == "Palace story.")
    }
    @Test func rankInViewFirstThenByDistance() {
        // heading 0, fov 55, acc 10 → half-width 27.5 + 20 = 47.5
        let a = Self.cand("A", n: 100, e: 0)                       // bearing 0,   100 m, in view
        let b = Self.cand("B", n: 0, e: 30)                        // bearing 90,   30 m, out
        let c = Self.cand("C", n: 200 * cos(.pi / 6), e: 100)      // bearing 30,  200 m, in view
        let d = Self.cand("D", n: -10, e: 0)                       // bearing 180,  10 m, out
        let r = CandidateRanker.rank([a, b, c, d], capture: Self.capture(heading: 0, acc: 10))
        #expect(r.map(\.candidate.id) == ["A", "C", "D", "B"])
        #expect(r.map(\.inView) == [true, true, false, false])
        #expect(abs(r[1].bearing - 30) < 0.01 && abs(r[1].distance - 200) < 0.5)
    }
    @Test func rankWithoutUsableHeadingIsByDistanceAndInViewNil() {
        let r = CandidateRanker.rank([Self.cand("A", n: 100, e: 0), Self.cand("D", n: -10, e: 0)], capture: Self.capture(heading: 0, acc: 60))
        #expect(r.map(\.candidate.id) == ["D", "A"] && r.allSatisfy { $0.inView == nil })
    }
    @Test func rankCapsAtFifteen() {
        let many = (1...40).map { Self.cand("c\($0)", n: Double($0), e: 0) }
        #expect(CandidateRanker.rank(many, capture: Self.capture(heading: nil, acc: nil)).count == 15)
    }

    struct Geo: ReverseGeocoding { var fail = false
        func address(for: Coordinate) async throws -> Address {
            if fail { throw URLError(.timedOut) }
            return Address(line: "Michaelerplatz", city: "Vienna", country: "Austria")
        }
    }
    static let osmJSON = #"{"elements":[{"type":"node","id":1,"lat":0.0009,"lon":0,"tags":{"name":"Gate","historic":"yes"}}]}"#
    static let wikiJSON = #"{"query":{"pages":[{"pageid":5,"title":"Palace","extract":"Old.","coordinates":[{"lat":0.0005,"lon":0}]}]}}"#
    func service(osmStatus: Int = 200, geoFail: Bool = false) -> GroundingService {
        let http = StubHTTPClient { r in
            r.url!.host!.contains("overpass") ? (osmStatus, Data(Self.osmJSON.utf8)) : (200, Data(Self.wikiJSON.utf8))
        }
        return GroundingService(overpass: .init(http: http), wikipedia: .init(http: http), geocoder: Geo(fail: geoFail))
    }

    @Test func groundsFromAllSources() async throws {
        let g = try await service().ground(Self.capture(heading: 0, acc: 10), language: .english)
        #expect(g.candidates.map(\.candidate.name) == ["Palace", "Gate"])
        #expect(g.address?.display == "Michaelerplatz, Vienna, Austria" && g.failedSources.isEmpty)
    }
    @Test func overpassFailureStillGroundsOnWikipedia() async throws {
        let g = try await service(osmStatus: 504).ground(Self.capture(heading: 0, acc: 10), language: .english)
        #expect(g.candidates.map(\.candidate.name) == ["Palace"] && g.failedSources == [.openStreetMap])
    }
    @Test func geocoderFailureLeavesAddressNil() async throws {
        let g = try await service(geoFail: true).ground(Self.capture(heading: 0, acc: 10), language: .english)
        #expect(g.address == nil && g.failedSources == [.geocoder])
    }
    @Test func noPositionThrows() async {
        var cap = Self.capture(heading: 0, acc: 10); cap.coordinate = nil
        await #expect(throws: GroundingError.noPosition) { try await service().ground(cap, language: .english) }
    }
}
```

- [ ] **Step 2: Run the tests.** Expected: compile failure.
- [ ] **Step 3: Implement.**
  - `merge`: walk OSM in order. A wiki candidate matches an OSM candidate when both have the same `wikidata`, or the same `wikipediaTitle`. A matched OSM candidate takes the wiki summary if it has none, and the wiki candidate is consumed. Then drop OSM candidates whose lowercased name equals an earlier kept candidate's name within `duplicateRadius`. Append unconsumed wiki candidates, applying the same name/radius dedupe.
  - `rank`: half-width comes from `capture.horizontalFOV` and `capture.headingAccuracy` only when `capture.usableHeading` is non-nil.
  - `ground`: run the three fetches concurrently with `async let`. A failure in any of them is recorded in `failedSources`, in the order `openStreetMap, wikipedia, geocoder`, and is not rethrown.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: Commit** with `git commit -m "feat(core): candidate merge, field-of-view ranking and grounding service"`.

### Task 8: Story types, prompts and decoding

Spec 6 (story style), 8.1.4: "say plainly when it is unsure what the subject is; write the 20-second first story … labelling legend and uncertainty." Spec 10: "Warm, conversational voice, a friend who knows the city."

**Files:**
- Create: `Sources/MyGuideCore/Story/PromptBuilder.swift`; extend `Sources/MyGuideCore/Story/StoryTypes.swift`
- Test: `Tests/MyGuideCoreTests/PromptBuilderTests.swift`

**Interfaces:**
- Consumes: `CaptureContext`, `Grounding`, `RankedCandidate`, `FieldOfView.compassPoint`, `TextTrim`, `JSONValue`, `StoryLanguage`.
- Produces:
  - `public enum StoryLevel: Int, Sendable, Codable, CaseIterable { case first = 1, more = 2, evenMore = 3; var targetSeconds: Int /* 20, 30, 120 */; var targetWords: Int /* targetSeconds * 150 / 60 */; var lengthPhrase: String; var next: StoryLevel? }`
  - `public enum SubjectConfidence: String, Sendable, Codable { case certain, likely, unsure }`
  - `public struct IdentifiedStory: Sendable, Equatable, Codable { var subject: String; var confidence: SubjectConfidence; var matchedCandidateID: String?; var title: String; var era: String; var story: String }`
  - `public struct PriorStory: Sendable, Equatable { var placeID: String?; var level: StoryLevel; var text: String; var toldAt: Date }`
  - `public enum PromptBuilder { static let priorTextLimit = 240; static func systemInstructions(language: StoryLanguage) -> String; static func firstStoryInput(capture: CaptureContext, grounding: Grounding, priors: [PriorStory]) -> String; static let firstStorySchema: JSONValue; static let continuationSchema: JSONValue; static func decodeFirstStory(_ json: Data, grounding: Grounding) throws -> IdentifiedStory /* nils unknown matchedCandidateID */ }`

  Task 11 adds `continuationInput`; Task 15 adds `thenImagePrompt`.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct PromptBuilderTests {
    static let gate = RankedCandidate(candidate: Candidate(id: "osm:way/1", name: "Michaelertor", coordinate: .init(latitude: 0, longitude: 0),
                                      kind: "historic=building", summary: "Gate of the palace.", wikipediaTitle: nil, wikidata: nil),
                                      distance: 35.4, bearing: 304.6, inView: true)
    static let grounding = Grounding(candidates: [gate], address: Address(line: "Michaelerplatz", city: "Vienna", country: "Austria"), failedSources: [])
    static func capture(heading: Double?, acc: Double?) -> CaptureContext {
        CaptureContext(coordinate: .init(latitude: 48.2082, longitude: 16.3738), horizontalAccuracy: 8, heading: heading,
                       headingAccuracy: acc, horizontalFOV: 55, takenAt: .now, source: .camera)
    }

    @Test func levelTargets() {
        // words = seconds·150/60:  20·150/60 = 50;  30·150/60 = 75;  120·150/60 = 300
        #expect(StoryLevel.allCases.map(\.targetWords) == [50, 75, 300])
        #expect(StoryLevel.allCases.map(\.lengthPhrase) == ["about 50 words (20 seconds spoken)",
                                                           "about 75 words (30 seconds spoken)",
                                                           "about 300 words (2 minutes spoken)"])
        #expect(StoryLevel.evenMore.next == nil && StoryLevel.first.next == .more)
    }
    @Test func instructionsCarryVoiceAndLanguage() {
        let en = PromptBuilder.systemInstructions(language: .english)
        #expect(en.contains("legend has it") && en.contains("Write in English."))
        #expect(PromptBuilder.systemInstructions(language: .norwegian).contains("Write in Norwegian Bokmål."))
    }
    @Test func firstInputWithHeading() {
        let s = PromptBuilder.firstStoryInput(capture: Self.capture(heading: 312, acc: 10), grounding: Self.grounding, priors: [])
        #expect(s.contains("Story length: about 50 words (20 seconds spoken)."))
        #expect(s.contains("Position: 48.208200, 16.373800 (accuracy ±8 m)"))
        #expect(s.contains("Facing: 312° (north-west), compass accuracy ±10°"))
        #expect(s.contains("Address: Michaelerplatz, Vienna, Austria"))
        // 35.4 m → 35 m; 304.6° → 305°
        #expect(s.contains("- [osm:way/1] Michaelertor — historic=building — 35 m, bearing 305°, in view\n  Summary: Gate of the palace."))
        #expect(s.contains("Already told: nothing yet"))
        #expect(!s.contains("Map data unavailable"))
    }
    @Test func firstInputUnknownHeadingAndFailures() {
        var g = Self.grounding; g.failedSources = [.openStreetMap, .geocoder]; g.address = nil
        let s = PromptBuilder.firstStoryInput(capture: Self.capture(heading: 312, acc: 60), grounding: g, priors: [])
        #expect(s.contains("Facing: unknown"))
        #expect(s.contains("Map data unavailable: OpenStreetMap, address lookup. Be more cautious."))
        #expect(!s.contains("Address:"))
    }
    @Test func priorsAreListedAndTrimmed() {
        let long = String(repeating: "word ", count: 100)   // 500 chars
        let s = PromptBuilder.firstStoryInput(capture: Self.capture(heading: nil, acc: nil), grounding: Self.grounding,
            priors: [PriorStory(placeID: "osm:way/1", level: .first, text: "The emperor rode out here.", toldAt: .now),
                     PriorStory(placeID: nil, level: .more, text: long, toldAt: .now)])
        #expect(s.contains("Already told:\n- [osm:way/1] level 1: The emperor rode out here."))
        let line = s.components(separatedBy: "\n").first { $0.hasPrefix("- [nearby, unidentified] level 2: ") }!
        #expect(line.hasSuffix("…") && line.count <= "- [nearby, unidentified] level 2: ".count + 241)
    }
    @Test func decodeNilsUnknownCandidate() throws {
        let ok = Data(#"{"subject":"Michaelertor","confidence":"likely","matchedCandidateID":"osm:way/1","title":"The gate","era":"around 1890","story":"S"}"#.utf8)
        #expect(try PromptBuilder.decodeFirstStory(ok, grounding: Self.grounding).matchedCandidateID == "osm:way/1")
        let bogus = Data(#"{"subject":"X","confidence":"unsure","matchedCandidateID":"osm:way/999","title":"T","era":"E","story":"S"}"#.utf8)
        #expect(try PromptBuilder.decodeFirstStory(bogus, grounding: Self.grounding).matchedCandidateID == nil)
    }
    @Test func decodeGarbageIsMalformed() {
        #expect(throws: OpenAIError.malformedResponse) { try PromptBuilder.decodeFirstStory(Data("{}".utf8), grounding: Self.grounding) }
    }
    @Test func schemaIsStrictCompatible() {
        guard case .object(let o) = PromptBuilder.firstStorySchema, case .array(let req) = o["required"]! else { Issue.record(); return }
        #expect(req.count == 6 && o["additionalProperties"] == .bool(false))
    }
}
```

- [ ] **Step 2: Run the tests.** Expected: compile failure.
- [ ] **Step 3: Implement.** The system instructions are exactly this copy, with `{language}` replaced by `promptName`:

```
You are MyGuide, a friend who knows this city well, walking beside the listener. You tell short, true stories about the people who were here and what this spot was like back then: the sounds, the smells, who walked past. Dates, architects and styles appear only when they support a story about people.

Rules:
1. Never present invented history as fact. If something is legend, tradition or disputed, say so plainly ("legend has it", "the story goes", "historians doubt it"). Prefer a less colourful true story over an invented one.
2. Use the supplied places, summaries and address as your factual ground. You may add well-established history you are confident of; never invent names, dates, quotes or events.
3. If you are not sure what the photo shows, say so in the story itself, then tell the story of the most likely candidate or of the spot itself.
4. Do not repeat anything listed under "Already told". Take a new angle.
5. Speak directly to the listener in a warm, conversational voice. No lists, no headings, no "Welcome to".
6. Never mention shops, restaurants or cafés unless the subject is one with real history.
7. Write in {language}. Hit the requested length closely; it will be read aloud at about 150 words per minute.
```

  First-story input layout, one line per item in this order:
  - `Story length: …`
  - `Position: … (accuracy ±N m)`
  - `Facing: …` or `Facing: unknown — identify the subject from position and the photo alone, and be more cautious.`
  - `Address: …` (omitted when nil)
  - `Map data unavailable: … Be more cautious.` (omitted when empty; source names are `OpenStreetMap`, `Wikipedia`, `address lookup`)
  - `Places nearby (in view first, nearest first):` followed by candidate lines and their indented `  Summary:` lines, or `Places nearby: none found`
  - `Already told:` followed by lines, or `Already told: nothing yet`
  - `Task: Identify what the photo shows, preferring places in view. Set matchedCandidateID only if the subject is one of the listed places (use its id in brackets). Then write the first story.`

  For candidates with no usable heading, omit `, in view` and `, out of view`. Schemas:

```
firstStorySchema: object, additionalProperties false, required all of:
  subject: string ("What the photo shows, e.g. 'St. Michael's Church, main portal'")
  confidence: string enum [certain, likely, unsure]
  matchedCandidateID: type ["string","null"]
  title: string ("3–8 word title")
  era: string ("The past era the story mostly paints, e.g. 'around 1780'")
  story: string
continuationSchema: object, additionalProperties false, required [story], story: string
```

  `decodeFirstStory` maps any `DecodingError` to `OpenAIError.malformedResponse`.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: Commit** with `git commit -m "feat(core): story types, prompts and first-story decoding"`.

### Task 9: Photo story flow (first level) and user-facing messages

Spec 8.1.1–5. Spec 8.1.1: "Without a position, the app says it cannot ground the photo and offers to use the current position instead; it does not silently tell an ungrounded story."

**Files:**
- Create: `Sources/MyGuideCore/Story/PhotoStoryFlow.swift`, `Sources/MyGuideCore/Story/UserFacingMessage.swift`, `Sources/MyGuideCore/Usage/UsageEntry.swift`; add `StorySession` to `StoryTypes.swift`
- Test: `Tests/MyGuideCoreTests/PhotoStoryFlowTests.swift`, `Tests/MyGuideCoreTests/UserFacingMessageTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 3–8.
- Produces:
  - `public enum UsageKind: String, Sendable, Codable { case story, speech, image }`
  - `public struct UsageEntry: Sendable, Equatable { var date: Date; var kind: UsageKind; var model: String; var inputTokens: Int; var outputTokens: Int; var words: Int; var images: Int }`
  - `public struct StorySession: Sendable, Equatable, Identifiable { var id: UUID; var capture: CaptureContext; var photoJPEG: Data /* the 1536 px upload version, kept as "photos taken" (spec 8.2) */; var thumbnailJPEG: Data; var language: StoryLanguage; var grounding: Grounding; var identified: IdentifiedStory; var levels: [String]; var matchedCandidate: RankedCandidate? { grounding.candidates.first { $0.candidate.id == identified.matchedCandidateID } }; var nextLevel: StoryLevel? { StoryLevel(rawValue: levels.count + 1) } }`
  - `public typealias PriorStoryLookup = @Sendable (_ placeIDs: [String], _ near: Coordinate, _ excludingSession: UUID?) async -> [PriorStory]`
  - `public enum PhotoStoryError: Error, Equatable { case noPosition, noFurtherLevel }`
  - `public struct PhotoStoryFlow: Sendable { static let uploadLongSide = 1536; static let thumbnailLongSide = 400; init(grounding: GroundingService, openAI: OpenAIClient, models: OpenAIModels = .current, priors: @escaping PriorStoryLookup = { _, _, _ in [] }, now: @escaping @Sendable () -> Date = Date.init); func tellFirstStory(photoJPEG: Data, capture: CaptureContext, language: StoryLanguage) async throws -> (StorySession, [UsageEntry]) }`
  - `public enum UserFacingMessage { static func message(for error: Error) -> String }`

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct PhotoStoryFlowTests {
    struct Geo: ReverseGeocoding { func address(for: Coordinate) async throws -> Address { Address(line: "Platz", city: "Wien", country: nil) } }
    static let storyJSON = #"{"subject":"Gate","confidence":"likely","matchedCandidateID":"osm:node/1","title":"T","era":"around 1890","story":"Once a coachman waited here."}"#
    static func openAIBody(_ inner: String) -> Data {
        let escaped = String(data: try! JSONEncoder().encode(inner), encoding: .utf8)!
        return Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":\#(escaped)}]}],"usage":{"input_tokens":900,"output_tokens":120}}"#.utf8)
    }
    static func http(_ openAI: Data = openAIBody(storyJSON)) -> StubHTTPClient {
        StubHTTPClient { r in
            switch r.url!.host! {
            case let h where h.contains("overpass"): (200, Data(GroundingTests.osmJSON.utf8))
            case let h where h.contains("wikipedia"): (200, Data(GroundingTests.wikiJSON.utf8))
            default: (200, openAI)
            }
        }
    }
    static func flow(_ http: StubHTTPClient, priors: @escaping PriorStoryLookup = { _, _, _ in [] }) -> PhotoStoryFlow {
        PhotoStoryFlow(grounding: GroundingService(overpass: .init(http: http), wikipedia: .init(http: http), geocoder: Geo()),
                       openAI: OpenAIClient(apiKey: "k", http: http), priors: priors, now: { Date(timeIntervalSince1970: 5) })
    }
    static let capture = GroundingTests.capture(heading: 0, acc: 10)

    @Test func tellsFirstStory() async throws {
        let http = Self.http()
        let (s, usage) = try await Self.flow(http).tellFirstStory(photoJPEG: TestImages.jpeg(width: 4032, height: 3024, orientation: 6),
                                                                capture: Self.capture, language: .english)
        #expect(s.levels == ["Once a coachman waited here."] && s.nextLevel == .more)
        #expect(s.matchedCandidate?.candidate.name == "Gate")
        #expect(ImageProcessing.pixelSize(of: s.thumbnailJPEG)! == (300, 400))   // 400/4032·3024 = 300, portrait
        #expect(ImageProcessing.pixelSize(of: s.photoJPEG)! == (1152, 1536))     // 1536/4032·3024 = 1152, portrait
        #expect(usage == [UsageEntry(date: Date(timeIntervalSince1970: 5), kind: .story, model: "gpt-5-mini",
                                     inputTokens: 900, outputTokens: 120, words: 0, images: 0)])
        let openAIRequest = http.requests.first { $0.url!.host == "api.openai.com" }!
        let content = ((openAIRequest.jsonBody["input"] as! [[String: Any]])[0]["content"] as! [[String: Any]])
        let b64 = (content[1]["image_url"] as! String).replacingOccurrences(of: "data:image/jpeg;base64,", with: "")
        #expect(ImageProcessing.pixelSize(of: Data(base64Encoded: b64)!)! == (1152, 1536))
    }
    @Test func noPositionThrowsBeforeAnyRequest() async {
        let http = Self.http(); var cap = Self.capture; cap.coordinate = nil
        await #expect(throws: PhotoStoryError.noPosition) {
            try await Self.flow(http).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: cap, language: .english)
        }
        #expect(http.requests.isEmpty)
    }
    @Test func priorsAreLookedUpByCandidateIDsAndSent() async throws {
        let http = Self.http()
        let seen = LockedBox<[String]>([])
        let flow = Self.flow(http) { ids, _, _ in
            seen.set(ids); return [PriorStory(placeID: "osm:node/1", level: .first, text: "Told before: the coachman.", toldAt: .now)]
        }
        _ = try await flow.tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english)
        #expect(Set(seen.value) == ["osm:node/1", "wiki:en/5"])
        let body = String(decoding: http.requests.first { $0.url!.host == "api.openai.com" }!.httpBody!, as: UTF8.self)
        #expect(body.contains("Told before: the coachman."))
    }
    @Test func refusalPropagates() async {
        let refusal = Data(#"{"output":[{"type":"message","content":[{"type":"refusal","refusal":"no"}]}],"usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)
        await #expect(throws: OpenAIError.refused("no")) {
            try await Self.flow(Self.http(refusal)).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english)
        }
    }
}

@Suite struct UserFacingMessageTests {
    @Test(arguments: [
        (OpenAIError.missingAPIKey as Error, "Add your OpenAI API key in Settings first."),
        (OpenAIError.invalidAPIKey, "OpenAI rejected the API key. Check it in Settings."),
        (OpenAIError.quotaExceeded, "Your OpenAI account is out of credit or over its limit."),
        (OpenAIError.rateLimited("x"), "OpenAI is busy right now. Try again in a moment."),
        (OpenAIError.server(503), "OpenAI had a problem (error 503). Try again."),
        (OpenAIError.network("offline"), "No connection. Check mobile data and try again."),
        (OpenAIError.refused("no"), "Couldn't tell a story about this photo."),
        (OpenAIError.malformedResponse, "Couldn't tell a story about this photo."),
        (PhotoStoryError.noPosition, "This photo has no location. Use where you are now?"),
        (ImageProcessingError.unreadableImage, "Couldn't read this photo."),
    ])
    func messages(error: Error, expected: String) { #expect(UserFacingMessage.message(for: error) == expected) }
}
```

(`LockedBox<T>` is a small `@unchecked Sendable` test helper; add it to `Support/StubHTTPClient.swift`.)

- [ ] **Step 2: Run the tests.** Expected: compile failure.
- [ ] **Step 3: Implement `tellFirstStory`.**
  1. Throw `.noPosition` if the coordinate is nil.
  2. Make the upload JPEG at 1536 px, quality 0.7, and the thumbnail at 400 px, quality 0.7.
  3. Ground the capture.
  4. Call `priors(candidateIDs, coordinate, nil)`.
  5. Call `respond` with `models.story`, `models.storyReasoningEffort`, the system instructions, the first-story input, the upload JPEG, `schemaName: "first_story"` and `firstStorySchema`.
  6. Decode, then build the session with a new UUID, `photoJPEG` = the upload JPEG and `levels = [story]`, plus one `UsageEntry`.

  The default branch of `UserFacingMessage` is `"Something went wrong: \(error.localizedDescription)"`.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: Commit** with `git commit -m "feat(core): first-level photo story flow and user-facing messages"`.

### Task 10: App: location, camera, library picker, story text, API key (milestone 1 on device)

Spec 8.1.1–2, 8.1.5 (text part), 7 (API key in Keychain).

**Files:**
- Create: `MyGuide/AppServices.swift`, `MyGuide/Capture/LocationProvider.swift`, `MyGuide/Capture/CameraController.swift`, `MyGuide/Capture/CameraPreview.swift`, `MyGuide/Capture/CaptureScreen.swift`, `MyGuide/Story/StoryViewModel.swift`, `MyGuide/Story/StoryView.swift`, `MyGuide/Settings/SettingsView.swift`, `MyGuide/Platform/MapKitReverseGeocoder.swift`
- Modify: `MyGuide/MyGuideApp.swift` (root becomes `CaptureScreen` inside a `NavigationStack`; `SelfCheckView` moves under Settings → Device check)

**Interfaces:**
- Consumes: `KeychainStore`, `CompassReading`, `FieldOfView`, `CaptureContext`, `PhotoMetadata`, `PhotoStoryFlow`, `GroundingService`, `OverpassClient`, `WikipediaClient`, `OpenAIClient`, `URLSessionHTTPClient`, `UserFacingMessage`, `ReverseGeocoding`, `Address`.
- Produces (used by Tasks 11–16):
  - `@MainActor final class AppServices { static let keychainService = "io.github.birgerlie.MyGuide"; static let apiKeyAccount = "openai-api-key"; func makeFlow() throws -> PhotoStoryFlow /* throws OpenAIError.missingAPIKey */; func makeOpenAI() throws -> OpenAIClient }`
  - `@MainActor @Observable final class StoryViewModel { enum State { case working(String), showing, failed(message: String, canUseCurrentPosition: Bool) }; var state: State; var session: StorySession?; func start(photoJPEG: Data, capture: CaptureContext); func retry(); func useCurrentPosition(_ coordinate: Coordinate, accuracy: Double?) }`
  - `@MainActor @Observable final class LocationProvider { var location: CLLocation?; var compass: CompassReading?; func start(); func stop() }`

- [ ] **Step 1: `LocationProvider`.** `CLLocationManager` with `desiredAccuracy = kCLLocationAccuracyBest`, `headingFilter = 1`, and `headingOrientation = .portrait` (the UI is portrait-only). Request when-in-use authorisation. Publish `CompassReading(trueHeading:magneticHeading:headingAccuracy:)` from each `CLHeading`.

- [ ] **Step 2: `MapKitReverseGeocoder: ReverseGeocoding`.** Use `MKReverseGeocodingRequest(location:)` and its `mapItems`. Map the first item's short address to `line`, its city name to `city`, and the region or country name to `country`.

- [ ] **Step 3: `CameraController` and `CameraPreview`.** Use `AVCaptureSession` with `.photo` preset, the back wide camera and an `AVCapturePhotoOutput`. Start and stop the session on a dedicated serial queue. `capture() async throws -> Data` returns `fileDataRepresentation()`. `horizontalFOV` is `FieldOfView.portraitHorizontalFOV(landscapeFOV: Double(device.activeFormat.videoFieldOfView))`.

- [ ] **Step 4: `CaptureScreen`.**
  - Full-screen preview, a shutter button, a `PhotosPicker` (images only, `photoLibrary: .shared()`) and a Settings gear.
  - A small HUD shows `GPS ±8 m · 312° NW ±10°`, or `No GPS fix` / `Compass unavailable`, so the owner can see what will be sent.
  - On shutter, snapshot `location` and `compass` **at the press, before awaiting the photo**. Build a `CaptureContext` with `source: .camera`, the camera FOV and `takenAt: .now`. A location older than 60 s counts as no coordinate.
  - On library pick, load `Data` and read `PhotoMetadata`. If it has no coordinate and the picker returned an `itemIdentifier`, request read authorisation and try `PHAsset.fetchAssets(withLocalIdentifiers:).firstObject?.location` for the coordinate (heading stays nil).
  - Then push `StoryView` with a new `StoryViewModel` and call `start`.

- [ ] **Step 5: `StoryViewModel` and `StoryView`.**
  - States: `working` shows a spinner with "Looking around…"; `showing` shows the photo thumbnail, title, story text and badges; `failed` shows the message and a Retry button. Retry re-runs with the same photo and capture; the photo is never lost.
  - When the error is `PhotoStoryError.noPosition`, `failed` also offers "Use where I am now", which calls `useCurrentPosition` with the provider's location (via `CaptureContext.withCoordinate`).
  - Badges: if `identified.confidence != .certain`, show "Not sure: \(subject)?" for `.unsure` and "Probably \(subject)" for `.likely`. If `grounding.failedSources` is non-empty, show "Less certain: map data unavailable".

- [ ] **Step 6: `SettingsView`.** Contents:
  - A `SecureField` for the API key with a Save button that writes to `KeychainStore`. The field shows "Key saved" plus the last 4 characters, never the full key.
  - A "Remove key" button.
  - A `NavigationLink` to `SelfCheckView` titled "Device check".

- [ ] **Step 7: Build.** Run `xcodegen generate`, then the app build check. Expected: `** BUILD SUCCEEDED **`, with zero Swift 6 concurrency errors.

- [ ] **Step 8: Commit** with `git add -A MyGuide MyGuide.xcodeproj` and `git commit -m "feat(app): camera, location, library picker and first story as text"`.

- [ ] **Step 9: Milestone 1 gate (owner, on the phone, in a real street).**
  1. Enter the API key, then quit and relaunch the app: it shows "Key saved ••••abcd".
  2. **Heading check (Review Focus 1):** stand facing a building whose direction you know from Apple Maps. The HUD heading must be within ±20° of the true direction the *back camera* faces. If it is off by about 90° or 180°, stop and fix `headingOrientation` or the reference frame before going on.
  3. Photograph a known landmark: within about 15 s a story appears that names the right subject.
  4. Turn around and photograph the building behind you: the story names that building, not the first one.
  5. Pick a library photo that has location data: you get a story. Pick a screenshot (no location): you get "This photo has no location. Use where you are now?" and the button works.
  6. Turn on aeroplane mode and take a photo: you get "No connection…". Turn aeroplane mode off and tap Retry: you get a story.
  7. Remove the key and take a photo: you get "Add your OpenAI API key in Settings first."

---

## Milestone 2: Deeper levels and speech (spec 9, step 2)

### Task 11: "Tell me more" and "even more"

Spec 8.1.6: "Each level continues the previous one rather than restarting, and avoids what has been said before."

**Files:**
- Modify: `Sources/MyGuideCore/Story/PromptBuilder.swift`, `Sources/MyGuideCore/Story/PhotoStoryFlow.swift`, `MyGuide/Story/StoryViewModel.swift`, `MyGuide/Story/StoryView.swift`
- Test: `Tests/MyGuideCoreTests/PromptBuilderTests.swift`, `Tests/MyGuideCoreTests/PhotoStoryFlowTests.swift`

**Interfaces:**
- Produces: `PromptBuilder.continuationInput(session: StorySession, level: StoryLevel, priors: [PriorStory]) -> String`, `PromptBuilder.decodeContinuation(_ json: Data) throws -> String`, `PhotoStoryFlow.continueStory(_ session: StorySession) async throws -> (StorySession, [UsageEntry])`, `StoryViewModel.tellMore()`.

- [ ] **Step 1: Write the failing tests**

```swift
// PromptBuilderTests: shared builder, also used by ThenImageTests (Task 15)
static func session(grounding: Grounding = PromptBuilderTests.grounding, matched: String? = "osm:way/1") -> StorySession {
    StorySession(id: UUID(), capture: capture(heading: 312, acc: 10), photoJPEG: Data(), thumbnailJPEG: Data(), language: .english,
        grounding: grounding,
        identified: IdentifiedStory(subject: "Michaelertor", confidence: .likely, matchedCandidateID: matched, title: "T", era: "around 1890", story: "L1"),
        levels: ["L1 text."])
}
@Test func continuationInput() {
    let session = Self.session()
    let s = PromptBuilder.continuationInput(session: session, level: .more,
        priors: [PriorStory(placeID: "osm:way/1", level: .first, text: "Earlier visit.", toldAt: .now)])
    #expect(s.contains("Story length: about 75 words (30 seconds spoken)."))
    #expect(s.contains("Subject: Michaelertor (confidence: likely)"))
    #expect(s.contains("Facts:\n- Michaelertor — historic=building\n  Summary: Gate of the palace."))
    #expect(s.contains("Told so far:\nLevel 1: L1 text."))
    #expect(s.contains("Already told on earlier visits:\n- [osm:way/1] level 1: Earlier visit."))
    #expect(s.contains("Continue the story from where it left off. Do not restart or repeat."))
}
@Test func continuationFactsWithoutMatchUseTopThreeInView() {
    func rc(_ name: String, _ d: Double, inView: Bool?) -> RankedCandidate {
        RankedCandidate(candidate: Candidate(id: "osm:node/\(name)", name: name, coordinate: .init(latitude: 0, longitude: 0),
                        kind: "historic=yes", summary: nil, wikipediaTitle: nil, wikidata: nil), distance: d, bearing: 0, inView: inView)
    }
    // ranked order is already in-view-first; the out-of-view one sits between to prove filtering, not slicing
    let g = Grounding(candidates: [rc("A", 10, inView: true), rc("B", 20, inView: true), rc("X", 5, inView: false),
                                   rc("C", 30, inView: true), rc("D", 40, inView: true)], address: nil, failedSources: [])
    let s = PromptBuilder.continuationInput(session: Self.session(grounding: g, matched: nil), level: .more, priors: [])
    #expect(s.contains("Facts:\n- A — historic=yes\n- B — historic=yes\n- C — historic=yes\n"))
    #expect(!s.contains("- X —") && !s.contains("- D —"))
    // heading unknown (inView nil everywhere) → nearest 3 in ranked order
    let g2 = Grounding(candidates: [rc("A", 10, inView: nil), rc("B", 20, inView: nil), rc("C", 30, inView: nil), rc("D", 40, inView: nil)],
                       address: nil, failedSources: [])
    let s2 = PromptBuilder.continuationInput(session: Self.session(grounding: g2, matched: nil), level: .more, priors: [])
    #expect(s2.contains("- C — historic=yes") && !s2.contains("- D —"))
    #expect(s.contains("Already told on earlier visits: nothing"))
}
```

```swift
// PhotoStoryFlowTests
@Test func continueAddsLevelWithoutImage() async throws {
    let http = Self.http(Self.openAIBody(#"{"story":"Level two."}"#))
    let flow = Self.flow(http)
    var s = try await Self.flow(Self.http()).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english).0
    let (next, usage) = try await flow.continueStory(s)
    #expect(next.levels == ["Once a coachman waited here.", "Level two."] && next.nextLevel == .evenMore)
    #expect(usage.count == 1 && usage[0].kind == .story)
    let r = http.requests.first { $0.url!.host == "api.openai.com" }!
    let content = ((r.jsonBody["input"] as! [[String: Any]])[0]["content"] as! [[String: Any]])
    #expect(content.count == 1)                        // text only, no image
    #expect(String(decoding: r.httpBody!, as: UTF8.self).contains("about 75 words"))
    s.levels = ["a", "b", "c"]
    let before = http.requests.count
    await #expect(throws: PhotoStoryError.noFurtherLevel) { try await flow.continueStory(s) }
    #expect(http.requests.count == before)
}
@Test func continuePassesSessionIDToPriorsForExclusion() async throws {
    let s = try await Self.flow(Self.http()).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english).0
    let excluded = LockedBox<UUID?>(nil)
    let ids = LockedBox<[String]>([])
    let flow = Self.flow(Self.http(Self.openAIBody(#"{"story":"Two."}"#))) { placeIDs, _, exclude in
        excluded.set(exclude); ids.set(placeIDs); return []
    }
    _ = try await flow.continueStory(s)
    #expect(excluded.value == s.id)
    #expect(ids.value == ["osm:node/1"])   // matched candidate only
}
```

- [ ] **Step 2: Run the tests.** Expected: compile failure.
- [ ] **Step 3: Implement.**
  - Continuation layout, in order: `Story length`, `Subject`, `Address`, `Facts:`, `Told so far:` (one `Level N: text` line per level), `Already told on earlier visits:` (or `…: nothing`), then `Task: Continue the story from where it left off. Do not restart or repeat. Take a new angle: another person, another moment in time, or something the listener can still see today that connects to it.`
  - `continueStory` calls `priors(ids, coordinate, session.id)` with ids = the matched candidate ID, or the Facts candidates' IDs. It sends `schemaName: "continuation"` with `continuationSchema` and no image.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: UI.** Under the story, a button labelled "Tell me more" (level 2) or "Even more" (level 3), hidden when `nextLevel == nil`. Each level appears as its own paragraph. The button shows a spinner while working. A failure shows the message inline with Retry and keeps the earlier levels on screen.
- [ ] **Step 6: Build check** (`xcodegen generate` plus the app build check). Expected: success.
- [ ] **Step 7: Commit** with `git commit -m "feat: tell me more and even more story levels"`.

### Task 12: Speech

Spec 8.1.5: "spoken with OpenAI text-to-speech. Audio plays through the phone speaker or connected AirPods." Spec 11: "TTS voice choice; caching of generated audio."

**Files:**
- Create: `Sources/MyGuideCore/Story/SpeechService.swift`, `MyGuide/Story/AudioPlayer.swift`
- Modify: `Sources/MyGuideCore/OpenAI/OpenAIClient.swift`, `MyGuide/Story/StoryViewModel.swift`, `MyGuide/Story/StoryView.swift`
- Test: `Tests/MyGuideCoreTests/SpeechServiceTests.swift`

**Interfaces:**
- Produces:
  - `OpenAIClient.speech(model: String, voice: String, instructions: String, text: String) async throws -> Data` (MP3)
  - `public struct SpeechService: Sendable { static let maxCharactersPerRequest = 4000; init(openAI: OpenAIClient, models: OpenAIModels = .current, cacheDirectory: URL, now: @escaping @Sendable () -> Date = Date.init); static func instructions(language: StoryLanguage) -> String; static func chunks(_ text: String, maxCharacters: Int) -> [String]; func audioFile(text: String, language: StoryLanguage, cacheKey: String) async throws -> (URL, UsageEntry?) }`
  - `@MainActor final class AudioPlayer { func play(_ url: URL); func stop(); var isPlaying: Bool }` (app)
  - Cache key convention: `"\(session.id.uuidString)-\(levelIndex + 1)"`.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct SpeechServiceTests {
    func dir() -> URL { FileManager.default.temporaryDirectory.appending(path: "speech-\(UUID().uuidString)") }

    @Test func requestShapeAndUsage() async throws {
        let http = StubHTTPClient { _ in (200, Data([0x49, 0x44, 0x33])) }
        let svc = SpeechService(openAI: OpenAIClient(apiKey: "k", http: http), cacheDirectory: dir(), now: { Date(timeIntervalSince1970: 1) })
        let (url, usage) = try await svc.audioFile(text: "One two three four", language: .english, cacheKey: "s-1")
        let r = http.requests[0]
        #expect(r.url!.absoluteString == "https://api.openai.com/v1/audio/speech")
        let b = r.jsonBody
        #expect(b["model"] as? String == "gpt-4o-mini-tts" && b["voice"] as? String == "coral")
        #expect(b["input"] as? String == "One two three four" && b["response_format"] as? String == "mp3")
        #expect((b["instructions"] as? String)?.contains("friend") == true)
        #expect(try Data(contentsOf: url) == Data([0x49, 0x44, 0x33]))
        #expect(usage == UsageEntry(date: Date(timeIntervalSince1970: 1), kind: .speech, model: "gpt-4o-mini-tts",
                                    inputTokens: 0, outputTokens: 0, words: 4, images: 0))
    }
    @Test func secondCallHitsCache() async throws {
        let http = StubHTTPClient { _ in (200, Data([1])) }
        let svc = SpeechService(openAI: OpenAIClient(apiKey: "k", http: http), cacheDirectory: dir())
        _ = try await svc.audioFile(text: "Hi", language: .english, cacheKey: "s-1")
        let (_, usage) = try await svc.audioFile(text: "Hi", language: .english, cacheKey: "s-1")
        #expect(http.requests.count == 1 && usage == nil)
    }
    @Test func longTextIsChunkedAtSentences() async throws {
        // 50 sentences of 99 chars joined by single spaces = 50·99 + 49 = 4999 chars. Greedy ≤ 4000:
        // 40 sentences = 40·99 + 39 = 3999; a 41st would make 3999 + 1 + 99 = 4099 > 4000.
        // Remaining 10 sentences = 10·99 + 9 = 999 → 2 chunks
        let sentence = String(repeating: "a", count: 98) + "."
        let text = Array(repeating: sentence, count: 50).joined(separator: " ")
        let chunks = SpeechService.chunks(text, maxCharacters: 4000)
        #expect(chunks.count == 2 && chunks[0].count == 3999 && chunks[1].count == 999)
        let http = StubHTTPClient { _ in (200, Data([7])) }
        let (url, _) = try await SpeechService(openAI: OpenAIClient(apiKey: "k", http: http), cacheDirectory: dir())
            .audioFile(text: text, language: .english, cacheKey: "long")
        #expect(http.requests.count == 2 && (try Data(contentsOf: url)) == Data([7, 7]))
    }
    @Test func norwegianInstructions() {
        #expect(SpeechService.instructions(language: .norwegian).contains("Norwegian Bokmål"))
    }
}
```

- [ ] **Step 2: Run the tests.** Expected: compile failure.
- [ ] **Step 3: Implement.**
  - Speech instructions (English): `Warm, relaxed and conversational, like a friend telling a story on a walk. Unhurried, about 150 words per minute.` For Norwegian, append ` Speak Norwegian Bokmål with a natural Norwegian accent.`
  - Chunking: split after `.`, `!` or `?` followed by whitespace, then pack sentences greedily, joined by a single space. A single sentence longer than the limit is hard-split at the last space before the limit.
  - The cache file is `<cacheDirectory>/<cacheKey>-<language.rawValue>.mp3`. Create the directory if missing, and write atomically.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: App.**
  - `AudioPlayer` sets the `AVAudioSession` category to `.playback`, mode `.spokenAudio` (routes to AirPods when connected), and plays with `AVAudioPlayer`.
  - The cache directory is `Caches/Speech`.
  - The view model auto-plays each new level as soon as its text is shown; text never waits for audio. There is a Play/Stop toggle per level.
  - A speech failure shows a small inline "Couldn't play audio" with Retry; the text stays.
- [ ] **Step 6: Build check.** Expected: success.
- [ ] **Step 7: Commit** with `git commit -m "feat: spoken stories with cached OpenAI TTS"`.

- [ ] **Step 8: Milestone 2 gate (owner, on the phone).**
  1. Take a photo: the text appears, then speech starts within a few seconds, and plays through AirPods when they are connected.
  2. Tap "Tell me more" and listen: level 2 continues the first story without repeating it, and lasts about 30 s.
  3. Tap "Even more": level 3 lasts about 2 min, and then the button disappears.
  4. Replay level 1: it plays instantly from the cache.

---

## Milestone 3: Memory (spec 9, step 3)

### Task 13: SwiftData models and memory store

Spec 8.2: "A local, on-device store of: places visited, stories told (all levels, full text), photos taken … Every AI story request includes a compact summary of what was already told about that place". Walked tracks and buzz state belong to phase 2 and are not built here.

**Files:**
- Create: `Sources/MyGuideCore/Memory/MemoryModels.swift`, `Sources/MyGuideCore/Memory/MemoryStore.swift`
- Test: `Tests/MyGuideCoreTests/MemoryStoreTests.swift`

**Interfaces:**
- Produces:
  - `@Model final class CaptureRecord { @Attribute(.unique) var id: UUID; var takenAt: Date; var latitude: Double; var longitude: Double; var placeID: String?; var title: String; var subject: String; var language: String; @Attribute(.externalStorage) var photoJPEG: Data; @Attribute(.externalStorage) var thumbnailJPEG: Data; var captureJSON: Data; var groundingJSON: Data; var identifiedJSON: Data; @Attribute(.externalStorage) var thenImagePNG: Data?; @Relationship(deleteRule: .cascade, inverse: \StoryRecord.capture) var stories: [StoryRecord] }`
  - `@Model final class StoryRecord { var level: Int; var text: String; var placeID: String?; var createdAt: Date; var capture: CaptureRecord? }`
  - `@Model final class PlaceRecord { @Attribute(.unique) var id: String; var name: String; var latitude: Double; var longitude: Double; var firstSeenAt: Date; var deepestLevelHeard: Int; var lastHeardAt: Date? }`
  - `@Model final class UsageRecord { var date: Date; var kind: String; var model: String; var inputTokens: Int; var outputTokens: Int; var words: Int; var images: Int; var estimatedUSD: Double?; }` (filled in Task 16)
  - `public enum MemorySchema { static let models: [any PersistentModel.Type] = [CaptureRecord.self, StoryRecord.self, PlaceRecord.self, UsageRecord.self] }`
  - `public enum MemoryError: Error, Equatable { case noPosition, corruptRecord }` (`corruptRecord` is thrown by `session(for:)` when a JSON blob fails to decode)
  - `@MainActor public final class MemoryStore { static let priorRadius = 75.0; static let priorLimit = 12; init(context: ModelContext); func save(_ session: StorySession) throws; func session(for record: CaptureRecord) throws -> StorySession; func priorStories(placeIDs: [String], near: Coordinate, excludingSession: UUID?) throws -> [PriorStory]; func place(id: String) throws -> PlaceRecord? }`

Decision (spec 8.2 "heard"): a level counts as heard when it is saved, because its text is shown immediately. `deepestLevelHeard` = the highest saved level for that place.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor @Suite struct MemoryStoreTests {
    let store: MemoryStore
    init() throws {
        let c = try ModelContainer(for: Schema(MemorySchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        store = MemoryStore(context: c.mainContext)
    }
    // 1 m of latitude = 1/111_195 degree
    static func session(placeID: String?, n metres: Double = 0, levels: [String], at t: TimeInterval = 0) -> StorySession {
        let cand = RankedCandidate(candidate: Candidate(id: placeID ?? "osm:node/x", name: "Gate", coordinate: .init(latitude: 0, longitude: 0),
                                   kind: "historic=yes", summary: nil, wikipediaTitle: nil, wikidata: nil), distance: 10, bearing: 0, inView: true)
        return StorySession(id: UUID(),
            capture: CaptureContext(coordinate: .init(latitude: metres / 111_195, longitude: 0), horizontalAccuracy: 5, heading: nil,
                                    headingAccuracy: nil, horizontalFOV: 55, takenAt: Date(timeIntervalSince1970: t), source: .camera),
            photoJPEG: Data([2]), thumbnailJPEG: Data([1]), language: .english, grounding: Grounding(candidates: [cand], address: nil, failedSources: []),
            identified: IdentifiedStory(subject: "Gate", confidence: .likely, matchedCandidateID: placeID, title: "T", era: "E", story: levels[0]),
            levels: levels)
    }
    static let origin = Coordinate(latitude: 0, longitude: 0)

    @Test func saveAndRestoreRoundTrips() throws {
        let s = Self.session(placeID: "osm:node/1", levels: ["one", "two"])
        try store.save(s)
        let rec = try #require(try store.context.fetch(FetchDescriptor<CaptureRecord>()).first)
        #expect(try store.session(for: rec) == s)
    }
    @Test func saveIsIdempotentAndAppendsNewLevels() throws {
        var s = Self.session(placeID: "osm:node/1", levels: ["one"])
        try store.save(s); s.levels.append("two"); try store.save(s); try store.save(s)
        #expect(try store.context.fetch(FetchDescriptor<StoryRecord>()).map(\.level).sorted() == [1, 2])
        #expect(try store.context.fetchCount(FetchDescriptor<CaptureRecord>()) == 1)
        #expect(try store.place(id: "osm:node/1")?.deepestLevelHeard == 2)
    }
    @Test func priorsByPlaceIDAnywhere() throws {
        try store.save(Self.session(placeID: "osm:node/1", n: 5_000, levels: ["far but same place"]))
        let p = try store.priorStories(placeIDs: ["osm:node/1"], near: Self.origin, excludingSession: nil)
        #expect(p.map(\.text) == ["far but same place"])
    }
    @Test func unidentifiedPriorsOnlyWithinRadius() throws {
        // 40 m north = 0.0003597°, 200 m = 0.0017986°; radius 75 m
        try store.save(Self.session(placeID: nil, n: 40, levels: ["near unknown"]))
        try store.save(Self.session(placeID: nil, n: 200, levels: ["far unknown"]))
        let p = try store.priorStories(placeIDs: [], near: Self.origin, excludingSession: nil)
        #expect(p.map(\.text) == ["near unknown"] && p[0].placeID == nil)
    }
    @Test func saveWithoutCoordinateThrows() {
        var s = Self.session(placeID: nil, levels: ["x"]); s.capture.coordinate = nil
        #expect(throws: MemoryError.noPosition) { try store.save(s) }
    }
    @Test func excludesCurrentSessionAndCapsNewestTwelve() throws {
        let current = Self.session(placeID: "osm:node/1", levels: ["mine"], at: 999)
        try store.save(current)
        for i in 0..<15 { try store.save(Self.session(placeID: "osm:node/1", levels: ["s\(i)"], at: Double(i))) }
        let p = try store.priorStories(placeIDs: ["osm:node/1"], near: Self.origin, excludingSession: current.id)
        #expect(p.count == 12 && p.first?.text == "s14" && !p.contains { $0.text == "mine" })
    }
}
```

(`MemoryStore` exposes `let context: ModelContext` so the tests can reach it.)

- [ ] **Step 2: Run the tests.** Expected: compile failure.
- [ ] **Step 3: Implement.**
  - `save` throws `MemoryError.noPosition` when `session.capture.coordinate` is nil; the flow never produces such a session, but the store must not write a record at 0,0.
  - The JSON blobs use `JSONEncoder`/`JSONDecoder`, with `CaptureContext`, `Grounding` and `IdentifiedStory` all `Codable`.
  - `StoryRecord.createdAt` = `capture.takenAt` plus the level index in seconds (keeps order stable).
  - `PlaceRecord` is upserted from `session.matchedCandidate` on save.
  - `priorStories`: fetch `StoryRecord`s whose `placeID` is in `placeIDs`, plus captures with `placeID == nil` inside a bounding box. The box is ±`priorRadius/111_195`° latitude and ±`priorRadius/(111_195·cos φ)`° longitude, then filtered by `GeoMath.distance ≤ priorRadius`. Exclude the session, sort by `createdAt` descending, and take `priorLimit`.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: Commit** with `git commit -m "feat(core): SwiftData memory of places, captures and stories"`.

### Task 14: App: persist sessions, feed priors, history

Spec 8.2; spec 8.1.8: "The story, photo thumbnail, place, position and time are saved to memory."

**Files:**
- Create: `MyGuide/History/HistoryView.swift`
- Modify: `MyGuide/MyGuideApp.swift` (`.modelContainer(for: MemorySchema.models)`), `MyGuide/AppServices.swift`, `MyGuide/Story/StoryViewModel.swift`, `MyGuide/Capture/CaptureScreen.swift`

**Interfaces:**
- Consumes: `MemoryStore`, `MemorySchema`, `PriorStoryLookup`.
- Produces: `StoryViewModel.init(session: StorySession, services: AppServices)`, which opens an existing session from history.

- [ ] **Step 1: Wire priors.** `AppServices.makeFlow()` passes a `PriorStoryLookup` that hops to the main actor (`await MainActor.run { (try? memory.priorStories(...)) ?? [] }`).
- [ ] **Step 2: Persist.** `StoryViewModel` calls `memory.save(session)` after every successful level. A save failure is logged with `os.Logger` and shown as a non-blocking banner, "Couldn't save to memory". It never hides the story.
- [ ] **Step 3: History.** `HistoryView` uses `@Query(sort: \CaptureRecord.takenAt, order: .reverse)` and shows rows with the thumbnail, title, subject, date and city. A row opens `StoryView` with the restored session (`memory.session(for:)`), so "Tell me more" works after a relaunch. Swipe to delete. Add a toolbar button on `CaptureScreen`.
- [ ] **Step 4: Build check.** Expected: success.
- [ ] **Step 5: Commit** with `git commit -m "feat(app): save stories to memory, history list, priors in requests"`.
- [ ] **Step 6: Milestone 3 gate (owner, on the phone).**
  1. Photograph a landmark, then photograph it again from a slightly different spot: the second story takes a new angle and doesn't repeat the first.
  2. Force-quit the app, open History and open the first session: all its levels are there, and "Tell me more" continues from them.
  3. Delete a history row: it is gone after a relaunch.

---

## Milestone 4: Norwegian, "then" image, usage and cost (spec 9, step 4)

### Task 15: "Then" image

Spec 8.1.7: "'Show me how it looked' generates a labelled AI reconstruction image of the scene in the relevant era." Spec 5: "Every generated image is clearly labelled as an AI reconstruction."

**Files:**
- Modify: `Sources/MyGuideCore/OpenAI/OpenAIClient.swift`, `Sources/MyGuideCore/Story/PromptBuilder.swift`, `Sources/MyGuideCore/Story/PhotoStoryFlow.swift`, `Sources/MyGuideCore/Memory/MemoryStore.swift`, `MyGuide/Story/StoryView.swift`, `MyGuide/Story/StoryViewModel.swift`
- Test: `Tests/MyGuideCoreTests/ThenImageTests.swift`, `Tests/MyGuideCoreTests/MemoryStoreTests.swift`

**Interfaces:**
- Produces:
  - `OpenAIClient.image(model: String, prompt: String, size: String, quality: String) async throws -> Data` (decoded `data[0].b64_json`)
  - `public enum ThenImage { static let label = "AI reconstruction — not a real photo"; static let size = "1024x1536"; static let quality = "medium" }`
  - `PromptBuilder.thenImagePrompt(session: StorySession) -> String`
  - `PhotoStoryFlow.thenImage(for session: StorySession) async throws -> (Data, UsageEntry)`
  - `MemoryStore.saveThenImage(_ png: Data, sessionID: UUID) throws`, `MemoryStore.thenImage(sessionID: UUID) throws -> Data?`

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct ThenImageTests {
    let s = PromptBuilderTests.session()   // subject Michaelertor, era "around 1890", address Michaelerplatz, Vienna, Austria

    @Test func promptNamesSubjectPlaceEraAndStyle() {
        let p = PromptBuilder.thenImagePrompt(session: s)
        #expect(p.hasPrefix("Historical reconstruction illustration of Michaelertor at Michaelerplatz, Vienna, Austria, as it looked around 1890."))
        #expect(p.contains("Painterly illustration style with visible brushwork, clearly not a photograph."))
        #expect(p.contains("No text, no captions, no modern objects."))
    }
    @Test func promptWithoutAddressDropsAtClause() {
        var g = PromptBuilderTests.grounding; g.address = nil
        #expect(PromptBuilder.thenImagePrompt(session: PromptBuilderTests.session(grounding: g))
            .hasPrefix("Historical reconstruction illustration of Michaelertor, as it looked around 1890."))
    }
    @Test func flowRequestsImageAndReportsUsage() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let http = StubHTTPClient { _ in (200, Data(#"{"data":[{"b64_json":"\#(png.base64EncodedString())"}]}"#.utf8)) }
        let (data, usage) = try await PhotoStoryFlowTests.flow(http).thenImage(for: s)
        #expect(data == png)
        #expect(usage == UsageEntry(date: Date(timeIntervalSince1970: 5), kind: .image, model: "gpt-image-1",
                                    inputTokens: 0, outputTokens: 0, words: 0, images: 1))
        let r = http.requests[0]
        #expect(r.url!.absoluteString == "https://api.openai.com/v1/images/generations" && r.timeoutInterval == 120)
        let b = r.jsonBody
        #expect(b["size"] as? String == "1024x1536" && b["quality"] as? String == "medium" && b["n"] as? Int == 1)
        #expect(b["prompt"] as? String == PromptBuilder.thenImagePrompt(session: s))
    }
    @Test func missingImageDataIsMalformed() async {
        let http = StubHTTPClient { _ in (200, Data(#"{"data":[]}"#.utf8)) }
        await #expect(throws: OpenAIError.malformedResponse) { try await PhotoStoryFlowTests.flow(http).thenImage(for: s) }
    }
}
// MemoryStoreTests
@Test func thenImageRoundTrips() throws {
    let s = Self.session(placeID: "osm:node/1", levels: ["one"])
    try store.save(s)
    try store.saveThenImage(Data([9, 9]), sessionID: s.id)
    #expect(try store.thenImage(sessionID: s.id) == Data([9, 9]))
    #expect(try store.thenImage(sessionID: UUID()) == nil)
}
```

- [ ] **Step 2: Run the tests.** Expected: compile failure.
- [ ] **Step 3: Implement.** Prompt template:

```
Historical reconstruction illustration of {subject} at {address.display}, as it looked {era}. Street-level view from roughly where the photographer stood, people of that time going about their day in period clothing, with the carts, trades and sounds of the era suggested in the scene. Painterly illustration style with visible brushwork, clearly not a photograph. No text, no captions, no modern objects.
```

  When the address is nil, drop ` at {address.display}`. The image request has a 120 s timeout.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: UI.** A "Show me how it looked" button, shown once level 1 exists. The image is shown with a permanent overlay banner containing `ThenImage.label`, drawn on top in the view and not optional. The image is saved to memory, so reopening from history shows it without regenerating.
- [ ] **Step 6: Build check, then commit** with `git commit -m "feat: labelled AI 'then' reconstruction images"`.

### Task 16: Usage and cost counter, language setting

Spec 9 step 1: "a simple running count of API usage and estimated cost". Spec 10: "because predictable cost was the owner's reason for one provider". Spec 6: "English by default; Norwegian as a setting."

**Files:**
- Create: `Sources/MyGuideCore/Usage/PriceTable.swift`
- Modify: `Sources/MyGuideCore/Memory/MemoryStore.swift`, `MyGuide/Settings/SettingsView.swift`, `MyGuide/Story/StoryViewModel.swift`, `MyGuide/AppServices.swift`
- Test: `Tests/MyGuideCoreTests/PriceTableTests.swift`, `Tests/MyGuideCoreTests/MemoryStoreTests.swift`

**Interfaces:**
- Produces:
  - `public enum Price: Sendable, Equatable { case tokens(inputPerMillion: Double, outputPerMillion: Double), speechPerMinute(Double), perImage(Double) }`
  - `public struct PriceTable: Sendable { var asOf: String; var prices: [String: Price]; static let current: PriceTable; func estimatedUSD(_ entry: UsageEntry) -> Double? /* nil = unknown model */ }`
  - `MemoryStore.recordUsage(_ entries: [UsageEntry], prices: PriceTable) throws`, `MemoryStore.usageTotals(now: Date, calendar: Calendar) throws -> UsageTotals`, where `public struct UsageTotals: Equatable { var monthUSD: Double; var allTimeUSD: Double; var monthRequests: Int; var unpricedRequests: Int }`
  - App: `@AppStorage("storyLanguage") var storyLanguage: StoryLanguage = .english`

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct PriceTableTests {
    let t = PriceTable(asOf: "test", prices: ["text": .tokens(inputPerMillion: 0.25, outputPerMillion: 2.00),
                                             "tts": .speechPerMinute(0.015), "img": .perImage(0.063)])
    func e(_ kind: UsageKind, _ model: String, i: Int = 0, o: Int = 0, w: Int = 0, n: Int = 0) -> UsageEntry {
        UsageEntry(date: .now, kind: kind, model: model, inputTokens: i, outputTokens: o, words: w, images: n)
    }
    @Test func tokenCost() {
        // 1_200·0.25/1e6 = 0.0003; 400·2.00/1e6 = 0.0008 → 0.0011
        #expect(abs(t.estimatedUSD(e(.story, "text", i: 1_200, o: 400))! - 0.0011) < 1e-12)
        // 10_000·0.25/1e6 = 0.0025; 0 output → 0.0025
        #expect(abs(t.estimatedUSD(e(.story, "text", i: 10_000))! - 0.0025) < 1e-12)
    }
    @Test func speechCostFromWordsAt150wpm() {
        // 300 words / 150 = 2 min · 0.015 = 0.03;  50 words / 150 = 0.3333 min · 0.015 = 0.005
        #expect(abs(t.estimatedUSD(e(.speech, "tts", w: 300))! - 0.03) < 1e-12)
        #expect(abs(t.estimatedUSD(e(.speech, "tts", w: 50))! - 0.005) < 1e-12)
    }
    @Test func imageCost() {
        // 1·0.063 = 0.063; 2·0.063 = 0.126
        #expect(t.estimatedUSD(e(.image, "img", n: 1)) == 0.063)
        #expect(abs(t.estimatedUSD(e(.image, "img", n: 2))! - 0.126) < 1e-12)
    }
    @Test func unknownModelIsNil() { #expect(t.estimatedUSD(e(.story, "nope", i: 5)) == nil) }
    @Test func currentTableCoversDefaultModels() {
        let m = OpenAIModels.current
        #expect([m.story, m.speech, m.image].allSatisfy { PriceTable.current.prices[$0] != nil })
    }
}
// MemoryStoreTests
@Test func usageTotalsByMonth() throws {
    // Oct 3 $0.01 + Oct 20 $0.02 = month $0.03; + Sep 30 $0.05 = all-time $0.08; one unpriced in Oct
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    func d(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    let table = PriceTable(asOf: "t", prices: ["img": .perImage(0.01)])
    try store.recordUsage([UsageEntry(date: d("2026-10-03T12:00:00Z"), kind: .image, model: "img", inputTokens: 0, outputTokens: 0, words: 0, images: 1),
                           UsageEntry(date: d("2026-10-20T12:00:00Z"), kind: .image, model: "img", inputTokens: 0, outputTokens: 0, words: 0, images: 2),
                           UsageEntry(date: d("2026-09-30T23:59:59Z"), kind: .image, model: "img", inputTokens: 0, outputTokens: 0, words: 0, images: 5),
                           UsageEntry(date: d("2026-10-21T12:00:00Z"), kind: .story, model: "unknown", inputTokens: 9, outputTokens: 9, words: 0, images: 0)],
                          prices: table)
    let u = try store.usageTotals(now: d("2026-10-27T10:00:00Z"), calendar: cal)
    #expect(abs(u.monthUSD - 0.03) < 1e-12 && abs(u.allTimeUSD - 0.08) < 1e-12)
    #expect(u.monthRequests == 3 && u.unpricedRequests == 1)
}
```

- [ ] **Step 2: Run the tests.** Expected: compile failure.
- [ ] **Step 3: Implement.** The `PriceTable.current` values below are from the plan date. **Before committing, check them against https://openai.com/api/pricing and update both the values and `asOf` if they have changed:**

  `asOf: "2026-10-27"`, `gpt-5-mini: .tokens(0.25, 2.00)`, `gpt-4o-mini-tts: .speechPerMinute(0.015)`, `gpt-image-1: .perImage(0.063)` (medium, 1024×1536).

  If any default model in `OpenAIModels.current` no longer exists, replace it with its current equivalent (spec 11) and update the table. `estimatedUSD` is stored at record time, so a later price change does not rewrite history. `unpricedRequests` counts records this month with `estimatedUSD == nil`.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: App.**
  - Every `UsageEntry` returned by the flow or by `SpeechService` (a cache hit returns nil, which records nothing) is passed to `memory.recordUsage(_, prices: .current)`.
  - Settings shows "This month: $0.42 (37 requests)" and "All time: $3.10". If `unpricedRequests > 0`, it adds "some usage not priced", and it shows "Prices as of 2026-10-27".
  - Settings gets a `Picker` for the story language (English / Norsk). New sessions use the setting; existing sessions keep their own `language`.
- [ ] **Step 6: Build check, then commit** with `git commit -m "feat: usage and cost counter, Norwegian story language setting"`.

### Task 17: Phase 1 acceptance on device

**Files:** none (verification only; fix and commit within the owning task if anything fails).

- [ ] **Step 1: Full test run.** Run `swift test --package-path Packages/MyGuideCore`. Expected: all tests pass, 0 failures.
- [ ] **Step 2: Clean build.** Run `xcodegen generate`, then the app build check. Expected: success with no warnings in `MyGuideCore`.
- [ ] **Step 3: Owner walk test (in a real old town, or the nearest historic street).**
  1. Repeat all the milestone 1–3 gates.
  2. Switch to Norsk: the next story and its speech are in Norwegian, and the Wikipedia grounding works. When fewer than 3 Norwegian articles exist, English articles fill in.
  3. "Show me how it looked": a painterly image appears with the label `AI reconstruction — not a real photo` always visible, and history shows it again without regenerating.
  4. Settings shows the cost after a session, and the number goes up after each request.
  5. Spot-check five stories against Wikipedia: no invented facts presented as fact, and legends are labelled (spec 5's first anti-goal). Report any story that fails this to Claude along with its text; it becomes a prompt fix with a regression test in `PromptBuilderTests`.
- [ ] **Step 4: Commit** any fixes from Step 3 with tests, then tag: `git tag phase-1`.
