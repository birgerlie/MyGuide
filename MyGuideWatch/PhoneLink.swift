import Foundation
import WatchConnectivity

enum PhoneLinkError: LocalizedError {
    case notActivated
    case notReachable
    case unexpectedReply

    var errorDescription: String? {
        switch self {
        case .notActivated: "Phone link not active"
        case .notReachable: "Phone not reachable"
        case .unexpectedReply: "Unexpected reply from the phone"
        }
    }
}

/// The watch side of WatchConnectivity. Messages are `[String: Any]` dictionaries with a `"type"` key.
@MainActor
@Observable
final class PhoneLink: NSObject {
    static let shared = PhoneLink()

    private(set) var isReachable = false
    private(set) var lastReceived: String?

    /// Handles a message from the phone; set by whoever cares (Task 15 adds the walking types).
    @ObservationIgnored var onMessage: (@MainActor ([String: Any]) -> Void)?

    /// Handles the phone's application context: each one it pushes, and the newest one already received when the
    /// session activates. Setting it also delivers that newest context, so an owner set after activation misses
    /// nothing. The receiver must tolerate the same context twice.
    @ObservationIgnored var onState: (@MainActor ([String: Any]) -> Void)? {
        didSet { deliverReceivedContext() }
    }

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    override init() {
        super.init()
        session?.delegate = self
        session?.activate()
    }

    /// Sends a message and returns the phone's reply. Waits up to 3 s for the session to activate first,
    /// since an Action button press can launch the app cold.
    func send(_ message: [String: Any]) async throws -> [String: Any] {
        guard let session else { throw PhoneLinkError.notActivated }
        var waited = 0
        while session.activationState != .activated, waited < 30 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        guard session.activationState == .activated else { throw PhoneLinkError.notActivated }
        guard session.isReachable else { throw PhoneLinkError.notReachable }
        return try await Self.sendMessage(UncheckedBox(value: message)).value
    }

    /// WatchConnectivity calls the reply and error handlers on its own queue. Handlers written inside this main-actor
    /// class would inherit its isolation and trap there (Swift 6 checks it at run time), so they are made here, off
    /// the actor, as `@Sendable` closures.
    private nonisolated static func sendMessage(_ message: UncheckedBox) async throws -> UncheckedBox {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UncheckedBox, Error>) in
            WCSession.default.sendMessage(message.value,
                                          replyHandler: { @Sendable reply in
                                              continuation.resume(returning: UncheckedBox(value: reply))
                                          },
                                          errorHandler: { @Sendable error in continuation.resume(throwing: error) })
        }
    }

    /// Hands the newest received context to `onState`; also called when the app becomes active.
    func deliverReceivedContext() {
        guard let session, session.activationState == .activated else { return }
        let context = session.receivedApplicationContext
        guard !context.isEmpty else { return }
        onState?(context)
    }

    /// Fire-and-forget form for callers that do not show a result.
    func tell(_ message: [String: Any]) async throws {
        _ = try await send(message)
    }
}

/// WatchConnectivity payloads are plain property-list dictionaries, copied before delivery,
/// so moving one across isolation domains is safe.
struct UncheckedBox: @unchecked Sendable {
    let value: [String: Any]
}

extension PhoneLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            self.deliverReceivedContext()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let box = UncheckedBox(value: message)
        Task { @MainActor in
            self.lastReceived = box.value["type"] as? String
            self.onMessage?(box.value)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let box = UncheckedBox(value: applicationContext)
        Task { @MainActor in self.onState?(box.value) }
    }
}
