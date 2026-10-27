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

    /// Progress of the "Tell me more" request; the earlier levels stay visible in every case.
    enum MoreState: Equatable {
        case idle
        case working
        case failed(message: String)
    }

    static let workingText = "Looking around…"
    static let unexpectedCancellationText = "Something went wrong. Try again."

    var state: State = .working(StoryViewModel.workingText)
    var session: StorySession?
    var moreState: MoreState = .idle

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

    /// Asks for the next level. Ignored while a request is already running or when no level is left.
    /// Uses the same `task` as the first story, so `cancel()` and a dropped screen stop it too.
    func tellMore() {
        guard let current = session, current.nextLevel != nil, moreState != .working else { return }
        moreState = .working
        task?.cancel()
        task = Task { [weak self, services] in
            do {
                let flow = try services.makeFlow()
                let (next, _) = try await flow.continueStory(current)
                guard !Task.isCancelled, let self else { return }
                self.session = next
                self.moreState = .idle
            } catch {
                // Our own cancel is silence, whatever error type the sources report it with.
                guard !Task.isCancelled, let self else { return }
                let message = UserFacingMessage.message(for: error)
                self.moreState = .failed(message: message.isEmpty ? Self.unexpectedCancellationText : message)
            }
        }
    }

    /// Stops in-flight work silently; called when the story screen is dropped (navigated back).
    func cancel() {
        task?.cancel()
        task = nil
        if moreState == .working { moreState = .idle }
    }

    private func run() {
        guard let photoJPEG, let capture else { return }
        task?.cancel()
        session = nil
        moreState = .idle
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
