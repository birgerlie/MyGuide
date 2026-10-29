import Foundation
import MyGuideCore

/// The running tour on disk (tours spec 7): one JSON file in Application Support, written whenever the tour changes
/// (start, a stop visited or skipped, the finish) and removed when it ends, so a tour survives the app being closed.
/// The paths were simplified when the tour started (`ActiveTour.pathTolerance`), so the file stays at a few tens of
/// kilobytes even for a long tour, and the synchronous writes on the main actor are cheap. A write happens a handful of
/// times per tour, never per fix.
struct TourStore: Sendable {
    let url: URL

    /// Application Support/ActiveTour.json.
    static let standard = TourStore(url: URL.applicationSupportDirectory.appending(path: "ActiveTour.json"))

    /// The stored tour, or nil when there is none. Throws when the file exists but cannot be read or decoded.
    func load() throws -> ActiveTour? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        return try JSONDecoder().decode(ActiveTour.self, from: data)
    }

    /// Replaces the stored tour, atomically. Readable after the first unlock, so a walk with the phone locked can
    /// still write it.
    func save(_ tour: ActiveTour) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(tour).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Removes the stored tour; no file is not an error.
    func clear() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}
