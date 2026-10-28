import os
import UIKit

/// Background time for one piece of work: `begin(name:)` asks UIKit for it, `end()` gives it back. The task is ended
/// exactly once, by `end()` or by the expiration handler, whichever comes first; later calls do nothing.
final class BackgroundTaskHold: @unchecked Sendable {
    private struct Slot {
        var identifier: UIBackgroundTaskIdentifier = .invalid
        var ended = false
    }

    private static let log = Logger(subsystem: "io.github.birgerlie.MyGuide", category: "walking")

    /// Only used for `endBackgroundTask`, which UIKit declares callable from any thread (`NS_SWIFT_NONISOLATED`).
    /// That is what makes the `@unchecked Sendable` sound.
    private let application: UIApplication
    private let name: String
    private let slot = OSAllocatedUnfairLock(initialState: Slot())

    private init(application: UIApplication, name: String) {
        self.application = application
        self.name = name
    }

    /// Begins a background task. When UIKit gives no background time (`.invalid`) the hold does nothing.
    @MainActor
    static func begin(name: String) -> BackgroundTaskHold {
        let hold = BackgroundTaskHold(application: .shared, name: name)
        let identifier = hold.application.beginBackgroundTask(withName: name,
                                                              expirationHandler: expirationHandler(for: hold))
        let endAtOnce = hold.slot.withLock { slot in
            slot.identifier = identifier
            return slot.ended
        }
        // Ended (expired) before the identifier was stored: end the task now that it is known.
        if endAtOnce, identifier != .invalid { hold.application.endBackgroundTask(identifier) }
        return hold
    }

    /// Made off the main actor: a closure written in `begin` would inherit main-actor isolation and trap if UIKit
    /// ever called it on another thread. `end()` is safe from any thread, so the handler ends the task before it
    /// returns, as UIKit requires.
    private nonisolated static func expirationHandler(for hold: BackgroundTaskHold) -> @Sendable () -> Void {
        { @Sendable in
            log.notice("background time ran out: \(hold.name, privacy: .public)")
            hold.end()
        }
    }

    /// Ends the background task. Safe from any thread; only the first call ends it.
    func end() {
        let identifier: UIBackgroundTaskIdentifier? = slot.withLock { slot in
            guard !slot.ended else { return nil }
            slot.ended = true
            return slot.identifier
        }
        guard let identifier, identifier != .invalid else { return }
        application.endBackgroundTask(identifier)
    }
}
