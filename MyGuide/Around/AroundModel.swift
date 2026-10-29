import Foundation
import MyGuideCore
import Observation
import UIKit

/// What «Rundt deg» shows (spec 5, 6): the notify-worthy places of the shared nearby list, the owner's position and
/// phone heading, and the place the owner is looking at, from `PlaceSelector`. Runs between `appear()` and
/// `disappear()`, i.e. while the map screen is visible: location, phone heading and a once-a-second tick that picks up
/// a changed list (any refresh: this screen's, walking mode's, a background wake's), lets a pending selection change
/// finish its dwell without new samples, and selects a place just buzzed (spec 12.2).
/// Automatic selection never starts audio; only `listen()` does.
@MainActor
@Observable
final class AroundModel {
    /// Selector updates from heading and position samples are at most this often (seconds), so 10 Hz.
    nonisolated static let minimumUpdateInterval: TimeInterval = 0.1
    /// The tick that reloads the list, checks for a buzz and updates the selection.
    nonisolated static let tickInterval: Duration = .seconds(1)

    /// The tiered places of the nearby list in the story language (spec 6.1); empty without a list.
    private(set) var places: [WalkingPlace] = []
    private(set) var selection: SelectionState = .noPlaces
    /// The owner's position from the latest usable fix; nil without one (none yet, invalid or older than 60 s).
    private(set) var position: Coordinate?
    /// The smoothed phone heading, only while it is reliable (heading accuracy and position accuracy within the
    /// limits of spec 6.4); nil means no view cone.
    private(set) var heading: Double?
    /// Whole seconds since the shown list was fetched; nil without a list, or when it is dated in the future. The map
    /// shows it when it is over 600 s (spec 5).
    private(set) var listAge: TimeInterval?
    /// True while there is no list in the story language yet ("Finner steder rundt deg …").
    private(set) var loading = true

    /// The story language setting as it is now; the list and the stories use it.
    var language: StoryLanguage { AppServices.currentStoryLanguage() }

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let location: LocationProvider
    @ObservationIgnored private let phoneHeading: PhoneHeadingProvider
    @ObservationIgnored private let config = PlaceSelectionConfig()
    @ObservationIgnored private var selector: PlaceSelector
    @ObservationIgnored private var active = false
    @ObservationIgnored private var tick: Task<Void, Never>?
    /// The trailing update of a burst of samples that came within `minimumUpdateInterval` of the last update.
    @ObservationIgnored private var pendingUpdate: Task<Void, Never>?
    @ObservationIgnored private var lastUpdateAt = Date.distantPast
    /// The last buzz already acted on (or present when the screen appeared), so each buzz selects once.
    @ObservationIgnored private var seenBuzzAt: Date?

    init(services: AppServices, location: LocationProvider) {
        self.services = services
        self.location = location
        phoneHeading = PhoneHeadingProvider(location: location)
        selector = PlaceSelector(config: config)
    }

