import Foundation
import MyGuideCore
import Observation

/// State machine for one photo's story. The photo and capture are kept so Retry never loses them.
@MainActor
@Observable
final class StoryViewModel {
    enum State {
        case working(String)
        case showing
        case failed(message: String, canUseCurrentPosition: Bool)
    }

    static let workingText = "Looking around…"

    var state: State = .working(StoryViewModel.workingText)
    var session: StorySession?

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var photoJPEG: Data?
    @ObservationIgnored private var capture: CaptureContext?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
    }

    func start(photoJPEG: Data, capture: CaptureContext) {
        self.photoJPEG = photoJPEG
        self.capture = capture
        run()
    }

    /// Re-runs with the same photo and capture.
    func retry() {
        run()
    }

    /// Replaces the capture's position (clearing its heading) and runs again.
    func useCurrentPosition(_ coordinate: Coordinate, accuracy: Double?) {
        guard let capture else { return }
        self.capture = capture.withCoordinate(coordinate, accuracy: accuracy)
        run()
    }

    /// Stops in-flight work silently, e.g. when the user navigates back.
    func cancel() {
        task?.cancel()
        task = nil
    }

    private func run() {
        guard let photoJPEG, let capture else { return }
        task?.cancel()
        session = nil
        state = .working(Self.workingText)
        task = Task { [weak self, services] in
            do {
                let flow = try services.makeFlow()
                let (session, _) = try await flow.tellFirstStory(photoJPEG: photoJPEG, capture: capture,
                                                                 language: .english)
                guard !Task.isCancelled, let self else { return }
                self.session = session
                self.state = .showing
            } catch {
                // Cancellation is silence: some sources report it with their own error types, so check the task too.
                guard !Task.isCancelled, let self else { return }
                let message = UserFacingMessage.message(for: error)
                guard !message.isEmpty else { return }
                self.state = .failed(message: message,
                                     canUseCurrentPosition: (error as? PhotoStoryError) == .noPosition)
            }
        }
    }
}
