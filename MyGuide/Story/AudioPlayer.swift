import AVFoundation

/// Plays one audio file at a time through the speaker or connected AirPods. Across the app only one player plays:
/// starting one stops the other (walking story, photo story, walking check), which hears `.interrupted`, and the
/// shared audio session is deactivated only when the player that is playing stops.
@MainActor
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    /// The player that is playing, if any.
    private static weak var active: AudioPlayer?

    private var player: AVAudioPlayer?
    private var observers: [any NSObjectProtocol] = []

    /// How playback ended without `stop()` being called.
    enum Ending {
        /// The file played to its end.
        case completed
        /// The file could not be decoded.
        case failed
        /// An interruption began (call, Siri) or the output device went away.
        case interrupted
    }

    /// Called on the main actor when playback ends without `stop()` being called.
    var onFinish: ((Ending) -> Void)?

    isolated deinit {
        removeObservers()
    }

    /// Stops any current playback, then starts `url`. Throws if the session or the file cannot be used;
    /// on every failure path the audio session is left inactive.
    func play(_ url: URL) throws {
        stop()
        // Another player stops through its normal path, told after this one has started (or failed to), but keeps
        // the session active for this one.
        let other = Self.active.flatMap { $0 === self ? nil : $0 }
        let otherWasPlaying = other?.yield() ?? false
        defer { if otherWasPlaying { other?.onFinish?(.interrupted) } }
        let session = AVAudioSession.sharedInstance()
        do {
            // Mixable (.duckOthers): iOS refuses to activate a non-mixable session from the background, and a story
            // started from a notification action (e.g. "Tell me" tapped on the Watch while the phone is locked) runs
            // there. Other audio is ducked, not stopped, and returns to full volume on deactivation below.
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            let next = try AVAudioPlayer(contentsOf: url)
            next.delegate = self
            guard next.play() else { throw CocoaError(.fileReadCorruptFile) }
            player = next
        } catch {
            // Nothing plays now: the other player was stopped above.
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        Self.active = self
        observe()
    }

    func stop() {
        removeObservers()
        guard let current = player else { return }
        player = nil
        current.delegate = nil
        current.stop()
        guard Self.active === self else { return }
        Self.active = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Stops for another player without touching the session; true when something was playing.
    private func yield() -> Bool {
        removeObservers()
        guard let current = player else { return false }
        player = nil
        current.delegate = nil
        current.stop()
        if Self.active === self { Self.active = nil }
        return true
    }

    /// Interruptions (calls, Siri) end playback without auto-resume; AirPods removal must not continue on the loudspeaker.
    private func observe() {
        removeObservers()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began else { return }
            Task { @MainActor in self?.endedExternally() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) == .oldDeviceUnavailable else { return }
            Task { @MainActor in self?.endedExternally() }
        })
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }

    private func endedExternally() {
        guard player != nil else { return }
        stop()
        onFinish?(.interrupted)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(finished)
        Task { @MainActor in self.didEnd(id, .completed) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ failed: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(failed)
        Task { @MainActor in self.didEnd(id, .failed) }
    }

    private func didEnd(_ id: ObjectIdentifier, _ ending: Ending) {
        guard let player, ObjectIdentifier(player) == id else { return }
        stop()
        onFinish?(ending)
    }
}
