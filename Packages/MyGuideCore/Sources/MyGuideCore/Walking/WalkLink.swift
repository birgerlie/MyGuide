import Foundation

/// The `myguide://walk/<story id>` link the Live Activity carries, which opens that walk story.
public enum WalkLink {
    public static let scheme = "myguide", host = "walk"

    public static func url(for id: UUID) -> URL {
        URL(string: "\(scheme)://\(host)/\(id.uuidString)")!
    }

    /// The story id in a walk link; nil for another scheme or host, a missing or malformed id, or extra path parts.
    public static func storyID(from url: URL) -> UUID? {
        guard url.scheme == scheme, url.host() == host, url.pathComponents.count == 2 else { return nil }
        return UUID(uuidString: url.pathComponents[1])
    }
}
