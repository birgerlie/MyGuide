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
    static let unexpectedCancellationText = "Something went wrong. Try again."

    var state: State = .working(StoryViewModel.workingText)
    var session: StorySession?

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var photoJPEG: Data?
    @ObservationIgnored private var capture: CaptureContext?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
    }

    // Backstop: work for a dropped screen must not keep running (the owner normally calls cancel()).
    isolated deinit {
        task?.cancel()
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

    /// Stops in-flight work silently; called when the story screen is dropped (navigated back).
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
                // Our own cancel (or a superseding run) is silence, whatever error type the sources report it with.
                guard !Task.isCancelled, let self else { return }
                let message = UserFacingMessage.message(for: error)
                // A CancellationError we did not ask for must not leave the spinner up with no way out.
                self.state = .failed(message: message.isEmpty ? Self.unexpectedCancellationText : message,
                                     canUseCurrentPosition: (error as? PhotoStoryError) == .noPosition)
            }
        }
    }
}
