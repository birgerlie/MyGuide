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

    var body: some View {
        List {
            if let errorText {
                Section { Text(errorText).font(.footnote).foregroundStyle(.red) }
            }
            if entries.isEmpty && errorText == nil {
                Section { Text("No buzzes yet").foregroundStyle(.secondary) }
            }
            if !counts.isEmpty {
                Section("By kind") {
                    ForEach(counts, id: \.kind) { count in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(count.kind)
                            Text("\(count.buzzes) buzzes · \(count.heard) heard · \(count.skipped) skipped · \(count.ignored) ignored")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    ForEach(entries.prefix(Self.shownLimit), id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.placeName)
                            Text("\(entry.at.formatted(date: .abbreviated, time: .shortened)) · \(entry.kind) · \(entry.outcome.rawValue)")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Newest")
                } footer: {
                    if entries.count > Self.shownLimit {
                        Text("The newest \(Self.shownLimit) of \(entries.count). The export has them all.")
                    }
                }
            }
        }
        .navigationTitle("Buzz log")
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
            errorText = "Couldn't read or export the buzz log: \(error)"
            exportURL = nil
        }
    }
}
