import MyGuideCore
import SwiftUI
import os

/// The walk logs on this phone, newest first (spec 4.5). Swipe deletes a run's file, except the run in progress.
struct WalkLogListView: View {
    private struct Row: Identifiable, Sendable {
        let url: URL
        let isCurrent: Bool
        /// nil when the file could not be read.
        let summary: WalkLogSummary?
        var id: URL { url }
    }

    let services: AppServices

    @State private var rows: [Row] = []
    @State private var loaded = false
    @State private var errorText: String?

    var body: some View {
        List {
            if let errorText {
                Section { Text(errorText).font(.footnote).foregroundStyle(.red) }
            }
            if loaded && rows.isEmpty && errorText == nil {
                Section { Text("No walks logged yet").foregroundStyle(.secondary) }
            }
            ForEach(rows) { row in
                NavigationLink {
                    WalkLogRunView(url: row.url, isCurrent: row.isCurrent)
                } label: {
                    rowLabel(row)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if !row.isCurrent {
                        Button(role: .destructive) { delete(row) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
        }
        .navigationTitle("Walk log")
        .onAppear { refresh() }
    }

    @ViewBuilder private func rowLabel(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let summary = row.summary {
                if let start = summary.start {
                    Text(start.formatted(.dateTime.weekday().day().month().year().locale(.current)))
                    Text(timeSpan(summary, start: start))
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text(row.url.lastPathComponent)
                }
                Text("\(WalkLogFormat.duration(summary.duration)) · \(WalkLogFormat.distance(summary.distance)) · \(summary.buzzes) buzzes")
                    .font(.footnote).foregroundStyle(.secondary)
                if row.isCurrent {
                    Text("In progress").font(.footnote).foregroundStyle(.secondary)
                } else if summary.stopReason == nil {
                    Text("Ended without a stop").font(.footnote).foregroundStyle(.red)
                }
                if summary.failures > 0 {
                    Text("\(summary.failures) failures").font(.footnote).foregroundStyle(.red)
                }
            } else {
                Text(row.url.lastPathComponent)
                Text("Unreadable").font(.footnote).foregroundStyle(.red)
                if row.isCurrent {
                    Text("In progress").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
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
                        let summary = (try? Data(contentsOf: url)).map { data -> WalkLogSummary in
                            let read = WalkLogReader.read(data)
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
                    errorText = "Couldn't read the walk logs: \(error)"
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
            errorText = "Couldn't delete the walk log: \(error)"
        }
    }
}
