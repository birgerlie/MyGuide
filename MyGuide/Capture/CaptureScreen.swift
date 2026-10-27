import MyGuideCore
import PhotosUI
import SwiftUI

/// Camera preview, shutter, library picker and a HUD showing what position and heading will be sent. Pushed from
/// Home; the camera runs only while this screen is on top. A finished photo (taken or picked) is handed to Home
/// through `onPhoto`; Home starts the story and replaces this screen with it.
struct CaptureScreen: View {
    let services: AppServices
    /// Home owns the location provider: it runs while this screen is on top or a story offers "Use where I am now".
    let location: LocationProvider
    let onPhoto: (_ photo: Data, _ capture: CaptureContext, _ language: StoryLanguage) -> Void

    @State private var camera = CameraController()
    @State private var pickerItem: PhotosPickerItem?
    @State private var isBusy = false
    @State private var errorText: String?
    /// True while this screen (not a walk story pushed on top of it) is visible.
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
                hud
                Spacer()
                controls
            }
            .padding()
        }
        // Over the whole screen: the overlay's transparent areas pass touches through, its buttons keep their taps.
        .simultaneousGesture(pinchToZoom, including: camera.isRunning ? .all : .subviews)
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
            // but never restarts the camera behind another screen.
            if phase == .active, isOnTop { Task { await camera.start() } }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task { await usePicked(item) }
        }
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
            // Balances the picker so the shutter stays centred.
            Color.clear.frame(width: 56, height: 56)
        }
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
                onPhoto(photo.data, capture, language)
            } catch {
                errorText = "The camera couldn't take the photo. Try again."
            }
        }
    }

    private func usePicked(_ item: PhotosPickerItem) async {
        let language = storyLanguage
        isBusy = true
        defer { isBusy = false }
        switch await PhotoImport.load(item) {
        case .success(let loaded): onPhoto(loaded.data, loaded.capture, language)
        case .failure(let failure): errorText = failure.text
        }
    }

    // MARK: - Helpers

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
