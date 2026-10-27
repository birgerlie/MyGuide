import Foundation
import Observation
import WatchConnectivity

/// The iPhone side of WatchConnectivity. Messages are `[String: Any]` dictionaries with a `"type"` key.
/// Types so far: `ping` (answered with `pong`) and `check.tell`.
@MainActor
@Observable
final class WatchLink: NSObject {
    private(set) var isPaired = false
    private(set) var isInstalled = false
    private(set) var isReachable = false
    private(set) var activated = false
    /// The `type` of the last message received from the watch.
    private(set) var lastReceived: String?

    /// Handles a message from the watch and returns the reply (an empty dictionary when none is due).
    @ObservationIgnored var onMessage: (@MainActor ([String: Any]) -> [String: Any])?

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    /// Activates the session. Called once at launch so messages sent while the app is in the background are delivered.
    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// Sends now when the watch is reachable, else queues it for delivery.
    func send(_ message: [String: Any]) {
        guard let session, session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil, errorHandler: { _ in })
        } else {
            session.transferUserInfo(message)
        }
    }

    fileprivate func refresh(_ state: State) {
        isPaired = state.isPaired
        isInstalled = state.isInstalled
        isReachable = state.isReachable
        activated = state.activated
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

    fileprivate func receive(_ message: [String: Any]) -> [String: Any] {
        lastReceived = message["type"] as? String
        if message["type"] as? String == "ping" { return ["type": "pong"] }
        return onMessage?(message) ?? [:]
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let state = State(session)
        Task { @MainActor in self.refresh(state) }
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
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in reply(self.receive(box.value)) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let box = Box(value: message)
        Task { @MainActor in _ = self.receive(box.value) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let box = Box(value: userInfo)
        Task { @MainActor in _ = self.receive(box.value) }
    }
}
