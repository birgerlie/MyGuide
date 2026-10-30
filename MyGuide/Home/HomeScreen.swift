import MapKit
import MyGuideCore
import SwiftData
import SwiftUI
import UIKit

/// Where a tab's navigation stack can go. Both tabs push the same routes, so a walking notification can open its
/// story on top of whatever is showing and a new photo story can replace the camera in a single change.
enum HomeRoute: Hashable {
    case camera
    case history
    case settings
    /// The story in `HomeScreen.pushedModel`: a fresh photo story, or a stored one opened from «Sist oppdaget».
    /// Pushed only on the Utforsk stack.
    case photoStory
    case walkStory(UUID)
    /// The day story of a diary day, by `Diary.dayKey`.
    case dayStory(String)
}

/// The app's root (spec 14, amended 2026-10-30): the tab bar with «Utforsk», the «Rundt deg» map with its sheet,
/// «Kamera», which opens the camera over the map, «Turer» (a free walk or a tour), and «Dagbok», the diary with History and Settings in its
/// top bar, and while a walk or a tour runs the walking line over the tab bar, which opens the walking sheet. Each tab has its own stack. This screen is the one
/// owner of the shared `LocationProvider` (start, stop and `onFix`), of the camera's running and of the map model's
/// appear/disappear, all driven from what is on top. The camera is off until asked for, so opening the app costs no
/// camera power.
struct HomeScreen: View {
    let services: AppServices

    @State private var tab: RootTab = .explore
    @State private var path: [HomeRoute] = []
    @State private var diaryPath: [HomeRoute] = []
    /// The photo story on the `.photoStory` route.
    @State private var pushedModel: StoryViewModel?
    /// Kept across tab switches and pushed screens (spec 16.8). The map frames the owner on the first fix; after
    /// that only the locate button moves it.
    @State private var mapPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var sheetExpanded = false
    /// The Utforsk tab's height, so the expanded sheet leaves part of the map in view.
    @State private var exploreHeight: CGFloat = 0
    @State private var errorText: String?
    /// The walking sheet, opened from the walking line.
    @State private var walkingSheetShown = false
    @Query(HomeScreen.recentPhotos) private var photos: [CaptureRecord]
    @Query(HomeScreen.recentWalks) private var walks: [WalkStoryRecord]
    /// The screen texts follow the iPhone's language (spec 17).
    private var screenLanguage: StoryLanguage { UILanguage.current }
    @Environment(\.scenePhase) private var scenePhase

    /// How many stories «Sist oppdaget» shows.
    static let recentCount = 3
    /// The share of the Utforsk tab the expanded sheet's lists may take.
    static let listShare: CGFloat = 0.35

    /// The shared provider for every screen that needs a position: the map, the camera HUD and a story's "Use where
    /// I am now". Stored in `AppServices` so it is made once; this screen alone starts and stops it and sets `onFix`.
    private var location: LocationProvider { services.location }
    /// What the map shows and selects; reads `location`.
    private var around: AroundModel { services.around }

    private static var recentPhotos: FetchDescriptor<CaptureRecord> {
        var descriptor = FetchDescriptor<CaptureRecord>(sortBy: [SortDescriptor(\.takenAt, order: .reverse)])
        descriptor.fetchLimit = recentCount
        return descriptor
    }

    private static var recentWalks: FetchDescriptor<WalkStoryRecord> {
        var descriptor = FetchDescriptor<WalkStoryRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = recentCount
        return descriptor
    }

