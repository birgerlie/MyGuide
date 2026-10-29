import MyGuideCore
import PhotosUI
import SwiftUI

/// "Hva ser du på?": the camera preview under the design package's overlay (heading, focus corners, shutter, library
/// picker and the coral "Finn stedet" button), with a one-line HUD showing what position and heading will be sent. The
/// new texts follow the story language (spec 5). Pushed from
/// Home, which starts the shared camera while this screen is on top and stops it otherwise; this screen only shows
/// and drives it. A finished photo (taken or picked) is handed to Home through `onPhoto`; Home starts the story and
/// replaces this screen with it.
struct CaptureScreen: View {
    /// `services.camera` is the one camera; never a per-screen one (SwiftUI may build this screen more than once).
    let services: AppServices
    /// Home owns the location provider: it runs while this screen is on top or a story offers "Use where I am now".
    let location: LocationProvider
    let onPhoto: (_ photo: Data, _ capture: CaptureContext, _ language: StoryLanguage) -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var isBusy = false
    @State private var errorText: String?
    /// The zoom when the current pinch began; nil between pinches. GestureState also resets on a cancelled pinch.
    @GestureState private var pinchBase: Double?
    /// Read when the photo is taken or picked, so a change in Settings never affects a photo already in flight.
    @AppStorage(AppServices.storyLanguageKey) private var storyLanguage: StoryLanguage = .english

    private var camera: CameraController { services.camera }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.failure == nil {
                CameraPreview(session: camera.session, isRunning: camera.isRunning)
                    .ignoresSafeArea()
                // The preview stays (and resumes by itself when the interruption ends); the reason shows over it.
                if let reason = camera.interruptionReason {
                    Text(reason)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            } else {
                Text(Self.cameraMessage(camera.failure))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding()
            }
            legibilityGradient
            VStack(spacing: Theme.Spacing.margin) {
                hud
                FocusCorners()
                    .stroke(Theme.Colour.ivory.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .padding(.horizontal, Theme.Spacing.wideMargin)
                    .padding(.vertical, Theme.Spacing.unit)
                    .frame(maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                Text(ScreenText.lookingAt(storyLanguage))
                    .font(Theme.Font.display)
                    .foregroundStyle(Theme.Colour.ivory)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    .accessibilityAddTraits(.isHeader)
                controls
            }
            .padding(.horizontal, Theme.Spacing.wideMargin)
            .padding(.vertical, Theme.Spacing.margin)
        }
        // Over the whole screen: the overlay's transparent areas pass touches through, its buttons keep their taps.
        .simultaneousGesture(pinchToZoom, including: camera.isRunning ? .all : .subviews)
        .alert("Couldn't use the photo", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
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

    /// A soft dark wash behind the HUD at the top and the heading and controls at the bottom, so ivory text stays
    /// legible over a bright scene. It takes no touches.
    private var legibilityGradient: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 140)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 420)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// One quiet caption line: what position and heading the photo will carry.
    private var hud: some View {
        // Re-evaluated every second so a fix that goes stale shows as "No GPS fix".
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(CaptureHUD.text(fix: LocationProvider.usableFix(location.location, now: context.date),
                                 compass: location.compass))
                .font(Theme.Font.caption.monospacedDigit())
                .foregroundStyle(Theme.Colour.ivory.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var controls: some View {
        VStack(spacing: Theme.Spacing.margin) {
            if camera.isRunning { zoomButton }
            controlRow
            // Takes the photo, same as the shutter. Coral with forest-green text (never light text on coral).
            Button(action: shutter) {
                HStack(spacing: Theme.Spacing.unit) {
                    Text(ScreenText.findPlace(storyLanguage))
                    Image(systemName: "arrow.right")
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.themePrimary(.coral))
            .disabled(!camera.isRunning || isBusy)
        }
    }

    private var controlRow: some View {
        HStack {
            // .current keeps the original bytes (and their GPS EXIF) instead of a transcoded copy.
            PhotosPicker(selection: $pickerItem, matching: .images, preferredItemEncoding: .current,
                         photoLibrary: .shared()) {
                Image(systemName: "photo.on.rectangle")
                    .font(.title2)
                    .foregroundStyle(Theme.Colour.ivory)
                    .frame(width: 56, height: 56)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .accessibilityLabel("Pick a photo")
            .disabled(isBusy)
            Spacer()
            Button(action: shutter) {
                Circle()
                    .strokeBorder(Theme.Colour.ivory, lineWidth: 4)
                    .background(Circle().fill(Theme.Colour.ivory.opacity(isBusy ? 0.3 : 0.85)).padding(6))
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
        case .runtime(let text): "The camera stopped: \(text) Pick a photo from your library."
        default: "The camera couldn't start. Pick a photo from your library."
        }
    }
}

/// The four corner brackets of the design package's viewfinder, inset in the given rect.
private struct FocusCorners: Shape {
    /// Length of each bracket arm, at most a quarter of the shorter side.
    var arm: CGFloat = 36
    var corner: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        let arm = min(arm, min(rect.width, rect.height) / 4)
        let r = min(corner, arm / 2)
        var path = Path()
        // Top left.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))
        // Top right.
        path.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + arm))
        // Bottom right.
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
        // Bottom left.
        path.move(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - arm))
        return path
    }
}
