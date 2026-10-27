import MyGuideCore
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

/// Where the navigation stack can go from Home. One path for all of it, so a new photo story can replace the camera
/// in a single change and a walking notification can open its story from any screen.
enum HomeRoute: Hashable {
    case camera
    case history
    case settings
    /// The story in `HomeScreen.pushedModel`: a fresh photo story, or a stored one opened from the card.
    case photoStory
    case walkStory(UUID)
}

/// The app's first screen: the latest story (photo or walk), the walking controls and a button to the camera.
/// The camera is off until asked for, so opening the app costs no camera power.
struct HomeScreen: View {
    let services: AppServices

    @State private var path: [HomeRoute] = []
    /// Owned here for every screen that needs a position: the camera HUD and a story's "Use where I am now".
    @State private var location = LocationProvider()
    /// The photo story on the `.photoStory` route.
    @State private var pushedModel: StoryViewModel?
    /// Speaks the latest photo story from the card; separate from `pushedModel`, which is the full screen's.
    @State private var cardModel: StoryViewModel?
    @State private var cardThumbnail: UIImage?
    @State private var cardSessionLevels: [String] = []
    @State private var cardWalkStory: WalkStory?
    @State private var pickerItem: PhotosPickerItem?
    @State private var isBusy = false
    @State private var errorText: String?
    @Query(HomeScreen.latestPhoto) private var photos: [CaptureRecord]
    @Query(HomeScreen.latestWalk) private var walks: [WalkStoryRecord]
    /// Read when a library photo is picked, so a change in Settings never affects a photo already in flight.
    @AppStorage(AppServices.storyLanguageKey) private var storyLanguage: StoryLanguage = .english
    @Environment(\.scenePhase) private var scenePhase

    static let firstRunText = "Take a photo of a building or turn on walking mode to hear its story."

