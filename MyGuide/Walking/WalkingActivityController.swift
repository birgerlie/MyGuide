@preconcurrency import ActivityKit
import Foundation
import MyGuideCore

/// The Live Activity of walking mode: "Walking" with the status line, and a stop story on the lock screen. An
/// update works with the app in the background; one that cannot be made throws, so the caller can fall back to a
/// notification. Updates are applied in the order they were made. Every push carries a stale date
/// (`WalkingStatus.activityStaleDate`), so an activity whose app was ended stops claiming "Walking" on its own.
@MainActor
final class WalkingActivityController {
    static let headline = "Walking"

    struct NotRunning: Error {}

    /// What the activity shows (or was last asked to show).
    private struct Shown {
        var headline: String
        var body: String
        var storyID: UUID?
    }

    private var activity: Activity<WalkingActivityAttributes>?
    /// The last status text; nothing is pushed for the same text again.
    private var status: String?
    private var shown: Shown?
    /// The newest stale date the controller knows, and the one last pushed.
    private var staleDate: Date?
    private var pushedStaleDate: Date?
    private var buzzCount = 0
    /// True while the activity shows a stop story. Status changes leave it up until the next buzz.
    private var showingStop = false
    private var stopBuzzCount = 0
    private var lastPush: Task<Void, Never>?
    /// Counts starts, so a start that was overtaken knows it is stale.
    private var generation = 0

    /// Starts the activity, after ending any left over from an earlier launch, and returns its id (nil when there is
    /// none: not allowed, failed, or a newer start took over while this one was ending the old ones). A failure is
    /// logged and walking mode goes on without one (stop stories then arrive as notifications).
    func start(at date: Date, status text: String) async -> String? {
        generation += 1
        let mine = generation
        activity = nil
        status = text
        buzzCount = 0
        showingStop = false
        lastPush = nil
        let stale = WalkingStatus.activityStaleDate(lastFixAt: nil, startedAt: date)
        shown = Shown(headline: Self.headline, body: text, storyID: nil)
        staleDate = stale
        pushedStaleDate = stale
        await Self.endAll()
        // A newer start (stop, then start again) owns the activity now; this one must not touch it.
        guard generation == mine, ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        do {
            let state = WalkingActivityAttributes.ContentState(headline: Self.headline, body: text, updatedAt: date, storyID: nil)
            let requested = try Activity.request(attributes: WalkingActivityAttributes(startedAt: date),
                                                 content: ActivityContent(state: state, staleDate: stale))
            activity = requested
            return requested.id
        } catch {
            AppServices.logMemoryFailure("live activity start failed", error)
            return nil
        }
    }

    /// Shows the status line when its text changed (a buzz, or GPS found or lost), not on every fix; and pushes what
    /// is shown again when `staleDate` has moved on enough (`WalkingStatus.needsStaleRefresh`). A stop story on show
    /// stays up until the next buzz.
    func updateStatus(_ text: String, buzzCount count: Int, staleDate stale: Date) {
        buzzCount = count
        staleDate = stale
        guard activity != nil else { return }
        if text != status {
            status = text
            if showingStop, count != stopBuzzCount { showingStop = false }
            if !showingStop {
                push(Shown(headline: Self.headline, body: text, storyID: nil), alert: nil)
                return
            }
        }
        if let shown, WalkingStatus.needsStaleRefresh(pushed: pushedStaleDate, next: stale) {
            push(shown, alert: nil)
        }
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
        await push(Shown(headline: story.title, body: text, storyID: story.id), alert: alert).value
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
            status = nil
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
        let content = ActivityContent(
            state: WalkingActivityAttributes.ContentState(headline: next.headline, body: next.body, updatedAt: .now,
                                                          storyID: next.storyID),
            staleDate: staleDate)
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

    private static func endAll() async {
        for activity in Activity<WalkingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
