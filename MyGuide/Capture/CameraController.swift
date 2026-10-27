import AVFoundation
import ImageIO
import MyGuideCore
import Observation
import Synchronization

struct CapturedPhoto: Sendable {
    var data: Data
    /// Read from the device as the capture was issued, so it is the zoom the photo really has.
    var zoomFactor: Double
}

enum CameraError: Error, Equatable {
    case accessDenied
    case noCamera
    case configurationFailed
    case notRunning
    case noPhotoData
    /// The session reported a runtime error it did not recover from; the text is AVFoundation's description.
    case runtime(String)
}

// CAMDIAG: temporary device diagnostics for the black preview / green photo. Remove this helper and every
// `CameraDiagnostics.log` call once the cause is known.
enum CameraDiagnostics {
    nonisolated static func log(_ message: @autoclosure () -> String) {
        print("[CAMDIAG] \(message())")
    }
}

/// Owns the capture session. UI state lives on the main actor; every session call runs on `CameraSession`'s serial queue.
@MainActor
@Observable
final class CameraController {
    /// True only while the session runs and delivers frames: false while stopped, failed or interrupted.
    private(set) var isRunning = false
    private(set) var failure: CameraError?
    /// Why the running session is interrupted (for the screen), or nil when it is not.
    private(set) var interruptionReason: String?
    /// Portrait horizontal FOV of the active format at 1×, degrees. Nil until the session is configured.
    private(set) var horizontalFOV: Double?
    /// The zoom last requested; the camera applies it before any photo requested after it.
    private(set) var zoomFactor = 1.0
    /// The device's highest zoom. 1 until the session is configured, so zoom stays off until then.
    private(set) var maxZoom = 1.0

    @ObservationIgnored let camera = CameraSession()
    /// The latest request from the UI. start() and stop() interleave at their awaits; a stop() that
    /// arrives while start() is waiting must win, so start() re-checks this after each await.
    @ObservationIgnored private var wantsRunning = false
    /// The session was started and is running or interrupted (it resumes by itself when the interruption ends).
    @ObservationIgnored private var sessionStarted = false
    /// A `.mediaServicesWereReset` runtime error restarts the session once per start().
    @ObservationIgnored private var didRetryAfterReset = false

    var session: AVCaptureSession { camera.session }

    init() {
        let events = camera.events
        // The controller lives as long as AppServices; the weak capture only keeps the loop from owning it.
        Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    func start() async {
        wantsRunning = true
        didRetryAfterReset = false
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            failure = .accessDenied
            sessionStarted = false
            updateRunning()
            return
        }
        // stop() was called while waiting for permission; its queue work may already have run.
        guard wantsRunning else { return }
        await run()
    }

    func stop() async {
        wantsRunning = false
        sessionStarted = false
        interruptionReason = nil
        updateRunning()
        await camera.stop()
    }

    /// Configures if needed and starts the session, then records what the session really reports.
    private func run() async {
        let outcome = await camera.start()
        // A stop() during camera.start() is queued behind it on the serial queue, so the session ends stopped.
        guard wantsRunning else {
            sessionStarted = false
            updateRunning()
            return
        }
        switch outcome {
        case .success(let state):
            horizontalFOV = FieldOfView.portraitHorizontalFOV(landscapeFOV: state.configuration.landscapeFOV)
            maxZoom = state.configuration.maxZoom
            if state.isInterrupted {
                // The notification with the reason may still be on its way; it replaces this text.
                if interruptionReason == nil { interruptionReason = "Camera interrupted" }
            } else {
                interruptionReason = nil
            }
            sessionStarted = state.isRunning || state.isInterrupted
            // Neither running nor interrupted: startRunning failed; a runtime error notification may add the reason.
            failure = sessionStarted ? nil : .notRunning
        case .failure(let error):
            failure = error
            sessionStarted = false
        }
        updateRunning()
    }

    private func handle(_ event: CameraSession.Event) async {
        switch event {
        case .interrupted(let reason):
            CameraDiagnostics.log("interrupted: \(reason) wantsRunning=\(wantsRunning)")
            guard wantsRunning else { return }
            interruptionReason = "Camera interrupted: \(reason)"
        case .interruptionEnded:
            CameraDiagnostics.log("interruption ended wantsRunning=\(wantsRunning)")
            interruptionReason = nil
        case .runtimeError(let code, let text):
            CameraDiagnostics.log("runtime error code=\(code.map(String.init) ?? "nil") \(text) wantsRunning=\(wantsRunning) retried=\(didRetryAfterReset)")
            guard wantsRunning else { return }
            if code == AVError.Code.mediaServicesWereReset.rawValue, !didRetryAfterReset {
                didRetryAfterReset = true
                CameraDiagnostics.log("media services were reset: restarting once")
                await run()
                return
            }
            failure = .runtime(text)
            sessionStarted = false
        }
        updateRunning()
    }

