import AVFoundation
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
}

/// Owns the capture session. UI state lives on the main actor; every session call runs on `CameraSession`'s serial queue.
@MainActor
@Observable
final class CameraController {
    private(set) var isRunning = false
    private(set) var failure: CameraError?
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

    var session: AVCaptureSession { camera.session }

    func start() async {
        wantsRunning = true
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            failure = .accessDenied
            isRunning = false
            return
        }
        // stop() was called while waiting for permission; its queue work may already have run.
        guard wantsRunning else { return }
        let outcome = await camera.start()
        // A stop() during camera.start() is queued behind it on the serial queue, so the session ends stopped.
        guard wantsRunning else {
            isRunning = false
            return
        }
        switch outcome {
        case .success(let configuration):
            failure = nil
            horizontalFOV = FieldOfView.portraitHorizontalFOV(landscapeFOV: configuration.landscapeFOV)
            maxZoom = configuration.maxZoom
            isRunning = true
        case .failure(let error):
            failure = error
            isRunning = false
        }
    }

    func stop() async {
        wantsRunning = false
        isRunning = false
        await camera.stop()
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
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "io.github.birgerlie.MyGuide.camera")
    private var configuration: Configuration?
    private var device: AVCaptureDevice?
    private var inFlight: [Int64: PhotoCaptureDelegate] = [:]

    struct Configuration: Sendable {
        /// The active format's landscape horizontal FOV at 1×, degrees.
        var landscapeFOV: Double
        var maxZoom: Double
    }

    /// Configures on first use, then starts running.
    func start() async -> Result<Configuration, CameraError> {
        await withCheckedContinuation { continuation in
            queue.async {
                let result = self.configureIfNeeded()
                if case .success = result, !self.session.isRunning {
                    self.session.startRunning()
                }
                continuation.resume(returning: result)
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.session.isRunning { self.session.stopRunning() }
                continuation.resume()
            }
        }
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
