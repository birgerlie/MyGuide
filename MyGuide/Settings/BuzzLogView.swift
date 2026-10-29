import MyGuideCore
import SwiftUI

/// Every buzz walking mode has sent: counts per kind of place, the newest entries and a CSV export.
struct BuzzLogView: View {
    private static let shownLimit = 200

    let services: AppServices

    @State private var entries: [BuzzLogEntry] = []
    @State private var counts: [KindCount] = []
    @State private var exportURL: URL?
    @State private var errorText: String?
    /// The screen texts follow the iPhone's language (spec 17).
    private var screenLanguage: StoryLanguage { UILanguage.current }

    var body: some View {
        List {
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(Theme.Font.caption).foregroundStyle(.red)
                }
                .themedRows()
            }
            if entries.isEmpty && errorText == nil {
                Section { Text(SettingsTexts.noBuzzes(screenLanguage)).opacity(0.75) }
                    .themedRows()
            }
            if !counts.isEmpty {
                Section {
                    ForEach(counts, id: \.kind) { count in
                        VStack(alignment: .leading, spacing: Theme.Spacing.unit / 4) {
                            Text(count.kind)
                            Text(SettingsTexts.kindCounts(buzzes: count.buzzes, heard: count.heard,
                                                          skipped: count.skipped, ignored: count.ignored,
                                                          screenLanguage))
                                .font(Theme.Font.caption).opacity(0.75)
                        }
                    }
                } header: {
                    ListSectionHeader(SettingsTexts.byKind(screenLanguage))
                }
                .themedRows()
                Section {
                    // The kind and outcome are the log's own data.
                    ForEach(entries.prefix(Self.shownLimit), id: \.id) { entry in
                        VStack(alignment: .leading, spacing: Theme.Spacing.unit / 4) {
                            Text(entry.placeName)
                            Text("\(entry.at.formatted(date: .abbreviated, time: .shortened)) · \(entry.kind) · \(entry.outcome.rawValue)")
                                .font(Theme.Font.caption).opacity(0.75)
                        }
                    }
                } header: {
                    ListSectionHeader(SettingsTexts.newest(screenLanguage))
                } footer: {
                    if entries.count > Self.shownLimit {
                        ListSectionFooter(SettingsTexts.newestFooter(shown: Self.shownLimit, of: entries.count,
                                                                     screenLanguage))
                    }
                }
                .themedRows()
            }
        }
        .themedList()
        .themedTitle(SettingsTexts.buzzLog(screenLanguage))
        .toolbar {
            if let exportURL {
                ToolbarItem(placement: .primaryAction) { ShareLink(item: exportURL) }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        do {
            let log = try services.memory.buzzLog()
            entries = log
            counts = BuzzLogExport.counts(log)
            errorText = nil
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("MyGuide-buzz-log.csv")
            try BuzzLogExport.csv(log).write(to: url, atomically: true, encoding: .utf8)
            exportURL = url
        } catch {
            AppServices.logMemoryFailure("buzz log failed", error)
            errorText = SettingsTexts.buzzLogFailed(error, screenLanguage)
            exportURL = nil
        }
    }
}
