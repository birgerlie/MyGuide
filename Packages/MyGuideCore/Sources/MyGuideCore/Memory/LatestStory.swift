import Foundation

/// The story the Home screen shows first: the newest of the latest photo story and the latest walk story.
public enum LatestStory: Equatable, Sendable {
    case photo(UUID)
    case walk(UUID)

    /// `photo` is the newest photo story (its `takenAt`), `walk` the newest walk story (its `createdAt`).
    /// The strictly newer one wins; at the same instant the photo story wins. Nil when there is neither.
    public static func newest(photo: (id: UUID, at: Date)?, walk: (id: UUID, at: Date)?) -> LatestStory? {
        switch (photo, walk) {
        case (nil, nil): nil
        case let (photo?, nil): .photo(photo.id)
        case let (nil, walk?): .walk(walk.id)
        case let (photo?, walk?): walk.at > photo.at ? .walk(walk.id) : .photo(photo.id)
        }
    }
}