    private func updateRunning() {
        isRunning = wantsRunning && sessionStarted && failure == nil && interruptionReason == nil
    }

    /// Clamps to 1...min(5, device max) and applies it on the session queue, ahead of any later capture.
    func setZoom(_ factor: Double) {
        let clamped = CameraZoom.clamped(factor, deviceMax: maxZoom)
        guard clamped != zoomFactor else { return }
        zoomFactor = clamped
        camera.setZoom(clamped)
    }

    /// The photo as JPEG file data (with EXIF), in portrait orientation, and the zoom it was taken at.
    func capture() async throws -> CapturedPhoto {
        try await camera.capture()
    }
}

/// The AVFoundation objects. Invariant: `session`, `output` and `inFlight` are touched only on `queue`,
/// except that the preview layer is handed `session` on the main thread (as Apple's AVCam does).
final class CameraSession: @unchecked Sendable {
    /// What the session reports by notification, delivered in order to the controller's main-actor loop.
    enum Event: Sendable {
        case interrupted(reason: String)
        case interruptionEnded
        /// `code` is the AVError code when the error is an AVError.
        case runtimeError(code: Int?, text: String)
    }

    /// What `start()` found on the queue right after asking the session to run.
    struct StartState: Sendable {
        var configuration: Configuration
        var isRunning: Bool
        var isInterrupted: Bool
    }

    let session = AVCaptureSession()
    let events: AsyncStream<Event>
    private let eventSink: AsyncStream<Event>.Continuation
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "io.github.birgerlie.MyGuide.camera")
    private var configuration: Configuration?
    private var device: AVCaptureDevice?
    private var inFlight: [Int64: PhotoCaptureDelegate] = [:]
    private var observers: [NSObjectProtocol] = []

    struct Configuration: Sendable {
        /// The active format's landscape horizontal FOV at 1×, degrees.
        var landscapeFOV: Double
        var maxZoom: Double
    }

    init() {
        (events, eventSink) = AsyncStream.makeStream(of: Event.self)
        let center = NotificationCenter.default
        let sink = eventSink
        // Posted on arbitrary threads; only Sendable values leave the closures, and the controller's loop runs
        // on the main actor.
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session,
                                            queue: nil) { [weak self] note in
            let raw = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
            let reason = raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            let text = reason.map(Self.describe) ?? "unknown reason (\(raw.map(String.init) ?? "none"))"
            self?.logOnQueue("wasInterrupted reason=\(raw.map(String.init) ?? "nil") \(text)")
            sink.yield(.interrupted(reason: text))
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session,
                                            queue: nil) { [weak self] _ in
            self?.logOnQueue("interruptionEnded")
            sink.yield(.interruptionEnded)
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session,
                                            queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let code = error?.domain == AVFoundationErrorDomain ? error?.code : nil
            let text = error?.localizedDescription ?? "Unknown camera error"
            self?.logOnQueue("runtimeError domain=\(error?.domain ?? "nil") code=\(error?.code ?? 0) \(error.map(String.init(describing:)) ?? "nil")")
            sink.yield(.runtimeError(code: code, text: text))
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        eventSink.finish()
    }

    static func describe(_ reason: AVCaptureSession.InterruptionReason) -> String {
        switch reason {
        case .videoDeviceNotAvailableInBackground: "video device not available in the background"
        case .audioDeviceInUseByAnotherClient: "audio device in use by another client"
        case .videoDeviceInUseByAnotherClient: "video device in use by another client"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: "video device not available with multiple foreground apps"
        case .videoDeviceNotAvailableDueToSystemPressure: "video device not available due to system pressure"
        case .sensitiveContentMitigationActivated: "sensitive content mitigation activated"
        @unknown default: "unknown reason (\(reason.rawValue))"
        }
    }

    /// Configures on first use, then starts running.
    func start() async -> Result<StartState, CameraError> {
        await withCheckedContinuation { continuation in
            queue.async {
                let result = self.configureIfNeeded().map { configuration in
                    if !self.session.isRunning { self.session.startRunning() }
                    self.logState("start")
                    return StartState(configuration: configuration, isRunning: self.session.isRunning,
                                      isInterrupted: self.session.isInterrupted)
                }
                if case .failure(let error) = result { CameraDiagnostics.log("start failed: \(error)") }
                continuation.resume(returning: result)
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.session.isRunning { self.session.stopRunning() }
                self.logState("stop")
                continuation.resume()
            }
        }
    }

    /// CAMDIAG: notifications arrive on arbitrary threads; the state is read on `queue`, as the invariant requires.
    private func logOnQueue(_ event: String) {
        queue.async { self.logState(event) }
    }

    // CAMDIAG: one line with everything that tells a dead sensor from an interrupted, suspended or busy one.
    // Runs on `queue`.
    private func logState(_ event: String) {
        let s = session
        var line = "\(event): session.isRunning=\(s.isRunning) isInterrupted=\(s.isInterrupted) preset=\(s.sessionPreset.rawValue) inputs=\(s.inputs.count) outputs=\(s.outputs.count) connections=\(s.connections.count)"
        if let device {
            let pressure = device.systemPressureState
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            line += " device=\(device.deviceType.rawValue) uniqueID=\(device.uniqueID) isConnected=\(device.isConnected) isSuspended=\(device.isSuspended) activeFormat=\(dims.width)x\(dims.height) fov=\(device.activeFormat.videoFieldOfView) zoom=\(device.videoZoomFactor) pressure=\(pressure.level.rawValue) factors=\(pressure.factors.rawValue)"
        } else {
            line += " device=nil"
        }
        if let connection = output.connection(with: .video) {
            line += " photoConnection.isEnabled=\(connection.isEnabled) isActive=\(connection.isActive)"
        } else {
            line += " photoConnection=nil"
        }
        CameraDiagnostics.log(line)
    }

    /// Queued, so a capture requested after this call is taken at this zoom. The caller has clamped it.
    func setZoom(_ factor: Double) {
        queue.async {
            guard let device = self.device else { return }
            // On failure the zoom stays put; capture() reports the zoom the device really has.
            do {
                try device.lockForConfiguration()
            } catch {
                return
            }
            device.videoZoomFactor = CGFloat(min(factor, Double(device.maxAvailableVideoZoomFactor)))
            device.unlockForConfiguration()
        }
    }

    func capture() async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.configuration != nil, self.session.isRunning else {
                    continuation.resume(throwing: CameraError.notRunning)
                    return
                }
                let settings: AVCapturePhotoSettings
                if self.output.availablePhotoCodecTypes.contains(.jpeg) {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                } else {
                    settings = AVCapturePhotoSettings()
                }
                if let connection = self.output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
                let zoom = self.device.map { Double($0.videoZoomFactor) } ?? 1
                let id = settings.uniqueID
                // The closure keeps `self` alive only until the capture finishes and the entry is removed.
                let delegate = PhotoCaptureDelegate(zoomFactor: zoom, continuation: continuation) {
                    self.queue.async { self.inFlight[id] = nil }
                }
                // AVCapturePhotoOutput does not keep the delegate alive; hold it until the capture finishes.
                self.inFlight[id] = delegate
                self.logState("capture")
                self.output.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    /// Runs on `queue`.
    private func configureIfNeeded() -> Result<Configuration, CameraError> {
        if let configuration { return .success(configuration) }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return .failure(.noCamera)
        }
        guard let input = try? AVCaptureDeviceInput(device: device) else { return .failure(.configurationFailed) }
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            return .failure(.configurationFailed)
        }
        session.addInput(input)
        session.addOutput(output)
        // The .photo preset picks the device's active format at commit; read the FOV only after it.
        session.commitConfiguration()
        let configured = Configuration(landscapeFOV: Double(device.activeFormat.videoFieldOfView),
                                       maxZoom: Double(device.maxAvailableVideoZoomFactor))
        self.device = device
        configuration = configured
        logState("configure")
        return .success(configured)
    }
}

