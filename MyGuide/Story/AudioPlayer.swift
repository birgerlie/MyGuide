import AVFoundation

/// Plays one audio file at a time through the speaker or connected AirPods.
@MainActor
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?

    /// Called on the main actor when playback ends on its own (not when `stop()` is called).
    var onFinish: (() -> Void)?

    var isPlaying: Bool { player?.isPlaying ?? false }

    /// Stops any current playback, then starts `url`. Throws if the session or the file cannot be used.
    func play(_ url: URL) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        let next = try AVAudioPlayer(contentsOf: url)
        next.delegate = self
        guard next.play() else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw CocoaError(.fileReadCorruptFile)
        }
        player = next
    }

    func stop() {
        guard let current = player else { return }
        player = nil
        current.delegate = nil
        current.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
