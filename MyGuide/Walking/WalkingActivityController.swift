@preconcurrency import ActivityKit
import Foundation
import MyGuideCore

/// The Live Activity of walking mode (spec 7.5): «Gåmodus» / «Walking» (or the paused text) with the latest buzzed or
/// playing place and its factual line, «Ser etter steder rundt deg» before the first one, and a stop story on the
/// lock screen. Every text is computed here, the headline and the waiting text in the iPhone's language (`UILanguage`)
/// and the place's factual line in the story language (spec 17); the widget only displays. A place never alerts
/// (its notification already did); a stop story does unless `quiet`. An
/// update works with the app in the background; one that cannot be made throws, so the caller can fall back to a
/// notification. Updates are applied in the order they were made. Every push carries a stale date
/// (`WalkingStatus.activityStaleDate`, or `WalkingStatus.pausedStaleDate` while paused), so an activity whose app was
/// ended stops claiming "Walking" on its own.
@MainActor
final class WalkingActivityController {
    struct NotRunning: Error {}

    /// What the activity shows (or was last asked to show).
    private struct Shown: Equatable {
        var headline: String
        var body: String
        var storyID: UUID?
        var placeName: String?
        var placeFact: String?
    }

    /// Called beside the memory log for every Live Activity failure, with its context, for the walk log.
    var onFailure: ((String, Error) -> Void)?

    /// The owner's Live Activities setting.
    static var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    private var activity: Activity<WalkingActivityAttributes>?
    /// The latest buzzed or playing place this run; nil before the first.
    private var place: Candidate?
    private var isPaused = false
    private var shown: Shown?
    /// The newest stale date the controller knows, and the one last pushed.
    private var staleDate: Date?
    private var pushedStaleDate: Date?
    private var buzzCount = 0
    /// True while the activity shows a stop story. Status changes leave it up until the next buzz, a pause or a resume.
    private var showingStop = false
    private var stopBuzzCount = 0
    private var lastPush: Task<Void, Never>?
    /// Counts starts, so a start that was overtaken knows it is stale.
    private var generation = 0

    /// Starts the activity, after ending any left over from an earlier launch, and returns its id (nil when there is
    /// none: not allowed, failed, or a newer start took over while this one was ending the old ones). A failure is
    /// logged and walking mode goes on without one (stop stories then arrive as notifications).
    func start(at date: Date) async -> String? {
        generation += 1
        let mine = generation
        activity = nil
        place = nil
        isPaused = false
        buzzCount = 0
        showingStop = false
        lastPush = nil
        let stale = WalkingStatus.activityStaleDate(lastFixAt: nil, startedAt: date)
        let first = walkingShown(storyLanguage: AppServices.currentStoryLanguage())
        shown = first
        staleDate = stale
        pushedStaleDate = stale
        await Self.endAll()
        // A newer start (stop, then start again) owns the activity now; this one must not touch it.
        guard generation == mine, ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        do {
            let state = Self.state(first, at: date)
            let attributes = WalkingActivityAttributes(startedAt: date, language: UILanguage.current.rawValue)
            let requested = try Activity.request(attributes: attributes,
                                                 content: ActivityContent(state: state, staleDate: stale))
            activity = requested
            return requested.id
        } catch {
            AppServices.logMemoryFailure("live activity start failed", error)
            onFailure?("live activity start failed", error)
            return nil
        }
    }

    /// Shows the walking status when it changed (a pause or a resume, or the story language of the factual line), not
    /// on every fix; and pushes what is shown again when `staleDate` has moved on enough
    /// (`WalkingStatus.needsStaleRefresh`). A stop story on show stays up until the next buzz (or `clearStop()`).
    func updateStatus(paused: Bool, buzzCount count: Int, staleDate stale: Date) {
        buzzCount = count
        staleDate = stale
        isPaused = paused
        guard activity != nil else { return }
        if showingStop, count != stopBuzzCount { showingStop = false }
        let next = showingStop ? shown : walkingShown(storyLanguage: AppServices.currentStoryLanguage())
        guard let next else { return }
        if next != shown || WalkingStatus.needsStaleRefresh(pushed: pushedStaleDate, next: stale) {
            push(next, alert: nil)
        }
    }

