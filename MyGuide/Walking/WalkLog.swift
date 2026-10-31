import Foundation
import MyGuideCore
import os

/// The walk log (spec 4): one JSON Lines file per walking-mode run in `Application Support/WalkLogs`, each line
/// written when its event happens. Logging never stops walking mode: a failure goes to `os.Logger` (category
/// `walklog`) and the event is dropped. Without a run in progress every call is a no-op, so work that ends after
/// `end()` (a late fetch, a cancelled story) writes nothing.
@MainActor
final class WalkLog {
    nonisolated static let logger = Logger(subsystem: "io.github.birgerlie.MyGuide", category: "walklog")
    /// Created on demand by the first run's writer.
    nonisolated static let directory = URL.applicationSupportDirectory.appending(path: "WalkLogs", directoryHint: .isDirectory)

    /// The file of the run in progress; nil when there is none (or its file could not be opened).
    private(set) var currentURL: URL?
    private var writer: WalkLogWriter?
    private var quiet = QuietThrottle()
    /// The allowance of the last `server` line written in this run; nil before the first.
    private var lastServer: ServerAllowance?

    /// Opens the file of a new run, then deletes the oldest files beyond the newest 20 (the new one counts and is
    /// never deleted). A run still open is ended first. When the file cannot be opened the run has no log.
    func begin(runID: UUID, at date: Date) {
        end()
        quiet.reset()
        lastServer = nil
        let url = Self.directory.appending(path: WalkLogStore.fileName(start: date, runID: runID),
                                           directoryHint: .notDirectory)
        do {
            writer = try WalkLogWriter(url: url)
            currentURL = url
        } catch {
            Self.logger.error("walk log open failed: \(String(describing: error), privacy: .public)")
            return
        }
        do {
            try WalkLogStore.prune(in: Self.directory, keep: WalkLogStore.keep, sparing: url)
        } catch {
            Self.logger.error("walk log prune failed: \(String(describing: error), privacy: .public)")
        }
    }

    func log(_ kind: WalkLogEvent.Kind, at date: Date = .now) {
        guard let writer else { return }
        Self.append(WalkLogEvent(at: date, kind: kind), to: writer)
    }

    /// A `quiet` line only when the reason, the set of due place ids or the holding place changed since the last one
    /// (spec 4.3, 20.6.6).
    func logQuiet(_ reason: QuietReason, due: [DuePlace], heldBy: HoldingPlace? = nil, at date: Date = .now) {
        guard writer != nil, quiet.shouldLog(reason, due: due, heldBy: heldBy) else { return }
        log(.quiet(reason, due: due, heldBy: heldBy), at: date)
    }

    /// A `server` line with what the guide server says is left, only when it differs from the last one written in
    /// this run (constraints, Ruling 8). Without a run nothing is written or remembered.
    func logServer(_ allowance: ServerAllowance, at date: Date = .now) {
        guard writer != nil, allowance != lastServer else { return }
        lastServer = allowance
        log(.server(allowance), at: date)
    }

    /// After a buzz, a pause or a resume the next quiet decision is always written.
    func resetQuiet() {
        quiet.reset()
    }

    func end() {
        writer?.close()
        writer = nil
        currentURL = nil
    }

    /// Ends the run now, like `end()`, except that its file takes one last line: the outcome of `post`, which runs
    /// at once (the auto-off notification, posted after walking mode stopped). Nothing else reaches the file
    /// meanwhile. An error from `post` goes to `onError` after its `notifyFailed` line.
    func end(posting kind: WalkNotificationKind, id: UUID?, _ post: @escaping @MainActor () async throws -> Void,
             onError: @escaping @MainActor (Error) -> Void) {
        let last = writer
        writer = nil
        currentURL = nil
        Task { @MainActor in
            defer { last?.close() }
            do {
                try await post()
            } catch {
                if let last {
                    Self.append(WalkLogEvent(at: .now, kind: .notifyFailed(id: id, kind: kind, error: WalkLogEvent.errorText(error))), to: last)
                }
                onError(error)
                return
            }
            guard let last else { return }
            let settings = await BuzzNotifier.settingsSnapshot()
            Self.append(WalkLogEvent(at: .now, kind: .notified(id: id, kind: kind, settings: settings)), to: last)
        }
    }

    /// Runs `post`, then logs `notified` with the notification settings read after it, or `notifyFailed`, and
    /// rethrows. Nothing is logged when the run ended (or another began) while `post` ran.
    func posting(_ kind: WalkNotificationKind, id: UUID?, _ post: @MainActor () async throws -> Void) async throws {
        let run = currentURL
        do {
            try await post()
        } catch {
            if run != nil, currentURL == run {
                log(.notifyFailed(id: id, kind: kind, error: WalkLogEvent.errorText(error)))
            }
            throw error
        }
        guard run != nil, currentURL == run else { return }
        let settings = await BuzzNotifier.settingsSnapshot()
        guard currentURL == run else { return }
        log(.notified(id: id, kind: kind, settings: settings))
    }

    private static func append(_ event: WalkLogEvent, to writer: WalkLogWriter) {
        do {
            try writer.append(event)
        } catch {
            logger.error("walk log write failed: \(String(describing: error), privacy: .public)")
        }
    }
}
