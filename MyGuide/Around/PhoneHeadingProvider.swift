import CoreMotion
import Foundation
import MyGuideCore
import Observation

/// The direction the phone faces, for the map (spec 6.4): the azimuth of the horizontal projection of (top edge +
/// back) from Core Motion device motion in the true-north frame, at 20 Hz, smoothed. Held flat that is the top
/// edge's direction, held upright the back camera's, with no switch between them. The accuracy is CoreLocation's
/// heading accuracy from `LocationProvider.compass` (device motion gives none), so that provider must run for the
/// heading to count as reliable. Without device motion in the true-north frame (or when it fails), the compass
/// heading itself is used. Runs only between `start()` and `stop()`, i.e. while the map is visible.
@MainActor
@Observable
final class PhoneHeadingProvider {
    /// Device motion samples per second.
    nonisolated static let motionRate = 20.0

    /// Smoothed heading in degrees (0..<360, clockwise from true north); nil while stopped, before the first sample,
    /// and while the phone is rolled on its side (the projection is shorter than `PhoneHeading.minimumLength`).
    private(set) var heading: Double?
    /// CoreLocation's heading accuracy in degrees at the last sample; nil when unknown or invalid (unreliable).
    private(set) var accuracy: Double?
    /// Told after every sample that was taken (heading or accuracy may have changed); the around model updates its
    /// selection from it.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let location: LocationProvider
    @ObservationIgnored private let manager = CMMotionManager()
    /// Device motion handlers run here, off the main thread; each sample hops to the main actor.
    @ObservationIgnored private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "PhoneHeadingProvider.motion"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    @ObservationIgnored private var smoother = HeadingSmoother()
    /// Counts starts and stops, so a sample already on its way to the main actor from an earlier run is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var running = false
    /// The compass polling of the fallback, while it runs.
    @ObservationIgnored private var compassPoll: Task<Void, Never>?

    init(location: LocationProvider) {
        self.location = location
    }

    /// Starts device motion in the true-north frame, or the compass fallback when the phone cannot give it.
    /// A second start while running does nothing.
    func start() {
        guard !running else { return }
        running = true
        generation += 1
        smoother = HeadingSmoother()
        if manager.isDeviceMotionAvailable,
           CMMotionManager.availableAttitudeReferenceFrames().contains(.xTrueNorthZVertical) {
            manager.deviceMotionUpdateInterval = 1 / Self.motionRate
            manager.startDeviceMotionUpdates(using: .xTrueNorthZVertical, to: queue,
                                             withHandler: Self.handler(for: self, generation: generation))
        } else {
            startCompassFallback()
        }
    }

    func stop() {
        guard running else { return }
        running = false
        generation += 1
        manager.stopDeviceMotionUpdates()
        compassPoll?.cancel()
        compassPoll = nil
        heading = nil
        accuracy = nil
    }

    // MARK: - Device motion

    /// The device motion handler. Built in a nonisolated context and `@Sendable`, so it is never main-actor isolated:
    /// Core Motion calls it on `queue`, and a main-actor closure called there would trap. It reads the numbers it
    /// needs from the sample on that queue and sends only them to the main actor.
    nonisolated private static func handler(for provider: PhoneHeadingProvider,
                                            generation: Int) -> CMDeviceMotionHandler {
        { @Sendable [weak provider] motion, error in
            let at = Date.now
            guard let motion else {
                if error != nil {
                    Task { @MainActor in provider?.motionFailed(generation: generation) }
                }
                return
            }
            let azimuth = azimuth(of: motion.attitude.rotationMatrix)
            Task { @MainActor in provider?.receive(azimuth: azimuth, at: at, generation: generation) }
        }
    }

    /// The phone heading of an attitude in the `xTrueNorthZVertical` frame (X north, Y west, Z up). Core Motion's
    /// matrix maps reference vectors to device coordinates (v_device = R · v_ref), so device axis i, expressed in the
    /// reference frame, is row i of R. Top edge = device +Y = row 2; back = device −Z = −row 3. West is −east.
    /// Example: the identity attitude (flat, face up, right edge north) gives top = west and back = down, so 270°.
    nonisolated static func azimuth(of r: CMRotationMatrix) -> Double? {
        let top = Vector3(north: r.m21, east: -r.m22, up: r.m23)
        let back = Vector3(north: -r.m31, east: r.m32, up: -r.m33)
        return PhoneHeading.azimuth(top: top, back: back)
    }

    private func receive(azimuth: Double?, at: Date, generation: Int) {
        guard running, generation == self.generation else { return }
        set(accuracy: location.compass?.accuracy)
        // Rolled on its side: no heading. The smoother keeps its last value; after a pause its α is near 1, so the
        // next valid sample takes over almost entirely.
        heading = azimuth.map { smoother.add($0, at: at) }
        onChange?()
    }

    /// Device motion reported an error (true north unavailable, for example): use the compass instead for this run.
    private func motionFailed(generation: Int) {
        guard running, generation == self.generation, compassPoll == nil else { return }
        manager.stopDeviceMotionUpdates()
        self.generation += 1
        startCompassFallback()
    }

    // MARK: - Compass fallback

    /// Samples `LocationProvider.compass` at the motion rate. CoreLocation reports headings only as they change
    /// (filter 1°), so polling keeps the smoothing's timing the same as with device motion.
    private func startCompassFallback() {
        let interval = Duration.seconds(1 / Self.motionRate)
        compassPoll = Task { [weak self] in
            while !Task.isCancelled {
                // Scoped so the provider is not held during the sleep.
                do {
                    guard let provider = self else { return }
                    provider.sampleCompass(at: .now)
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Assigns only a changed value, so views reading the accuracy are not invalidated 20 times a second.
    private func set(accuracy new: Double?) {
        if accuracy != new { accuracy = new }
    }

    private func sampleCompass(at now: Date) {
        guard running else { return }
        let compass = location.compass
        set(accuracy: compass?.accuracy)
        heading = compass.map { smoother.add($0.heading, at: now) }
        onChange?()
    }
}