    /// Shows `candidate` as the latest place: on a buzz and when its story starts playing. Never alerts: the buzz
    /// notification already did. Replaces a stop story on show.
    func showPlace(_ candidate: Candidate) {
        place = candidate
        guard activity != nil else { return }
        showingStop = false
        let next = walkingShown(storyLanguage: AppServices.currentStoryLanguage())
        if next != shown { push(next, alert: nil) }
    }

    /// Lets the next status change replace a stop story on show: a pause and a resume always show their status
    /// («Gåmodus satt på pause» / «Walking paused», then «Gåmodus» / «Walking» with the place), since a stop story
    /// always comes before the pause it led to.
    func clearStop() {
        showingStop = false
    }

    /// Puts the stop story on the lock screen; `quiet` leaves out the alert (sound, screen on) while another story
    /// is playing. Throws `NotRunning` when there is no activity to update.
    func showStop(_ story: WalkStory, quiet: Bool) async throws {
        guard let activity, activity.activityState == .active else { throw NotRunning() }
        showingStop = true
        stopBuzzCount = buzzCount
        let text = story.levels.first ?? ""
        let alert = quiet ? nil : AlertConfiguration(title: LocalizedStringResource(stringLiteral: story.title),
                                                     body: LocalizedStringResource(stringLiteral: text), sound: .default)
        await push(Shown(headline: story.title, body: text, storyID: story.id, placeName: nil, placeFact: nil),
                   alert: alert).value
    }

    /// Ends the current run's activity at once (walking mode is off).
    func endCurrent() {
        guard let id = activity?.id else { return }
        end(id: id)
    }

    /// Ends the activity with `id` and only that one; run state is reset only if it is the current activity, so a
    /// start that was given up never touches a newer run's.
    func end(id: String) {
        if activity?.id == id {
            activity = nil
            place = nil
            isPaused = false
            shown = nil
            staleDate = nil
            pushedStaleDate = nil
            showingStop = false
            lastPush = nil
        }
        Task {
            for activity in Activity<WalkingActivityAttributes>.activities where activity.id == id {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Ends every walking activity but the current run's: left over from a run whose app was ended (walking mode
    /// never survives a relaunch), or from the Walking check of an earlier launch.
    func endLeftovers() {
        let current = activity?.id
        Task {
            for activity in Activity<WalkingActivityAttributes>.activities where activity.id != current {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    @discardableResult
    private func push(_ next: Shown, alert: AlertConfiguration?) -> Task<Void, Never> {
        guard let activity else { return Task {} }
        shown = next
        pushedStaleDate = staleDate
        let content = ActivityContent(state: Self.state(next, at: .now), staleDate: staleDate)
        let previous = lastPush
        let task = Task { @MainActor in
            await previous?.value
            if let alert {
                await activity.update(content, alertConfiguration: alert)
            } else {
                await activity.update(content)
            }
        }
        lastPush = task
        return task
    }

    /// The walking status with the latest place, or the waiting text before the first (spec 7.5). No distance: it
    /// would be stale between updates. The status is in the iPhone's language, the factual line in `storyLanguage`.
    private func walkingShown(storyLanguage: StoryLanguage) -> Shown {
        let norwegian = UILanguage.current == .norwegian
        let headline = isPaused ? WalkingActivityAttributes.pausedHeadline(norwegian: norwegian)
                                : (norwegian ? "Gåmodus" : "Walking")
        guard let place else {
            return Shown(headline: headline, body: norwegian ? "Ser etter steder rundt deg" : "Looking for places around you",
                         storyID: nil, placeName: nil, placeFact: nil)
        }
        let fact = FactLine.text(for: place, language: storyLanguage)
        return Shown(headline: headline, body: fact ?? "", storyID: nil, placeName: place.name, placeFact: fact)
    }

    private static func state(_ shown: Shown, at date: Date) -> WalkingActivityAttributes.ContentState {
        WalkingActivityAttributes.ContentState(headline: shown.headline, body: shown.body, updatedAt: date,
                                               storyID: shown.storyID, placeName: shown.placeName,
                                               placeFact: shown.placeFact)
    }

    private static func endAll() async {
        for activity in Activity<WalkingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
