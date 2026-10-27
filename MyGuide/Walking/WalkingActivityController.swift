@preconcurrency import ActivityKit
import Foundation
import MyGuideCore

/// The Live Activity of walking mode: "Walking" with the status line, and a stop story on the lock screen. An
/// update works with the app in the background; one that cannot be made throws, so the caller can fall back to a
/// notification. Updates are applied in the order they were made.
@MainActor
final class WalkingActivityController {
    static let headline = "Walking"

    struct NotRunning: Error {}

    private var activity: Activity<WalkingActivityAttributes>?
    /// The last status text; nothing is pushed for the same text again.
    private var status: String?
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
        await Self.endAll()
        // A newer start (stop, then start again) owns the activity now; this one must not touch it.
        guard generation == mine, ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        do {
            let state = WalkingActivityAttributes.ContentState(headline: Self.headline, body: text, updatedAt: date, storyID: nil)
            let requested = try Activity.request(attributes: WalkingActivityAttributes(startedAt: date),
                                                 content: ActivityContent(state: state, staleDate: nil))
            activity = requested
            return requested.id
        } catch {
            AppServices.logMemoryFailure("live activity start failed", error)
            return nil
        }
    }

    /// Shows the status line, but only when its text changed (a buzz, or GPS found or lost), not on every fix.
    func updateStatus(_ text: String, buzzCount count: Int) {
        buzzCount = count
        guard activity != nil, text != status else { return }
        status = text
        if showingStop {
            guard count != stopBuzzCount else { return }
            showingStop = false
        }
        push(headline: Self.headline, body: text, storyID: nil, alert: nil)
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
        await push(headline: story.title, body: text, storyID: story.id, alert: alert).value
    }

    /// Ends an activity at once: the one with `id` (a start that was given up), else the current one (walking mode
    /// is off). Only that instance; a start soon after must not lose the one it requests.
    func end(_ id: String? = nil) {
        guard let target = id ?? activity?.id else { return }
        if activity?.id == target {
            activity = nil
            status = nil
            showingStop = false
            lastPush = nil
        }
        Task {
            for activity in Activity<WalkingActivityAttributes>.activities where activity.id == target {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    @discardableResult
    private func push(headline: String, body: String, storyID: UUID?, alert: AlertConfiguration?) -> Task<Void, Never> {
        guard let activity else { return Task {} }
        let content = ActivityContent(
            state: WalkingActivityAttributes.ContentState(headline: headline, body: body, updatedAt: .now, storyID: storyID),
            staleDate: nil)
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
