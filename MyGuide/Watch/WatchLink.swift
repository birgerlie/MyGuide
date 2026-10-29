import Foundation
import MyGuideCore
import Observation
import os
import WatchConnectivity

/// The iPhone side of WatchConnectivity. Messages are `[String: Any]` dictionaries with a `"type"` key.
/// From the watch: `ping` (answered here with `pong`), `check.tell`, the guided walk commands `walk.*` and «Lytt» on a
/// buzz (`buzz.tell`). To the watch: the walk state (`walk.state`) as the application context, and each buzz (`buzz`)
/// as a message.
@MainActor
@Observable
final class WatchLink: NSObject {
    private(set) var isPaired = false
    private(set) var isInstalled = false
    private(set) var isReachable = false
    private(set) var activated = false
    /// The `type` of the last message received from the watch.
    private(set) var lastReceived: String?

    /// Handles a message from the watch other than `ping` and returns the reply (an empty dictionary when none is
    /// due). The reply is sent when it returns.
    @ObservationIgnored var onCommand: (@MainActor ([String: Any]) async -> [String: Any])?
    /// The walk state now, freshly stamped. Pushed on every activation of the session, so the watch has it after a
    /// launch and again after a watch switch (the old session deactivates and a new one activates).
    @ObservationIgnored var currentState: (@MainActor () -> [String: Any])?
    /// The newest state pushed before the session was activated; sent on activation when `currentState` is not set.
    @ObservationIgnored private var pendingState: Box?

    nonisolated private static let log = Logger(subsystem: "io.github.birgerlie.MyGuide", category: "watch")

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    /// Activates the session. Called once at launch so messages sent while the app is in the background are delivered.
    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// Sends now when the watch is reachable, else queues it for delivery. A send that fails (the watch went out of
    /// reach between the check and the send, or did not answer) is logged and queued instead; the receiver must
    /// tolerate the same message twice (a buzz is deduped by id).
    func send(_ message: [String: Any]) {
        guard let session, session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil, errorHandler: Self.queueOnFailure(Box(value: message)))
        } else {
            session.transferUserInfo(message)
        }
    }

    /// The error handler for `send`, made off the actor as a `@Sendable` closure: WatchConnectivity calls it on its own
    /// queue, where a closure inheriting this class's main-actor isolation would trap.
    nonisolated private static func queueOnFailure(_ message: Box) -> @Sendable (Error) -> Void {
        { error in
            let ns = error as NSError
            let type = message.value["type"] as? String ?? "?"
            log.error("send \(type, privacy: .public) failed, queued: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            WCSession.default.transferUserInfo(message.value)
        }
    }

    /// Makes `state` the application context, which the watch reads whenever its app starts or becomes active.
    /// Before activation it is remembered (only the newest) and pushed once the session is activated.
    func pushState(_ state: [String: Any]) {
        guard let session else { return }
        guard session.activationState == .activated else {
            pendingState = Box(value: state)
            return
        }
        // A remembered state is older than this one: it must not be pushed after it.
        pendingState = nil
        update(session, context: state)
    }

    private func update(_ session: WCSession, context: [String: Any]) {
        do {
            try session.updateApplicationContext(context)
        } catch {
            let ns = error as NSError
            Self.log.error("application context update failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
        }
    }

    fileprivate func refresh(_ state: State) {
        isPaired = state.isPaired
        isInstalled = state.isInstalled
        isReachable = state.isReachable
        activated = state.activated
    }

    /// The session finished activating. When it is activated the current state is pushed, else the remembered one.
    fileprivate func activationCompleted(_ state: State) {
        refresh(state)
        guard state.activated, let session else { return }
        let pending = pendingState
        pendingState = nil
        if let context = currentState?() ?? pending?.value {
            update(session, context: context)
        }
    }

    fileprivate struct State: Sendable {
        let isPaired: Bool
        let isInstalled: Bool
        let isReachable: Bool
        let activated: Bool

        init(_ session: WCSession) {
            isPaired = session.isPaired
            isInstalled = session.isWatchAppInstalled
            isReachable = session.isReachable
            activated = session.activationState == .activated
        }
    }

    /// Plist dictionaries are copied before delivery, so moving one across isolation domains is safe.
    fileprivate struct Box: @unchecked Sendable {
        let value: [String: Any]
    }

    /// WatchConnectivity's reply handler, called once with the reply. It may be called from any thread, so it is
    /// carried to the main actor in this box rather than captured by a closure that would inherit its isolation.
    fileprivate struct ReplyBox: @unchecked Sendable {
        let send: ([String: Any]) -> Void
    }

    fileprivate func receive(_ message: [String: Any]) async -> [String: Any] {
        lastReceived = message["type"] as? String
        if message["type"] as? String == WatchMessage.ping { return ["type": WatchMessage.pong] }
        return await onCommand?(message) ?? [:]
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let state = State(session)
        Task { @MainActor in self.activationCompleted(state) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        let state = State(session)
        Task { @MainActor in self.refresh(state) }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // After a watch switch the old session is finished; a new one must be activated.
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let state = State(session)
        Task { @MainActor in self.refresh(state) }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let state = State(session)
        Task { @MainActor in self.refresh(state) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let box = Box(value: message)
        let reply = ReplyBox(send: replyHandler)
        Task { @MainActor in
            let answer = await self.receive(box.value)
            reply.send(answer)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let box = Box(value: message)
        Task { @MainActor in _ = await self.receive(box.value) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let box = Box(value: userInfo)
        Task { @MainActor in _ = await self.receive(box.value) }
    }
}
