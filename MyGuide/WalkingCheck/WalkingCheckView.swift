import MyGuideCore
import SwiftUI

/// Checks, on the owner's own device, that background location and audio from a notification action work.
struct WalkingCheckView: View {
    let model: WalkingCheckModel
    let watch: WatchLink

    /// The screen texts follow the iPhone's language (spec 17).
    private var screenLanguage: StoryLanguage { UILanguage.current }

    var body: some View {
        // Pushed from Settings, so it lives in the app's NavigationStack rather than its own.
        List {
            Section {
                row(WalkingCheckTexts.backgroundLocation(screenLanguage), status: model.locationStatus,
                    result: model.locationResult) {
                    Button(model.locationRunning ? WalkingCheckTexts.stop(screenLanguage)
                                                 : WalkingCheckTexts.start(screenLanguage)) {
                        if model.locationRunning { model.stopLocation() } else { model.startLocation() }
                    }
                }
                row(WalkingCheckTexts.buzzFromWatch(screenLanguage), status: model.buzzStatus ?? WalkingCheckTexts.notStarted(screenLanguage), result: model.buzzResult) {
                    Button(model.buzzPending ? WalkingCheckTexts.cancel(screenLanguage)
                                             : WalkingCheckTexts.sendTestNotification(screenLanguage)) {
                        if model.buzzPending { model.cancelBuzz() } else { Task { await model.startBuzz() } }
                    }
                }
                row(WalkingCheckTexts.liveActivity(screenLanguage), status: model.activityStatus ?? WalkingCheckTexts.notStarted(screenLanguage),
                    result: model.activityResult) {
                    Button(model.activityRunning ? WalkingCheckTexts.end(screenLanguage)
                                                 : WalkingCheckTexts.start(screenLanguage)) {
                        if model.activityRunning { model.endActivity() } else { Task { await model.startActivity() } }
                    }
                }
                row(WalkingCheckTexts.watch(screenLanguage), status: watchStatus, result: model.watchTellResult) {
                    Text(model.watchTellStatus ?? WalkingCheckTexts.noWatchTell(screenLanguage))
                        .font(Theme.Font.caption).opacity(0.75)
                }
            }
            .themedRows()
        }
        .themedList()
        .themedTitle(WalkingCheckTexts.title(screenLanguage))
    }

    private var watchStatus: String {
        WalkingCheckTexts.watchLink(paired: watch.isPaired, installed: watch.isInstalled, reachable: watch.isReachable,
                                    lastMessage: watch.lastReceived, screenLanguage)
    }

    /// The check mark (a symbol, never colour alone), the title, the status, the result and the row's control as a
    /// stone button (a secondary action).
    @ViewBuilder
    private func row(_ title: String, status: String, result: CheckResult?,
                     @ViewBuilder button: () -> some View) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.unit) {
            CheckMark(passed: result?.passed, passedText: SelfCheckTexts.passed(screenLanguage),
                      failedText: SelfCheckTexts.failed(screenLanguage), waitingText: SelfCheckTexts.waiting(screenLanguage))
            VStack(alignment: .leading, spacing: Theme.Spacing.unit / 2) {
                Text(title).font(Theme.Font.bodyMedium)
                Text(status).font(Theme.Font.caption).opacity(0.75)
                if let result {
                    Text(result.detail)
                        .font(Theme.Font.caption)
                        .foregroundStyle(result.passed ? Theme.Colour.text : Color.red)
                }
                button()
                    .buttonStyle(.themeSecondary)
            }
        }
        .padding(.vertical, Theme.Spacing.unit / 2)
    }
}