/// One capture's delegate; resumes its continuation exactly once.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, Sendable {
    private let zoomFactor: Double
    private let continuation: Mutex<CheckedContinuation<CapturedPhoto, Error>?>
    private let onFinish: @Sendable () -> Void

    init(zoomFactor: Double, continuation: CheckedContinuation<CapturedPhoto, Error>,
         onFinish: @escaping @Sendable () -> Void) {
        self.zoomFactor = zoomFactor
        self.continuation = Mutex(continuation)
        self.onFinish = onFinish
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        // CAMDIAG: a zero-filled (green) photo still has real dimensions; the pixel sample tells them apart.
        let dims = photo.resolvedSettings.photoDimensions
        let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        CameraDiagnostics.log("photo: resolved=\(dims.width)x\(dims.height) error=\(error.map(String.init(describing:)) ?? "nil") exposure=\(exif?[kCGImagePropertyExifExposureTime as String] ?? "nil") iso=\(exif?[kCGImagePropertyExifISOSpeedRatings as String] ?? "nil") brightness=\(exif?[kCGImagePropertyExifBrightnessValue as String] ?? "nil")")
        if let error {
            resume(.failure(error))
        } else if let data = photo.fileDataRepresentation() {
            resume(.success(CapturedPhoto(data: data, zoomFactor: zoomFactor)))
        } else {
            resume(.failure(CameraError.noPhotoData))
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        // Last callback for this capture. Covers failures where no photo was ever delivered.
        resume(.failure(error ?? CameraError.noPhotoData))
        onFinish()
    }

    private func resume(_ result: Result<CapturedPhoto, Error>) {
        let pending = continuation.withLock { value -> CheckedContinuation<CapturedPhoto, Error>? in
            defer { value = nil }
            return value
        }
        pending?.resume(with: result)
    }
}
