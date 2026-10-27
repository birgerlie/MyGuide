import AVFoundation

/// Plays one audio file at a time through the speaker or connected AirPods.
@MainActor
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var observers: [any NSObjectProtocol] = []

    /// Called on the main actor when playback ends without `stop()` being called:
    /// finished, decode error, interruption began, or the output device went away.
    var onFinish: (() -> Void)?

    isolated deinit {
        removeObservers()
    }

    /// Stops any current playback, then starts `url`. Throws if the session or the file cannot be used;
    /// on every failure path the audio session is left inactive.
    func play(_ url: URL) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let next = try AVAudioPlayer(contentsOf: url)
            next.delegate = self
            guard next.play() else { throw CocoaError(.fileReadCorruptFile) }
            player = next
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        observe()
    }

    func stop() {
        removeObservers()
        guard let current = player else { return }
        player = nil
        current.delegate = nil
        current.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
        onFinish?()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(finished)
        Task { @MainActor in self.didEnd(id) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ failed: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(failed)
        Task { @MainActor in self.didEnd(id) }
    }

    private func didEnd(_ id: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == id else { return }
        stop()
        onFinish?()
    }
}