    /// The map screen became visible: starts location (feeding foreground refreshes of the nearby list), the phone
    /// heading and the tick. A buzz delivered before this moment does not select its place.
    func appear() {
        guard !active else { return }
        active = true
        seenBuzzAt = services.walking.lastBuzz?.at
        location.onFix = { [weak self] fix in self?.fixArrived(fix) }
        location.start()
        phoneHeading.onChange = { [weak self] in self?.scheduleUpdate() }
        phoneHeading.start()
        if let fix = location.fix() { services.noteForegroundFix(fix) }
        tick = Task { [weak self] in
            while !Task.isCancelled {
                // Scoped so the model is not held during the sleep.
                do {
                    guard let model = self else { return }
                    await model.tickOnce()
                }
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    /// The map screen is gone (or the app left the foreground): stops location, heading and the tick. The list and
    /// the last selection stay for the next appearance, which updates them at once.
    func disappear() {
        guard active else { return }
        active = false
        tick?.cancel()
        tick = nil
        pendingUpdate?.cancel()
        pendingUpdate = nil
        phoneHeading.stop()
        phoneHeading.onChange = nil
        location.onFix = nil
        location.stop()
        heading = nil
    }

    /// The owner tapped a marker (spec 6.3): selects it at once and holds it against automatic changes. Ignored
    /// without a usable position or for a place not in the list.
    func choose(_ placeID: String) {
        let now = Date.now
        guard let input = input(now: now) else { return }
        assign(selection: selector.choose(placeID: placeID, input))
        lastUpdateAt = now
    }

    /// «Lytt» on the selected place: its story on this run in the story language when there is one (just buzzed,
    /// preparing or ready) from level 1, else a new story told for the place (spec 12.1). Does nothing without a
    /// selected place or a position.
    func listen() {
        guard case .selected(let selected) = selection, let position else { return }
        let place = selected.vector.place
        let language = language
        let stories = services.walking.stories
        if let id = stories.storyID(forPlace: place.candidate.id, language: language) {
            stories.listen(id, level: 1)
        } else {
            services.walking.tellPlace(place, position: position, language: language)
        }
    }

    // MARK: - Updates

    private func fixArrived(_ fix: LocationFix) {
        guard active else { return }
        services.noteForegroundFix(fix)
        scheduleUpdate()
    }

    /// A heading or position sample: updates at once when the last update is at least `minimumUpdateInterval` old,
    /// else once that interval has passed (one trailing update for the whole burst, from the latest samples).
    private func scheduleUpdate() {
        guard active else { return }
        let now = Date.now
        let wait = Self.minimumUpdateInterval - now.timeIntervalSince(lastUpdateAt)
        guard wait > 0 else {
            update(now: now)
            return
        }
        guard pendingUpdate == nil else { return }
        pendingUpdate = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, self.active else { return }
            self.pendingUpdate = nil
            self.update(now: .now)
        }
    }

    /// Rebuilds the vectors from the latest position and feeds the selector. Without a usable fix the selector is
    /// reset (an infinite accuracy) and the state is "uncertain position".
    private func update(now: Date) {
        pendingUpdate?.cancel()
        pendingUpdate = nil
        lastUpdateAt = now
        if let input = input(now: now) {
            assign(selection: selector.update(input))
        } else {
            assign(selection: selector.update(SelectionInput(vectors: [], positionAccuracy: .infinity, heading: nil,
                                                             headingAccuracy: nil, playingPlaceID: nil, now: now)))
        }
    }

    /// The selector's input from the latest fix and heading; nil without a usable fix. Also refreshes `position`
    /// and `heading`, so they always match what the selector saw.
    private func input(now: Date) -> SelectionInput? {
        let fix = location.fix(at: now)
        assign(position: fix?.coordinate)
        let smoothed = phoneHeading.heading
        let headingAccuracy = phoneHeading.accuracy
        let reliable = Self.isReliable(heading: smoothed, headingAccuracy: headingAccuracy,
                                       positionAccuracy: fix?.accuracy, config)
        assign(heading: reliable ? smoothed : nil)
        guard let fix else { return nil }
        return SelectionInput(vectors: PlaceVector.from(position: fix.coordinate, places: places),
                              positionAccuracy: fix.accuracy, heading: smoothed, headingAccuracy: headingAccuracy,
                              playingPlaceID: services.walking.stories.playingPlaceID, now: now)
    }

    /// Spec 6.4: a heading with accuracy at most `maxHeadingAccuracy`, from a position with accuracy at most
    /// `maxPositionAccuracy`.
    nonisolated static func isReliable(heading: Double?, headingAccuracy: Double?, positionAccuracy: Double?,
                                       _ config: PlaceSelectionConfig) -> Bool {
        guard let heading, heading.isFinite,
              let headingAccuracy, headingAccuracy >= 0, headingAccuracy <= config.maxHeadingAccuracy,
              let positionAccuracy, positionAccuracy <= config.maxPositionAccuracy else { return false }
        return true
    }

    /// One tick: the list in the story language, a new buzz, then the selection.
    private func tickOnce() async {
        let language = language
        let list = await services.nearby.current(language: language)
        guard active else { return }
        let now = Date.now
        let newPlaces = list?.walkingPlaces ?? []
        if newPlaces != places { places = newPlaces }
        let isLoading = list == nil
        if loading != isLoading { loading = isLoading }
        let age = list.flatMap { list -> TimeInterval? in
            let seconds = now.timeIntervalSince(list.fetchedAt)
            return seconds >= 0 ? seconds.rounded(.down) : nil
        }
        if listAge != age { listAge = age }
        selectBuzzedPlace()
        update(now: now)
    }

    /// Spec 12.2: a buzz while the app is active makes the buzzed place the explicit selection, so the map and the
    /// notification agree. A buzz for a place not in the list is passed over.
    private func selectBuzzedPlace() {
        guard let buzz = services.walking.lastBuzz, buzz.at != seenBuzzAt else { return }
        seenBuzzAt = buzz.at
        guard UIApplication.shared.applicationState == .active,
              places.contains(where: { $0.candidate.id == buzz.placeID }) else { return }
        choose(buzz.placeID)
    }

    // MARK: - Assignments that notify only on change

    private func assign(selection new: SelectionState) {
        if selection != new { selection = new }
    }

    private func assign(position new: Coordinate?) {
        if position != new { position = new }
    }

    private func assign(heading new: Double?) {
        if heading != new { heading = new }
    }
}