    var body: some View {
        RootTabs(selection: $tab, language: screenLanguage, openCamera: openCamera,
                 accessoryEnabled: walkingActive) {
            NavigationStack(path: $path) {
                explore
                    .navigationDestination(for: HomeRoute.self, destination: destination)
            }
        } tours: {
            ToursTab(model: services.tourBuilder, walking: services.walking, language: screenLanguage,
                     onStart: startTour)
        } diary: {
            NavigationStack(path: $diaryPath) {
                diary
                    .navigationDestination(for: HomeRoute.self, destination: destination)
            }
        } accessory: {
            WalkingLine(walking: services.walking, position: around.position, language: screenLanguage,
                        open: openWalkingSheet)
        }
        .sheet(isPresented: $walkingSheetShown) {
            WalkingSheet(walking: services.walking, position: around.position, language: screenLanguage)
        }
        .alert(AroundTexts.openFailed(screenLanguage), isPresented: errorPresented) {
            Button(AroundTexts.ok(screenLanguage), role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        // A tap on a walking notification, the panel's title or a myguide://walk link opens that story on top of
        // whatever is showing (initial: a cold launch from the notification sets it before this view exists).
        .onChange(of: services.walking.stories.openID, initial: true) { _, id in
            guard let id else { return }
            services.walking.stories.openID = nil
            // The story opens on the stack under the walking sheet: close the sheet so it is seen.
            walkingSheetShown = false
            openWalkStory(id)
        }
        .onChange(of: path) { old, path in
            // Each opening of the camera starts at 1×, as a fresh camera screen always did.
            if path.contains(.camera), !old.contains(.camera) { services.camera.setZoom(1) }
            // The story screen is being dropped (navigated back): stop its work silently.
            if !path.contains(.photoStory) { setPushedModel(nil) }
            keepDayStories()
        }
        .onChange(of: diaryPath) { keepDayStories() }
        // A walk that starts while «Turer» is showing («Gå en tur» there, or the watch) shows the map, as a tour start
        // does. A refused start stays on «Turer», where the reason shows under the button.
        .onChange(of: services.walking.isOn) { _, isOn in
            guard isOn, tab == .tours else { return }
            path = []
            tab = .explore
        }
        // Location runs while the map or the camera is on top, while a story offers "Use where I am now", while
        // the tours tab is selected, or while a tour is being planned.
        .onChange(of: locationWanted, initial: true) { _, wanted in
            if wanted {
                // Fixes while the map or the camera (or a story's "Use where I am now") is up keep the nearby list
                // current.
                let services = services
                location.onFix = { services.noteForegroundFix($0) }
                location.start()
            } else {
                location.stop()
            }
        }
        // The phone heading and the map model's tick run only while the map is on screen.
        .onChange(of: mapVisible, initial: true) { _, visible in
            if visible { around.appear() } else { around.disappear() }
        }
        // The camera runs only while its screen is on top and the app is not in the background. Driven from here,
        // not by the camera screen's appear/disappear, so a rebuilt or duplicated screen can never start a second
        // session or stop the visible one. Coming back from the background restarts it (and re-checks access).
        .onChange(of: cameraWanted, initial: true) { _, wanted in
            if wanted {
                Task { await services.camera.start() }
            } else {
                Task { await services.camera.stop() }
            }
        }
    }

    // MARK: - Utforsk

    private var explore: some View {
        ZStack {
            AroundMap(model: around, position: $mapPosition, tour: services.walking.tour, language: screenLanguage)
            // The free part of the map (inside the safe area, above the sheet), whatever the map itself does with
            // safe areas: the pill is placed in it. Transparent to touches.
            Color.clear
                .allowsHitTesting(false)
                .overlay(alignment: .topLeading) { appPill }
        }
        // The map keeps its attribution and controls above the sheet, and draws under it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AroundSheet(model: around, walking: services.walking, placeImages: services.placeImages,
                        memoryFallback: services.memoryFallback, authorization: location.authorization,
                        language: screenLanguage, recent: recentStories, isExpanded: $sheetExpanded,
                        maxListHeight: exploreHeight * Self.listShare, openSelected: openSelectedPlace,
                        openCamera: openCamera, openRecent: openRecent,
                        walkingLineInSheet: !RootTab.hasAccessory,
                        openWalking: openWalkingSheet)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { exploreHeight = $0 }
        .toolbar(.hidden, for: .navigationBar)
    }

    /// «MyGuide» in Playfair on an ivory pill (spec 14).
    private var appPill: some View {
        Text(AroundTexts.appName())
            .font(.custom(Theme.FontName.display, size: 22, relativeTo: .title2))
            .foregroundStyle(Theme.Colour.forest)
            .padding(.horizontal, Theme.Spacing.margin)
            .padding(.vertical, Theme.Spacing.unit)
            .background(Theme.Colour.ivory, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            .padding(.leading, Theme.Spacing.margin)
            .padding(.top, Theme.Spacing.unit)
            .accessibilityAddTraits(.isHeader)
    }

    private var recentStories: [RecentStory] {
        RecentStory.newest(photos: photos.map { ($0.id, $0.title, $0.takenAt) },
                           walks: walks.map { ($0.id, $0.title, $0.createdAt) }, limit: Self.recentCount)
    }

    // MARK: - Dagbok

    private var diary: some View {
        DiaryView(services: services, location: location, openWalkStory: openWalkStory,
                  openDayStory: { diaryPath.append(.dayStory($0.id)) })
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: HomeRoute.history) { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel(AroundTexts.history(screenLanguage))
                        // The diary keeps the owner on it while photos are added, so the summary is always seen.
                        .disabled(services.diary.isImporting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: HomeRoute.settings) { Image(systemName: "gearshape") }
                        .accessibilityLabel(AroundTexts.settings(screenLanguage))
                        .disabled(services.diary.isImporting)
                }
            }
    }

