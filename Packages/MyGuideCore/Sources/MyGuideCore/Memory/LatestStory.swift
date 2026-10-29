import Foundation

/// The story the Home screen shows first: the one most recently told.
public enum LatestStory: Equatable, Sendable {
    case photo(UUID)
    case walk(UUID)

    /// The newest of the recorded ref and the two stored candidates.
    /// - `told`: the story last saved, with when (`LatestStoryRef`), or nil when none is recorded or its record is
    ///   gone. It beats the candidates because a library photo's `takenAt` is its EXIF date, not when it was told.
    /// - `photo`: the newest photo story by `takenAt`; `walk`: the newest walk story by `createdAt`. Fallback for
    ///   stores without a ref.
    /// The strictly newer candidate beats the other candidate; at the same instant the photo story wins. The ref wins
    /// over both candidates unless a candidate is strictly newer than its `toldAt`. Nil when there is nothing.
    public static func newest(told: LatestStoryRef? = nil, photo: (id: UUID, at: Date)?,
                              walk: (id: UUID, at: Date)?) -> LatestStory? {
        let candidate: (story: LatestStory, at: Date)? = switch (photo, walk) {
        case (nil, nil): nil
        case let (photo?, nil): (.photo(photo.id), photo.at)
        case let (nil, walk?): (.walk(walk.id), walk.at)
        case let (photo?, walk?): walk.at > photo.at ? (.walk(walk.id), walk.at) : (.photo(photo.id), photo.at)
        }
        guard let told else { return candidate?.story }
        if let candidate, candidate.at > told.toldAt { return candidate.story }
        return told.story
    }
}

/// The story last told (saved) and when, kept in UserDefaults so Home can show it even when its stored date is old.
public struct LatestStoryRef: Codable, Equatable, Sendable {
    public static let defaultsKey = "latestStory"

    public var story: LatestStory
    public var toldAt: Date

    public init(story: LatestStory, toldAt: Date) {
        self.story = story
        self.toldAt = toldAt
    }

    private enum CodingKeys: String, CodingKey { case kind, id, toldAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UUID.self, forKey: .id)
        switch try c.decode(String.self, forKey: .kind) {
        case "photo": story = .photo(id)
        case "walk": story = .walk(id)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown kind \(other)")
        }
        toldAt = try c.decode(Date.self, forKey: .toldAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch story {
        case .photo(let id): try c.encode("photo", forKey: .kind); try c.encode(id, forKey: .id)
        case .walk(let id): try c.encode("walk", forKey: .kind); try c.encode(id, forKey: .id)
        }
        try c.encode(toldAt, forKey: .toldAt)
    }

    /// Records `story` as told at `at`.
    public static func record(_ story: LatestStory, at: Date = .now, in defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(LatestStoryRef(story: story, toldAt: at)) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// The recorded ref; nil when none was saved or the data is unreadable.
    public static func load(from defaults: UserDefaults = .standard) -> LatestStoryRef? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(LatestStoryRef.self, from: data)
    }
}

/// Where a photo story goes in the navigation path. Generic over the route type so the rules are testable here.
public enum StoryPath {
    /// A photo finished on the camera screen. If `camera` is still in the path, its entry becomes `story` and
    /// whatever was pushed over it stays on top; otherwise (the owner went back) nil: drop the photo.
    public static func replacingCamera<R: Equatable>(in path: [R], camera: R, with story: R) -> [R]? {
        guard let index = path.firstIndex(of: camera) else { return nil }
        var result = path
        result[index] = story
        return result
    }
}
