import CoreLocation
import MyGuideCore
import Photos
import PhotosUI
import SwiftUI

/// Camera preview, shutter, library picker, Settings and a HUD showing what position and heading will be sent.
struct CaptureScreen: View {
    let services: AppServices

    @State private var camera = CameraController()
    @State private var location = LocationProvider()
    @State private var pickerItem: PhotosPickerItem?
    @State private var story: StoryViewModel?
    @State private var isBusy = false
    @State private var errorText: String?
    /// True while this screen (not History, Settings or a story pushed on top of it) is visible.
    @State private var isOnTop = false
    /// The zoom when the current pinch began; nil between pinches. GestureState also resets on a cancelled pinch.
    @GestureState private var pinchBase: Double?
    /// Read when the photo is taken or picked, so a change in Settings never affects a photo already in flight.
    @AppStorage(AppServices.storyLanguageKey) private var storyLanguage: StoryLanguage = .english
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.failure == nil {
                CameraPreview(session: camera.session, isRunning: camera.isRunning)
                    .ignoresSafeArea()
            } else {
                Text(Self.cameraMessage(camera.failure))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding()
            }
            VStack {
                if !services.memoryIsPersistent { MemoryUnavailableNotice().clipShape(Capsule()) }
                hud
                WalkingStatusPill(controller: services.walking)
                Spacer()
                controls
            }
            .padding()
        }
        // Over the whole screen: the overlay's transparent areas pass touches through, its buttons keep their taps.
        .simultaneousGesture(pinchToZoom, including: camera.isRunning ? .all : .subviews)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    HistoryView(services: services, location: location)
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel("History")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView(services: services)
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .navigationDestination(isPresented: storyPresented) {
            if let story {
                StoryView(model: story, location: location)
            }
        }
        .alert("Couldn't use the photo", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .onAppear {
            isOnTop = true
            Task { await camera.start() }
        }
        .onDisappear {
            isOnTop = false
            Task { await camera.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Picks up camera access granted in the Settings app while we were away,
            // but never restarts the camera behind History, Settings or a story.
            if phase == .active, isOnTop, story == nil { Task { await camera.start() } }
        }
        // Location runs while this screen is on top, or while a story offers "Use where I am now".
        .onChange(of: locationWanted, initial: true) { _, wanted in
            if wanted { location.start() } else { location.stop() }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task { await usePicked(item) }
        }
    }

    /// Whether location updates should run now (re-evaluated as the scene, the top screen or the story changes).
    private var locationWanted: Bool {
        scenePhase != .background && (isOnTop || storyOffersCurrentPosition)
    }

    private var storyOffersCurrentPosition: Bool {
        if case .failed(_, canUseCurrentPosition: true) = story?.state { return true }
        return false
    }

    // MARK: - Subviews

    private var pinchToZoom: some Gesture {
        MagnifyGesture()
            .updating($pinchBase) { value, base, _ in
                let start = base ?? camera.zoomFactor
                base = start
                camera.setZoom(CameraZoom.pinched(base: start, magnification: Double(value.magnification),
                                                  deviceMax: camera.maxZoom))
            }
    }

    /// Shows the zoom; a tap goes back to 1×. VoiceOver users swipe up or down to zoom in 0.5× steps.
    private var zoomButton: some View {
        Button {
            camera.setZoom(1)
        } label: {
            Text(CameraZoom.label(camera.zoomFactor))
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(camera.zoomFactor > 1 ? .yellow : .white)
                .frame(minWidth: 44, minHeight: 32)
                .background(.black.opacity(0.55), in: Capsule())
        }
        .accessibilityLabel("Zoom")
        .accessibilityValue(CameraZoom.label(camera.zoomFactor))
        .accessibilityHint("Double-tap to go back to 1×.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: camera.setZoom(camera.zoomFactor + 0.5)
            case .decrement: camera.setZoom(camera.zoomFactor - 0.5)
            @unknown default: break
            }
        }
    }

    private var hud: some View {
        // Re-evaluated every second so a fix that goes stale shows as "No GPS fix".
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(CaptureHUD.text(fix: LocationProvider.usableFix(location.location, now: context.date),
                                 compass: location.compass))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
        }
    }

    private var controls: some View {
        VStack(spacing: 16) {
            if camera.isRunning { zoomButton }
            controlRow
        }
    }

    private var controlRow: some View {
        HStack {
            // .current keeps the original bytes (and their GPS EXIF) instead of a transcoded copy.
            PhotosPicker(selection: $pickerItem, matching: .images, preferredItemEncoding: .current,
                         photoLibrary: .shared()) {
                Image(systemName: "photo.on.rectangle")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .accessibilityLabel("Pick a photo")
            .disabled(isBusy)
            Spacer()
            Button(action: shutter) {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .background(Circle().fill(.white.opacity(isBusy ? 0.3 : 0.85)).padding(6))
                    .frame(width: 76, height: 76)
            }
            .accessibilityLabel("Take photo")
            .disabled(!camera.isRunning || isBusy)
            Spacer()
            walkButton
        }
    }

    /// Turns walking mode on or off; yellow while it runs.
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
                .foregroundStyle(isOn ? .yellow : .white)
                .frame(width: 56, height: 56)
                .background(.black.opacity(0.4), in: Circle())
        }
        .accessibilityLabel("Walking mode")
        .accessibilityValue(isOn ? "On" : "Off")
    }

    private var storyPresented: Binding<Bool> {
        Binding(get: { story != nil }, set: { presented in
            guard !presented else { return }
            // The story screen is being dropped (navigated back): stop its work silently.
            story?.cancel()
            story = nil
        })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
    }

    // MARK: - Actions

    private func shutter() {
        guard !isBusy else { return }
        // Snapshot position and heading at the press, before awaiting the photo.
        let fix = location.fix()
        let compass = location.compass
        let takenAt = Date.now
        let language = storyLanguage
        let fov = camera.horizontalFOV ?? FieldOfView.portraitHorizontalFOV(landscapeFOV: FieldOfView.landscapeFOV)
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let photo = try await camera.capture()
                let capture = Self.cameraContext(fix: fix, compass: compass,
                                                 horizontalFOV: FieldOfView.zoomedHorizontalFOV(fov, zoomFactor: photo.zoomFactor),
                                                 takenAt: takenAt)
                openStory(photo: photo.data, capture: capture, language: language)
            } catch {
                errorText = "The camera couldn't take the photo. Try again."
            }
        }
    }

    private func usePicked(_ item: PhotosPickerItem) async {
        let language = storyLanguage
        isBusy = true
        defer { isBusy = false }
        let data: Data?
        do {
            data = try await item.loadTransferable(type: Data.self)
        } catch {
            errorText = "Couldn't load the photo from your library."
            return
        }
        guard let data, let metadata = PhotoMetadata.read(from: data) else {
            errorText = UserFacingMessage.message(for: ImageProcessingError.unreadableImage)
            return
        }
        var capture = metadata.captureContext(fallbackDate: .now)
        if capture.coordinate == nil, let identifier = item.itemIdentifier,
           let assetLocation = await Self.assetLocation(identifier),
           let fix = Self.assetFix(assetLocation) {
            // Position only; the EXIF heading (if any) still describes this photo, PHAsset adds none.
            capture.coordinate = fix.coordinate
            capture.horizontalAccuracy = fix.accuracy
        }
        openStory(photo: data, capture: capture, language: language)
    }

    private func openStory(photo: Data, capture: CaptureContext, language: StoryLanguage) {
        let model = StoryViewModel(services: services, language: language)
        model.start(photoJPEG: photo, capture: capture)
        story = model
    }

    // MARK: - Helpers

    /// The library asset's location, after asking for read access. Nil if access is refused or there is none.
    private static func assetLocation(_ identifier: String) async -> CLLocation? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject?.location
    }

    /// A library location has no age limit (the photo may be old), but sentinel values still mean "no position".
    private static func assetFix(_ location: CLLocation) -> (coordinate: Coordinate, accuracy: Double?)? {
        guard CLLocationCoordinate2DIsValid(location.coordinate),
              !(location.coordinate.latitude == 0 && location.coordinate.longitude == 0) else { return nil }
        let accuracy = location.horizontalAccuracy
        return (Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
                accuracy >= 0 && accuracy.isFinite ? accuracy : nil)
    }

    static func cameraContext(fix: LocationFix?, compass: CompassReading?, horizontalFOV: Double,
                              takenAt: Date) -> CaptureContext {
        CaptureContext(coordinate: fix?.coordinate, horizontalAccuracy: fix?.accuracy,
                       heading: compass?.heading, headingAccuracy: compass?.accuracy,
                       horizontalFOV: horizontalFOV, takenAt: takenAt, source: .camera)
    }

    private static func cameraMessage(_ failure: CameraError?) -> String {
        switch failure {
        case .accessDenied: "Camera access is off. Allow it in the Settings app, or pick a photo from your library."
        case .noCamera: "No back camera found. Pick a photo from your library."
        default: "The camera couldn't start. Pick a photo from your library."
        }
    }
}
