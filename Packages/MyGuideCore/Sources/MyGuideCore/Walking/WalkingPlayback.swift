import Foundation

/// Which walking story is preparing, ready or playing, and what to do when the listener taps, asks for more or skips
/// (design 7.5). Pure state: the app feeds events in and carries out the returned effects.
public struct WalkingPlayback: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case buzzSent(UUID), storyReady(UUID), storyFailed(UUID), moreReady(UUID, level: Int), moreFailed(UUID)
        case tellMe(UUID), more(UUID), skip(UUID), finished(UUID, level: Int), stoppedExternally
    }

    public enum Effect: Sendable, Equatable {
        case play(UUID, level: Int), stopAudio, fetchMore(UUID), offerMore(UUID), retire(UUID), reportFailure(UUID)
    }

    private enum Phase: Sendable, Equatable {
        /// `wanted`: the listener already tapped "tell me" and is waiting.
        case preparing(wanted: Bool)
        /// Story available (first level, or a level already told) and nothing is being fetched.
        case ready
        case failed
        case fetching
        case skipped
    }

    private var phases: [UUID: Phase] = [:]
    /// The highest level played or being played for each story; drives the three-level limit.
    private var levels: [UUID: Int] = [:]
    public private(set) var playing: (id: UUID, level: Int)?

    public init() {}

    public static func == (a: WalkingPlayback, b: WalkingPlayback) -> Bool {
        a.phases == b.phases && a.levels == b.levels && a.playing?.id == b.playing?.id && a.playing?.level == b.playing?.level
    }

    /// Preparing any story, fetching more, or playing.
    public var isBusy: Bool {
        if playing != nil { return true }
        return phases.values.contains { phase in
            switch phase {
            case .preparing, .fetching: true
            case .ready, .failed, .skipped: false
            }
        }
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .buzzSent(let id):
            phases[id] = .preparing(wanted: false)
            return []

        case .storyReady(let id):
            guard case .preparing(let wanted) = phases[id] else { return [] }
            phases[id] = .ready
            return wanted ? start(id, level: 1) : []

        case .storyFailed(let id):
            guard case .preparing(let wanted) = phases[id] else { return [] }
            phases[id] = .failed
            return wanted ? [.reportFailure(id)] : []

        case .tellMe(let id):
            switch phases[id] {
            case .preparing:
                phases[id] = .preparing(wanted: true)
                return []
            case .ready:
                // Already playing this story: the tap changes nothing.
                if playing?.id == id { return [] }
                return start(id, level: 1)
            case .failed, .fetching, .skipped, nil:
                // Unknown: the app was relaunched and the prepared story is gone; the app re-prepares from memory.
                return [.reportFailure(id)]
            }

        case .more(let id):
            guard phases[id] == .ready, let level = levels[id], level < StoryLevel.allCases.count else { return [] }
            phases[id] = .fetching
            return [.fetchMore(id)]

        case .moreReady(let id, let level):
            guard phases[id] == .fetching else { return [] }
            phases[id] = .ready
            return start(id, level: level)

        case .moreFailed(let id):
            guard phases[id] == .fetching else { return [] }
            phases[id] = .ready
            return [.reportFailure(id)]

        case .skip(let id):
            var effects: [Effect] = []
            if playing?.id == id {
                playing = nil
                effects.append(.stopAudio)
            }
            // A story still being prepared or fetched is remembered so its late result is ignored.
            phases[id] = .skipped
            levels[id] = nil
            effects.append(.retire(id))
            return effects

        case .finished(let id, let level):
            // A stale finish (the story was interrupted or skipped) changes nothing.
            guard playing?.id == id else { return [] }
            playing = nil
            return level < StoryLevel.allCases.count ? [.offerMore(id)] : []

        case .stoppedExternally:
            playing = nil
            return []
        }
    }

    private mutating func start(_ id: UUID, level: Int) -> [Effect] {
        var effects: [Effect] = []
        if let current = playing, current.id != id { effects.append(.stopAudio) }
        playing = (id, level)
        levels[id] = level
        effects.append(.play(id, level: level))
        return effects
    }
}
