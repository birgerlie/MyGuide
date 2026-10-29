import MyGuideCore
import SwiftUI
import os

/// The walk logs on this phone, newest first (spec 4.5). Swipe deletes a run's file, except the run in progress.
struct WalkLogListView: View {
    private struct Row: Identifiable, Sendable {
        let url: URL
        let isCurrent: Bool
        /// nil when the file could not be read, or holds no readable event but unreadable lines.
        let summary: WalkLogSummary?
        var id: URL { url }
    }

    let services: AppServices

    @State private var rows: [Row] = []
    @State private var loaded = false
    @State private var errorText: String?
    @AppStorage(AppServices.storyLanguageKey) private var storyLanguage: StoryLanguage = .english

    var body: some View {
        List {
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(Theme.Font.caption).foregroundStyle(.red)
                }
                .themedRows()
            }
            if loaded && rows.isEmpty && errorText == nil {
                Section { Text(SettingsTexts.noWalks(storyLanguage)).opacity(0.75) }
                    .themedRows()
            }
            ForEach(rows) { row in
                NavigationLink {
                    WalkLogRunView(url: row.url, isCurrent: row.isCurrent)
                } label: {
                    rowLabel(row)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if !row.isCurrent {
                        Button(role: .destructive) { delete(row) } label: {
                            Label(SettingsTexts.delete(storyLanguage), systemImage: "trash")
                        }
                    }
                }
            }
            .themedRows()
        }
        .themedList()
        .themedTitle(SettingsTexts.walkLog(storyLanguage))
        .onAppear { refresh() }
    }

    @ViewBuilder private func rowLabel(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.unit / 4) {
            if let summary = row.summary {
                if let start = summary.start {
                    Text(start.formatted(.dateTime.weekday().day().month().year().locale(.current)))
                        .font(Theme.Font.bodyMedium)
                    Text(timeSpan(summary, start: start))
                        .font(Theme.Font.caption).opacity(0.75)
                } else {
                    Text(row.url.lastPathComponent)
                }
                Text(SettingsTexts.walkLine(duration: WalkLogFormat.duration(summary.duration),
                                            distance: WalkLogFormat.distance(summary.distance),
                                            buzzes: summary.buzzes, storyLanguage))
                    .font(Theme.Font.caption).opacity(0.75)
                if row.isCurrent {
                    Text(SettingsTexts.inProgress(storyLanguage)).font(Theme.Font.caption).opacity(0.75)
                } else if summary.stopReason == nil {
                    problem(SettingsTexts.endedWithoutStop(storyLanguage))
                }
                if summary.failures > 0 {
                    problem(SettingsTexts.failures(summary.failures, storyLanguage))
                }
            } else {
                Text(row.url.lastPathComponent)
                problem(SettingsTexts.unreadable(storyLanguage))
                if row.isCurrent {
                    Text(SettingsTexts.inProgress(storyLanguage)).font(Theme.Font.caption).opacity(0.75)
                }
            }
        }
    }

    /// A problem in red with a warning symbol, so it never rests on colour alone.
    private func problem(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(Theme.Font.caption)
            .foregroundStyle(.red)
    }

    private func timeSpan(_ summary: WalkLogSummary, start: Date) -> String {
        let from = WalkLogFormat.time(start)
        guard let end = summary.end else { return from }
        return "\(from)–\(WalkLogFormat.time(end))"
    }

    private func refresh() {
        let current = services.walkLog.currentURL
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[Row], Error> in
                do {
                    let urls = try WalkLogStore.runFiles(in: WalkLog.directory)
                    return .success(urls.map { url in
                        // A file with lines but not one readable event cannot be parsed at all (spec 6): "Unreadable".
                        let summary = (try? Data(contentsOf: url)).flatMap { data -> WalkLogSummary? in
                            let read = WalkLogReader.read(data)
                            if read.events.isEmpty, read.unreadable > 0 { return nil }
                            return WalkLogSummary(events: read.events, unreadable: read.unreadable)
                        }
                        return Row(url: url, isCurrent: url == current, summary: summary)
                    })
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let found):
                rows = found
                errorText = nil
            case .failure(let error):
                // A missing directory just means no run has been logged yet.
                if (error as? CocoaError)?.code == .fileReadNoSuchFile {
                    rows = []
                    errorText = nil
                } else {
                    WalkLog.logger.error("walk log list failed: \(String(describing: error), privacy: .public)")
                    errorText = SettingsTexts.walkLogsFailed(error, storyLanguage)
                }
            }
            loaded = true
        }
    }

    private func delete(_ row: Row) {
        guard !row.isCurrent, row.url != services.walkLog.currentURL else { return }
        do {
            try FileManager.default.removeItem(at: row.url)
            rows.removeAll { $0.url == row.url }
            errorText = nil
        } catch {
            WalkLog.logger.error("walk log delete failed: \(String(describing: error), privacy: .public)")
            errorText = SettingsTexts.walkLogDeleteFailed(error, storyLanguage)
        }
    }
}
