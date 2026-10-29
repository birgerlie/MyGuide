import Foundation

/// The running tour on disk (tours spec 7): one JSON file, written whenever the tour changes and removed when it ends,
/// so a tour survives the app being closed. The paths were simplified when the tour started
/// (`ActiveTour.pathTolerance`), so the file stays at a few tens of kilobytes and writing it synchronously is cheap.
public struct ActiveTourStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The stored tour, or nil when there is no file. Throws a `DecodingError` for a file that is not a tour, and the
    /// read error for a file that cannot be read (on iOS: protected while the phone is locked after a restart).
    public func load() throws -> ActiveTour? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        return try JSONDecoder().decode(ActiveTour.self, from: data)
    }

    /// Replaces the stored tour atomically, creating the directory when needed. On iOS the file is readable after the
    /// first unlock, so a walk with the phone locked can still write it.
    public func save(_ tour: ActiveTour) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS) || os(watchOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try JSONEncoder().encode(tour).write(to: url, options: options)
    }

    /// Removes the stored tour; no file is not an error.
    public func clear() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}