    // MARK: - Destinations

    @ViewBuilder
    private func destination(_ route: HomeRoute) -> some View {
        switch route {
        case .camera:
            CaptureScreen(services: services, location: location, onPhoto: photoReady)
                .toolbar(.hidden, for: .tabBar)
        case .history:
            HistoryView(services: services, location: location)
        case .settings:
            SettingsView(services: services)
        case .photoStory:
            if let pushedModel {
                StoryView(model: pushedModel, location: location)
            }
        case .walkStory(let id):
            WalkStoryView(stories: services.walking.stories, placeImages: services.placeImages, id: id)
                .id(id)
        case .dayStory(let dayKey):
            DayStoryScreen(model: services.diary.dayStory(dayKey, services: services))
                .id(dayKey)
        }
    }

    // MARK: - Navigation

    /// The «Kamera» tab or a card's «Ta bilde»: the camera on the Utforsk stack, from any tab. A camera already on the
    /// stack (under a walk story) comes back to the top rather than a second one being pushed.
    private func openCamera() {
        tab = .explore
        if let index = path.firstIndex(of: .camera) {
            path = Array(path[...index])
        } else {
            path.append(.camera)
        }
    }

    private func openWalkingSheet() {
        walkingSheetShown = true
    }

    /// While a walk or a tour runs, the walking line shows over the tab bar.
    private var walkingActive: Bool {
        services.walking.isOn || services.walking.tour != nil
    }

    /// A photo was taken or picked on the camera screen: its story takes the camera's place in the stack, so going
    /// back lands on the map with the camera off. If something was pushed over the camera meanwhile (a walk story),
    /// it stays on top and the photo story waits under it. If the camera left the stack (the owner went back) the
    /// photo is dropped before any paid request starts, rather than hijacking the screen.
    private func photoReady(_ photo: Data, _ capture: CaptureContext, _ language: StoryLanguage) {
        guard let newPath = StoryPath.replacingCamera(in: path, camera: HomeRoute.camera, with: .photoStory) else {
            return
        }
        setPushedModel(startStory(photo: photo, capture: capture, language: language))
        path = newPath
    }

    /// Every replacement cancels the old story first, so no request or audio outlives its screen.
    private func setPushedModel(_ model: StoryViewModel?) {
        pushedModel?.cancel()
        pushedModel = model
    }

    private func startStory(photo: Data, capture: CaptureContext, language: StoryLanguage) -> StoryViewModel {
        let model = StoryViewModel(services: services, language: language)
        model.start(photoJPEG: photo, capture: capture)
        return model
    }