    private static var latestPhoto: FetchDescriptor<CaptureRecord> {
        var descriptor = FetchDescriptor<CaptureRecord>(sortBy: [SortDescriptor(\.takenAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return descriptor
    }

    private static var latestWalk: FetchDescriptor<WalkStoryRecord> {
        var descriptor = FetchDescriptor<WalkStoryRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return descriptor
    }

    private var latest: LatestStory? {
        LatestStory.newest(photo: photos.first.map { ($0.id, $0.takenAt) },
                           walk: walks.first.map { ($0.id, $0.createdAt) })
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 16) {
                    if !services.memoryIsPersistent { MemoryUnavailableNotice().clipShape(Capsule()) }
                    WalkingStatusPill(controller: services.walking)
                    if services.walking.isOn { WalkingPanel(stories: services.walking.stories) }
                    content
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) { actions }
            .navigationTitle("MyGuide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: HomeRoute.history) { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel("History")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: HomeRoute.settings) { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(for: HomeRoute.self, destination: destination)
        }
        .alert("Couldn't use the photo", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        // A tap on a walking notification, the panel's title or a myguide://walk link opens that story on top of
        // whatever is showing (initial: a cold launch from the notification sets it before this view exists).
        .onChange(of: services.walking.stories.openID, initial: true) { _, id in
            guard let id else { return }
            services.walking.stories.openID = nil
            openWalkStory(id)
        }
        .onChange(of: path) { _, path in
            // The story screen is being dropped (navigated back): stop its work silently.
            if !path.contains(.photoStory), let model = pushedModel {
                model.cancel()
                pushedModel = nil
            }
            if path.isEmpty {
                Task { await refreshCard() }
            } else {
                cardModel?.stopSpeech()
            }
        }
        // Location runs while the camera is on top, or while a story offers "Use where I am now".
        .onChange(of: locationWanted, initial: true) { _, wanted in
            if wanted { location.start() } else { location.stop() }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task { await usePicked(item) }
        }
        .task(id: latest) { await refreshCard() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch latest {
        case .photo(let id):
            if let record = photos.first(where: { $0.id == id }) {
                card(title: record.title, thumbnail: cardThumbnail, levels: cardSessionLevels,
                     playing: cardModel.map { $0.speechState(for: 0) != .idle } ?? false,
                     canPlay: cardModel != nil,
                     play: { cardModel?.toggleSpeech(level: 0) }, open: openPhotoStory)
            }
        case .walk(let id):
            if let record = walks.first(where: { $0.id == id }) {
                walkCard(record: record)
            }
        case nil:
            Text(Self.firstRunText)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.vertical, 40)
        }
    }

    private func walkCard(record: WalkStoryRecord) -> some View {
        let stories = services.walking.stories
        let id = record.id
        // The prepared copy gains levels as they arrive; the stored one covers stories no longer prepared.
        let live = stories.story(id)
        let walkStory = [live, cardWalkStory].compactMap { $0 }.max { $0.levels.count < $1.levels.count }
        let playing = stories.listening?.id == id
        return card(title: record.title, thumbnail: nil, levels: walkStory?.levels ?? [],
                    playing: playing, canPlay: playing || stories.canListen(id, level: 1),
                    play: { if playing { stories.stopListening() } else { stories.listen(id, level: 1) } },
                    open: { openWalkStory(id) })
    }

    /// The latest story: tap anywhere on the text to open it; the speaker plays the first level.
    private func card(title: String, thumbnail: UIImage?, levels: [String], playing: Bool, canPlay: Bool,
                      play: @escaping () -> Void, open: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Latest story")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Button(action: open) {
                VStack(alignment: .leading, spacing: 12) {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    Text(title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.leading)
                    if let first = levels.first {
                        Text(first)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                    }
                    Text("Show all")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the full story.")
            Button(action: play) {
                Label(playing ? "Stop" : "Play", systemImage: playing ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            .disabled(!playing && !canPlay)
            .accessibilityLabel(playing ? "Stop story" : "Play story")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    /// Camera, library and walking mode, always within reach of the thumb.
    private var actions: some View {
        HStack(spacing: 12) {
            PhotosPicker(selection: $pickerItem, matching: .images, preferredItemEncoding: .current,
                         photoLibrary: .shared()) {
                Image(systemName: "photo.on.rectangle")
                    .font(.title2)
                    .frame(width: 56, height: 56)
                    .background(.quaternary, in: Circle())
            }
            .accessibilityLabel("Pick a photo")
            .disabled(isBusy)
            Button {
                path.append(.camera)
            } label: {
                Label("Camera", systemImage: "camera.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .accessibilityLabel("Open camera")
            walkButton
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Turns walking mode on or off; accent colour while it runs.
    private var walkButton: some View {
        let isOn = services.walking.isOn
        return Button {
            if isOn {
                services.walking.stop()
            } else {
                Task { await services.walking.start() }
            }
        } label: {
            Image(systemName: isOn ? "figure.walk.motion" : "figure.walk")
                .font(.title2)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .frame(width: 56, height: 56)
                .background(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Circle())
        }
        .accessibilityLabel("Walking mode")
        .accessibilityValue(isOn ? "On" : "Off")
    }

    @ViewBuilder
    private func destination(_ route: HomeRoute) -> some View {
        switch route {
        case .camera:
            CaptureScreen(services: services, location: location, onPhoto: photoReady)
        case .history:
            HistoryView(services: services, location: location)
        case .settings:
            SettingsView(services: services)
        case .photoStory:
            if let pushedModel {
                StoryView(model: pushedModel, location: location)
            }
        case .walkStory(let id):
            WalkStoryView(stories: services.walking.stories, id: id)
                .id(id)
        }
    }

    // MARK: - Navigation

    /// A photo was taken or picked on the camera screen: its story replaces the camera, so going back lands on
    /// Home with the camera off. If the camera is no longer on top (the owner went back, or a walk story is open
    /// over it) the photo is dropped before any paid request starts, rather than hijacking the screen.
    private func photoReady(_ photo: Data, _ capture: CaptureContext, _ language: StoryLanguage) {
        guard path.last == .camera else { return }
        pushedModel = startStory(photo: photo, capture: capture, language: language)
        path = [.photoStory]
    }

    private func startStory(photo: Data, capture: CaptureContext, language: StoryLanguage) -> StoryViewModel {
        let model = StoryViewModel(services: services, language: language)
        model.start(photoJPEG: photo, capture: capture)
        return model
    }

    /// The card's story, in full on its own screen: the stored session, as History reopens it.
    private func openPhotoStory() {
        guard let record = photos.first else { return }
        do {
            let session = try services.memory.session(for: record)
            pushedModel = StoryViewModel(session: session, services: services)
            path.append(.photoStory)
        } catch {
            AppServices.logMemoryFailure("open session failed", error)
            errorText = HistoryView.corruptText
        }
    }

    /// On top of whatever is showing; a walk story already on top is swapped for the new one.
    private func openWalkStory(_ id: UUID) {
        if case .walkStory = path.last {
            path[path.count - 1] = .walkStory(id)
        } else {
            path.append(.walkStory(id))
        }
    }

    // MARK: - Actions

    private func usePicked(_ item: PhotosPickerItem) async {
        let language = storyLanguage
        isBusy = true
        defer { isBusy = false }
        switch await PhotoImport.load(item) {
        case .success(let loaded):
            pushedModel = startStory(photo: loaded.data, capture: loaded.capture, language: language)
            // The picker is shown from Home only; a story already open (rare) is replaced by the new one.
            path = [.photoStory]
        case .failure(let failure):
            errorText = failure.text
        }
    }

    /// Loads what the card shows for the latest story: a photo story's session and thumbnail, or a walk story's
    /// stored copy. Runs when the latest story changes and each time Home comes back to the top.
    private func refreshCard() async {
        cardModel?.stopSpeech()
        cardModel = nil
        cardThumbnail = nil
        cardSessionLevels = []
        cardWalkStory = nil
        switch latest {
        case .photo(let id):
            guard let record = photos.first(where: { $0.id == id }) else { return }
            cardThumbnail = UIImage(data: record.thumbnailJPEG)
            do {
                let session = try services.memory.session(for: record)
                cardSessionLevels = session.levels
                cardModel = StoryViewModel(session: session, services: services)
            } catch {
                AppServices.logMemoryFailure("home card load failed", error)
            }
        case .walk(let id):
            cardWalkStory = services.walking.stories.storedStory(id)
        case nil:
            break
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
    }

    /// Whether location updates should run now (re-evaluated as the scene, the top screen or the story changes).
    private var locationWanted: Bool {
        scenePhase != .background && (path.last == .camera || storyOffersCurrentPosition)
    }

    private var storyOffersCurrentPosition: Bool {
        if case .failed(_, canUseCurrentPosition: true) = pushedModel?.state { return true }
        return false
    }
}
