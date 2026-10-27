import Foundation

/// The walking stories prepared on this run, with the audio file of each level fetched so far, so a tap plays at
/// once. Only the newest few are kept; an older one is rebuilt from memory and the on-disk speech cache.
public struct PreparedWalkStories: Sendable, Equatable {
    public static let limit = 5

    private struct Entry: Sendable, Equatable {
        var story: WalkStory
        /// Audio file per level (1-based).
        var audio: [Int: URL]
    }

    private var entries: [UUID: Entry] = [:]
    /// Story ids from oldest to newest.
    public private(set) var ids: [UUID] = []

    public init() {}

    public func story(_ id: UUID) -> WalkStory? { entries[id]?.story }

    public func audio(_ id: UUID, level: Int) -> URL? { entries[id]?.audio[level] }

    /// Stores `story`, or refreshes it (new levels) keeping the audio already fetched. Either way it becomes the
    /// newest; the oldest beyond `limit` are dropped.
    public mutating func store(_ story: WalkStory) {
        let audio = entries[story.id]?.audio ?? [:]
        entries[story.id] = Entry(story: story, audio: audio.filter { story.levels.indices.contains($0.key - 1) })
        ids.removeAll { $0 == story.id }
        ids.append(story.id)
        while ids.count > Self.limit {
            entries[ids.removeFirst()] = nil
        }
    }

    /// Remembers the audio file of one level. Ignored for an unknown story or a level the story does not have.
    public mutating func setAudio(_ url: URL, id: UUID, level: Int) {
        guard var entry = entries[id], entry.story.levels.indices.contains(level - 1) else { return }
        entry.audio[level] = url
        entries[id] = entry
    }

    public mutating func remove(_ id: UUID) {
        entries[id] = nil
        ids.removeAll { $0 == id }
    }
}
