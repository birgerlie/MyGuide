import AVFoundation
import MyGuideCore
import Observation
import Synchronization

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
    /// Portrait horizontal FOV of the active format, degrees. Nil until the session is configured.
    private(set) var horizontalFOV: Double?

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
        case .success(let landscapeFOV):
            failure = nil
            horizontalFOV = FieldOfView.portraitHorizontalFOV(landscapeFOV: landscapeFOV)
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

    /// The photo as JPEG file data (with EXIF), in portrait orientation.
    func capture() async throws -> Data {
        try await camera.capture()
    }
}

/// The AVFoundation objects. Invariant: `session`, `output` and `inFlight` are touched only on `queue`,
/// except that the preview layer is handed `session` on the main thread (as Apple's AVCam does).
final class CameraSession: @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "io.github.birgerlie.MyGuide.camera")
    private var configuredFOV: Double?
    private var inFlight: [Int64: PhotoCaptureDelegate] = [:]

    /// Configures on first use, then starts running. Succeeds with the active format's landscape horizontal FOV.
    func start() async -> Result<Double, CameraError> {
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

    func capture() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.configuredFOV != nil, self.session.isRunning else {
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
                let id = settings.uniqueID
                // The closure keeps `self` alive only until the capture finishes and the entry is removed.
                let delegate = PhotoCaptureDelegate(continuation: continuation) {
                    self.queue.async { self.inFlight[id] = nil }
                }
                // AVCapturePhotoOutput does not keep the delegate alive; hold it until the capture finishes.
                self.inFlight[id] = delegate
                self.output.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    /// Runs on `queue`.
    private func configureIfNeeded() -> Result<Double, CameraError> {
        if let configuredFOV { return .success(configuredFOV) }
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
        let fov = Double(device.activeFormat.videoFieldOfView)
        configuredFOV = fov
        return .success(fov)
    }
}

/// One capture's delegate; resumes its continuation exactly once.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, Sendable {
    private let continuation: Mutex<CheckedContinuation<Data, Error>?>
    private let onFinish: @Sendable () -> Void

    init(continuation: CheckedContinuation<Data, Error>, onFinish: @escaping @Sendable () -> Void) {
        self.continuation = Mutex(continuation)
        self.onFinish = onFinish
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            resume(.failure(error))
        } else if let data = photo.fileDataRepresentation() {
            resume(.success(data))
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

    private func resume(_ result: Result<Data, Error>) {
        let pending = continuation.withLock { value -> CheckedContinuation<Data, Error>? in
            defer { value = nil }
            return value
        }
        pending?.resume(with: result)
    }
}
