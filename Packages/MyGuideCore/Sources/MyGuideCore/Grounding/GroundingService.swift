import Foundation
import Synchronization

public enum GroundingError: Error, Equatable {
    case noPosition
}

/// Gathers nearby places (OpenStreetMap, Wikipedia) and a street address for a capture.
/// A failing source is recorded in `failedSources`; only cancellation propagates.
/// The geocoder and OpenStreetMap are bounded by timeouts; running out of time counts as that source's failure.
public struct GroundingService: Sendable {
    static let osmRadius = 250
    static let wikiRadius = 400

    private let overpass: OverpassClient
    private let wikipedia: WikipediaClient
    private let geocoder: ReverseGeocoding
    public static let defaultGeocoderTimeout: Duration = .seconds(8)
    private let geocoderTimeout: Duration
    /// Bounds the whole OpenStreetMap call, both Overpass endpoints included (each may take 12 s), so a photo never
    /// waits for a failing server and its fallback (spec 13.6): it goes on with Wikipedia and the address.
    public static let defaultOSMTimeout: Duration = .seconds(15)
    private let osmTimeout: Duration

    public init(overpass: OverpassClient, wikipedia: WikipediaClient, geocoder: ReverseGeocoding,
                geocoderTimeout: Duration = Self.defaultGeocoderTimeout, osmTimeout: Duration = Self.defaultOSMTimeout) {
        self.overpass = overpass
        self.wikipedia = wikipedia
        self.geocoder = geocoder
        self.geocoderTimeout = geocoderTimeout
        self.osmTimeout = osmTimeout
    }

    public func ground(_ capture: CaptureContext, language: StoryLanguage) async throws -> Grounding {
        guard let here = capture.coordinate else { throw GroundingError.noPosition }
        return try await ground(capture, language: language, address: { try await self.address(for: here) })
    }

    /// The street address from the geocoder, bounded by the geocoder timeout; nil when it fails or runs out of time.
    /// Only cancellation propagates.
    public func address(for here: Coordinate) async throws -> Address? {
        let geocoder = self.geocoder
        let timeout = geocoderTimeout
        return try await Self.attempt { try await Self.withTimeout(timeout) { try await geocoder.address(for: here) } }
    }

    /// As `ground`, with the address from `address` (nil meaning the geocoder failed), so a lookup that is already
    /// under way can be shared with the caller. `address` may throw only cancellation.
    func ground(_ capture: CaptureContext, language: StoryLanguage,
                address: @escaping @Sendable () async throws -> Address?) async throws -> Grounding {
        guard let here = capture.coordinate else { throw GroundingError.noPosition }

        let overpass = self.overpass, osmTimeout = self.osmTimeout
        async let osm = Self.attempt {
            try await Self.withTimeout(osmTimeout) {
                try await overpass.places(around: here, radius: Self.osmRadius, language: language)
            }
        }
        async let wiki = Self.attempt { try await wikipedia.articles(around: here, radius: Self.wikiRadius, language: language) }
        async let geo = address()
        let (osmResult, wikiResult, geoResult) = try await (osm, wiki, geo)
        // Some sources signal cancellation with their own error type (CLError, MKError); do not report that as a failure.
        try Task.checkCancellation()

        var failed: [GroundingSource] = []
        if osmResult == nil { failed.append(.openStreetMap) }
        if wikiResult == nil { failed.append(.wikipedia) }
        if geoResult == nil { failed.append(.geocoder) }

        let merged = CandidateRanker.merge(osm: osmResult ?? [], wiki: wikiResult ?? [])
        return Grounding(candidates: CandidateRanker.rank(merged, capture: capture),
                         address: geoResult, failedSources: failed)
    }

    /// Thrown by `withTimeout` when the sleep wins.
    struct Timeout: Error {}

    /// Races `work` against a sleep of `timeout`; the loser is cancelled. Throws `Timeout` if the sleep wins.
    /// `work` runs abandonable, so a source that ignores cancellation (MapKit's request) cannot hold the race open.
    static func withTimeout<T: Sendable>(_ timeout: Duration,
                                         _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await abandoningOnCancel(work) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Timeout()
            }
            defer { group.cancelAll() }
            // Both children always finish (with a value or an error), so next() never returns nil here.
            guard let first = try await group.next() else { throw Timeout() }
            return first
        }
    }

    /// Runs `work` in its own task and waits for it, but stops waiting with CancellationError as soon as the
    /// caller is cancelled, even if `work` ignores cancellation. The abandoned task is cancelled and left to end on its own.
    static func abandoningOnCancel<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let once = ResumeOnce<T>()
        let task = Task {
            do { once.resume(with: .success(try await work())) } catch { once.resume(with: .failure(error)) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { once.attach($0) }
        } onCancel: {
            task.cancel()
            once.resume(with: .failure(CancellationError()))
        }
    }

    /// nil on any failure except cancellation, which propagates.
    private static func attempt<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T? {
        do {
            return try await work()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }
}

/// Resumes one continuation exactly once with the first result offered, whether that result arrives
/// before or after the continuation is attached. Later results are dropped.
private final class ResumeOnce<T: Sendable>: Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<T, Error>)
        case early(Result<T, Error>)
        case done
    }
    private let state = Mutex<State>(.idle)

    func attach(_ continuation: CheckedContinuation<T, Error>) {
        let early: Result<T, Error>? = state.withLock { state in
            switch state {
            case .idle:
                state = .waiting(continuation)
                return nil
            case .early(let result):
                state = .done
                return result
            case .waiting, .done:
                preconditionFailure("ResumeOnce attached twice")
            }
        }
        if let early { continuation.resume(with: early) }
    }

    func resume(with result: Result<T, Error>) {
        let waiting: CheckedContinuation<T, Error>? = state.withLock { state in
            switch state {
            case .idle:
                state = .early(result)
                return nil
            case .waiting(let continuation):
                state = .done
                return continuation
            case .early, .done:
                return nil
            }
        }
        waiting?.resume(with: result)
    }
}
