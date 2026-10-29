import MyGuideCore
import SwiftUI

/// "Story timings" (spec 10): the median of each timing over the stored photo stories, and the last 20 with their date
/// and whether the nearby list was fresh. Only numbers: the file holds no story text and no photo.
struct StoryTimingsView: View {
    /// nil while the file is being read.
    @State private var entries: [PhotoTimingsEntry]?

    /// How many of the newest entries are listed one by one.
    static let recentCount = 20

    var body: some View {
        List {
            if let entries {
                if entries.isEmpty {
                    Text("No photo stories timed yet.")
                        .foregroundStyle(.secondary)
                } else {
                    medians(entries)
                    recent(entries)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Story timings")
        .task { entries = await AppServices.photoTimings() }
    }

    // MARK: - Medians

    private func medians(_ entries: [PhotoTimingsEntry]) -> some View {
        let timings = entries.map(\.timings)
        let fresh = timings.filter(\.listFresh).count
        return Section {
            row("Shutter to first step", milliseconds: timings.map(\.feedbackMs), of: timings.count)
            row("Shutter to likely place", milliseconds: timings.compactMap(\.guessMs), of: timings.count)
            row("Place search", milliseconds: timings.compactMap(\.placeSearchMs), of: timings.count)
            row("Article text", milliseconds: timings.compactMap(\.articleMs), of: timings.count)
            row("Request to first words", milliseconds: timings.compactMap(\.firstTextMs), of: timings.count)
            row("Request to complete story", milliseconds: timings.map(\.modelMs), of: timings.count)
            row("List age", value: PhotoTimingsLog.median(timings.compactMap(\.listAgeS)).map { "\($0) s" },
                count: timings.compactMap(\.listAgeS).count, of: timings.count)
            row("Article characters", value: PhotoTimingsLog.median(timings.map(\.articleChars)).map(String.init),
                count: timings.count, of: timings.count)
            LabeledContent("Fresh list", value: "\(fresh) of \(timings.count)")
        } header: {
            Text("Median of \(timings.count) \(timings.count == 1 ? "story" : "stories")")
        } footer: {
            Text("Each median is over the stories that have the value; the count is shown when some lack it.")
        }
    }

    private func row(_ label: String, milliseconds values: [Int], of total: Int) -> some View {
        row(label, value: PhotoTimingsLog.median(values).map { "\($0) ms" }, count: values.count, of: total)
    }

    private func row(_ label: String, value: String?, count: Int, of total: Int) -> some View {
        LabeledContent(label) {
            if let value {
                Text(count == total ? value : "\(value) (\(count))")
                    .monospacedDigit()
            } else {
                Text("—")
            }
        }
    }

    // MARK: - Recent

    private func recent(_ entries: [PhotoTimingsEntry]) -> some View {
        Section("Last \(min(Self.recentCount, entries.count))") {
            ForEach(Array(entries.suffix(Self.recentCount).reversed().enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.at, format: .dateTime.day().month(.abbreviated).hour().minute())
                        Spacer()
                        Text(listText(entry.timings))
                            .foregroundStyle(entry.timings.listFresh ? .primary : .secondary)
                    }
                    .font(.subheadline)
                    Text(details(entry.timings))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "fresh, 120 s old" / "not fresh, no list".
    private func listText(_ t: PhotoStoryTimings) -> String {
        let age = t.listAgeS.map { "\($0) s old" } ?? "no list"
        return "\(t.listFresh ? "fresh" : "not fresh"), \(age)"
    }

    /// The entry's timings in milliseconds on one line (a missing value is left out), then the article length.
    private func details(_ t: PhotoStoryTimings) -> String {
        var parts = ["step \(t.feedbackMs)"]
        if let v = t.guessMs { parts.append("guess \(v)") }
        if let v = t.placeSearchMs { parts.append("search \(v)") }
        if let v = t.articleMs { parts.append("article \(v)") }
        if let v = t.firstTextMs { parts.append("first words \(v)") }
        parts.append("story \(t.modelMs)")
        return "ms: " + parts.joined(separator: " · ") + " — article chars \(t.articleChars)"
    }
}
