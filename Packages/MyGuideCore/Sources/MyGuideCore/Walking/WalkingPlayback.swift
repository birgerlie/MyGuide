import Foundation

/// Which walking story is preparing, ready or playing, and what to do when the listener taps, asks for more or skips
/// (design 7.5). Pure state: the app feeds events in and carries out the returned effects.
public struct WalkingPlayback: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case buzzSent(UUID), storyReady(UUID), storyFailed(UUID), moreReady(UUID, level: Int)
        /// `storedLevels`: the levels whose text exists now (the new level's text may be saved although its speech
        /// failed); 0 when unknown. The stored count never decreases.
        case moreFailed(UUID, storedLevels: Int = 0)
        case tellMe(UUID), more(UUID), skip(UUID), finished(UUID, level: Int), stoppedExternally
        /// The listener picked one level of a story that has its text (the in-app story screen).
        case listen(UUID, level: Int)
        /// A story the machine does not know (relaunch, or forgotten) was found in memory with `storedLevels`
        /// levels, `deepestHeard` of them heard (0 for none). It becomes ready with that level cap.
        case restored(UUID, storedLevels: Int, deepestHeard: Int)
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
        /// Fetching the text and speech of `level`.
        case fetching(level: Int)
    }

    /// Stories remembered at most; older idle ones are forgotten (a forgotten id behaves as unknown).
    static let memoryLimit = 20

    private var phases: [UUID: Phase] = [:]
    /// The highest level played or being played for each story; drives the three-level limit.
    private var levels: [UUID: Int] = [:]
    /// The number of levels whose text exists for each story (told or not).
    private var stored: [UUID: Int] = [:]
    /// Ids from least to most recently touched; bounds `phases`, `levels` and `stored`.
    private var recency: [UUID] = []
    public private(set) var playing: (id: UUID, level: Int)?

    public init() {}

    public static func == (a: WalkingPlayback, b: WalkingPlayback) -> Bool {
        a.phases == b.phases && a.levels == b.levels && a.stored == b.stored && a.playing?.id == b.playing?.id && a.playing?.level == b.playing?.level
    }

    /// Preparing any story, fetching more, or playing.
    public var isBusy: Bool {
        if playing != nil { return true }
        return phases.values.contains { phase in
            switch phase {
            case .preparing, .fetching: true
            case .ready, .failed: false
            }
        }
    }

    /// True while the story is preparing, ready or fetching more: "tell me" can be answered without memory.
    /// False for a failed, skipped, forgotten or never-seen id.
    public func hasStory(_ id: UUID) -> Bool {
        switch phases[id] {
        case .preparing, .ready, .fetching: true
        case .failed, nil: false
        }
    }

    /// The highest level played or being played for the story; nil when none was played or the id is unknown.
    public func deepestLevel(_ id: UUID) -> Int? { levels[id] }

    /// The number of levels whose text exists for the story (told or not); 0 when unknown.
    public func storedLevels(_ id: UUID) -> Int { stored[id] ?? 0 }

    /// The level being fetched for the story ("more"); nil when nothing is being fetched for it.
    public func fetchingLevel(_ id: UUID) -> Int? {
        if case .fetching(let level) = phases[id] { return level }
        return nil
    }

    /// The level "more" asks for: the one after the deepest heard. A ready story has level 1 even when nothing was
    /// played yet, so that counts as heard here.
    private func nextLevel(_ id: UUID) -> Int {
        max(levels[id] ?? 0, 1) + 1
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        let effects = process(event)
        switch event {
        case .buzzSent(let id), .storyReady(let id), .storyFailed(let id), .moreReady(let id, _), .moreFailed(let id, _),
             .tellMe(let id), .more(let id), .skip(let id), .finished(let id, _), .listen(let id, _),
             .restored(let id, _, _):
            touch(id)
        case .stoppedExternally:
            break
        }
        return effects
    }

    private mutating func touch(_ id: UUID) {
        recency.removeAll { $0 == id }
        if phases[id] != nil || levels[id] != nil { recency.append(id) }
        // Drop the oldest ids that are idle; never one that is playing, preparing or fetching.
        var index = 0
        while recency.count > Self.memoryLimit, index < recency.count {
            let old = recency[index]
            switch phases[old] {
            case .preparing, .fetching:
                index += 1
            default:
                if playing?.id == old { index += 1; continue }
                phases[old] = nil
                levels[old] = nil
                stored[old] = nil
                recency.remove(at: index)
            }
        }
    }

    private mutating func process(_ event: Event) -> [Effect] {
        switch event {
        case .buzzSent(let id):
            phases[id] = .preparing(wanted: false)
            return []

        case .restored(let id, let storedLevels, let deepestHeard):
            guard storedLevels >= 1 else { return [] }
            let cap = min(storedLevels, StoryLevel.allCases.count)
            phases[id] = .ready
            stored[id] = cap
            levels[id] = deepestHeard >= 1 ? min(deepestHeard, cap) : nil
            return []

        case .storyReady(let id):
            guard case .preparing(let wanted) = phases[id] else { return [] }
            phases[id] = .ready
            stored[id] = max(stored[id] ?? 0, 1)
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
            case .ready, .fetching:
                // Already playing this story: the tap changes nothing. While more is being fetched the tap replays
                // level 1 and the fetch carries on; its `moreReady` plays the new level.
                if playing?.id == id { return [] }
                return start(id, level: 1)
            case .failed, nil:
                // Unknown: the app was relaunched and the prepared story is gone; the app re-prepares from memory.
                return [.reportFailure(id)]
            }

        case .more(let id):
            // The level after the deepest heard: played from storage when its text exists, otherwise fetched.
            let next = nextLevel(id)
            guard phases[id] == .ready, next <= StoryLevel.allCases.count else { return [] }
            if next <= stored[id] ?? 0 { return start(id, level: next) }
            phases[id] = .fetching(level: next)
            return [.fetchMore(id)]

        case .moreReady(let id, let level):
            guard case .fetching = phases[id] else { return [] }
            phases[id] = .ready
            stored[id] = max(stored[id] ?? 0, level)
            return start(id, level: level)

        case .moreFailed(let id, let storedLevels):
            guard case .fetching = phases[id] else { return [] }
            phases[id] = .ready
            // A level whose text was saved can be listened to even though its speech failed.
            stored[id] = max(stored[id] ?? 0, min(storedLevels, StoryLevel.allCases.count))
            return [.reportFailure(id)]

        case .skip(let id):
            var effects: [Effect] = []
            if playing?.id == id {
                playing = nil
                effects.append(.stopAudio)
            }
            // Forgetting the id makes a late result for it (ready, more ready) be ignored.
            phases[id] = nil
            levels[id] = nil
            stored[id] = nil
            effects.append(.retire(id))
            return effects

        case .finished(let id, let level):
            // A stale finish (interrupted, skipped, or of an earlier level than the one now playing) changes nothing.
            guard let current = playing, current.id == id, current.level == level else { return [] }
            playing = nil
            // After a replay of level 1 the later levels exist already: offer more only if some level is still untold.
            return (levels[id] ?? level) < StoryLevel.allCases.count ? [.offerMore(id)] : []

        case .stoppedExternally:
            playing = nil
            return []

        case .listen(let id, let level):
            switch phases[id] {
            case .ready, .fetching:
                // Only a level whose text exists.
                guard level >= 1, level <= stored[id] ?? 0 else { return [] }
                // A level of the story already playing replaces it in the player (`play` for the same id).
                if let current = playing, current.id == id, current.level == level { return [] }
                return start(id, level: level)
            case .preparing:
                // No text yet; "tell me" is the way to wait for it.
                return []
            case .failed, nil:
                return [.reportFailure(id)]
            }
        }
    }

    private mutating func start(_ id: UUID, level: Int) -> [Effect] {
        var effects: [Effect] = []
        if let current = playing, current.id != id { effects.append(.stopAudio) }
        playing = (id, level)
        levels[id] = max(levels[id] ?? 0, level)
        effects.append(.play(id, level: level))
        return effects
    }
}