    /// «Start turen» on the tour preview: shows the map at its root, where the tour panel follows the tour, and starts
    /// walking mode on the tour (`WalkingController.startTour`). A start that is refused leaves the tour on the panel
    /// with the reason under it.
    private func startTour(_ tour: RoutedTour) {
        path = []
        tab = .explore
        Task { await services.walking.startTour(tour) }
    }

    /// On top of whatever the selected tab shows; a walk story already on top is swapped for the new one.
    private func openWalkStory(_ id: UUID) {
        switch tab {
        case .explore: Self.push(.walkStory(id), onto: &path)
        case .diary: Self.push(.walkStory(id), onto: &diaryPath)
        case .tours, .camera:
            // The tours tab has no story routes (and «Kamera» is never selected); the story opens over the map.
            tab = .explore
            Self.push(.walkStory(id), onto: &path)
        }
    }

    private static func push(_ route: HomeRoute, onto stack: inout [HomeRoute]) {
        if case .walkStory = route, case .walkStory = stack.last {
            stack[stack.count - 1] = route
        } else {
            stack.append(route)
        }
    }

    /// A tap on the card (spec 5): the place's story on this run when there is one, else «Lytt» starts telling it
    /// and its screen opens at once, showing it being written.
    private func openSelectedPlace() {
        guard case .selected(let selected) = around.selection else { return }
        let placeID = selected.vector.place.candidate.id
        let stories = services.walking.stories
        let language = around.language
        if let id = stories.storyID(forPlace: placeID, language: language) {
            openWalkStory(id)
            return
        }
        around.listen()
        if let id = stories.storyID(forPlace: placeID, language: language) { openWalkStory(id) }
    }

    /// «Sist oppdaget»: a photo story opens its stored session, as History reopens it; a walk story its screen.
    private func openRecent(_ story: RecentStory) {
        switch story.source {
        case .walk(let id):
            openWalkStory(id)
        case .photo(let id):
            guard let record = photos.first(where: { $0.id == id }) else { return }
            do {
                let session = try services.memory.session(for: record)
                setPushedModel(StoryViewModel(session: session, services: services))
                path.append(.photoStory)
            } catch {
                AppServices.logMemoryFailure("open session failed", error)
                errorText = AroundTexts.openFailedMessage(screenLanguage)
            }
        }
    }

    /// Day story models live while their route is on either stack.
    private func keepDayStories() {
        services.diary.keepDayStories(Set((path + diaryPath).compactMap { route in
            if case .dayStory(let dayKey) = route { dayKey } else { nil }
        }))
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
    }

    // MARK: - What runs

    /// Whether location updates should run now (re-evaluated as the scene, the tab, the top screen or the story
    /// changes): the Utforsk tab showing the map, the camera, or a story offering "Use where I am now"; the Turer
    /// tab; and a tour being planned on any tab. Otherwise never while the Dagbok tab is selected. This screen alone
    /// starts and stops the shared provider and sets its `onFix`.
    private var locationWanted: Bool {
        guard scenePhase != .background else { return false }
        // The tours tab plans from where the owner stands, and its destination search is biased to it. A run being
        // planned keeps it on after the owner switches tab, so it still gets its position.
        if tab == .tours || services.tourBuilder.isPlanning { return true }
        return tab == .explore && (path.isEmpty || path.last == .camera || storyOffersCurrentPosition)
    }

    /// Whether the map is on screen: the Utforsk tab at its root, with the app not in the background.
    private var mapVisible: Bool {
        scenePhase != .background && tab == .explore && path.isEmpty
    }

    /// Whether the camera should run now: its screen is on top (not under a walk story), its tab is selected and the
    /// app is visible.
    private var cameraWanted: Bool {
        scenePhase != .background && tab == .explore && path.last == .camera
    }

    private var storyOffersCurrentPosition: Bool {
        if case .failed(_, canUseCurrentPosition: true) = pushedModel?.state { return true }
        return false
    }
}
