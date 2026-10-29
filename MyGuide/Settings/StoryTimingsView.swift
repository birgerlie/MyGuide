import MyGuideCore
import SwiftUI

/// "Story timings" (spec 10, 13 check 3, 14.5): the nearby list's status (whether there is one in the story language,
/// its age, and its distance from the owner), the median of each timing over the stored photo stories, and the last
/// 20 with their date and whether the nearby list was fresh. Only numbers: the file holds no story text and no photo.
struct StoryTimingsView: View {
    /// nil while the file is being read.
    @State private var entries: [PhotoTimingsEntry]?
    /// The nearby list in the story language; `listLoaded` is false while it is being looked up.
    @State private var list: NearbyList?
    @State private var listLoaded = false
    /// Its own position source while the screen is open, for the list's distance; stopped when it closes.
    @State private var location = LocationProvider()
    private let language = AppServices.currentStoryLanguage()
    /// The words follow the iPhone's language (spec 17); `language` is the list's.
    private var screenLanguage: StoryLanguage { UILanguage.current }

    /// How many of the newest entries are listed one by one.
    static let recentCount = 20

    var body: some View {
        List {
            nearbyList
            if let entries {
                if entries.isEmpty {
                    Section {
                        Text(SettingsTexts.noTimings(screenLanguage))
                            .opacity(0.75)
                    }
                    .themedRows()
                } else {
                    medians(entries)
                    recent(entries)
                }
            } else {
                ProgressView()
                    .themedRows()
            }
        }
        .themedList()
        .themedTitle(SettingsTexts.storyTimings(screenLanguage))
        .task { entries = await AppServices.photoTimings() }
        .task {
            list = await AppServices.sharedNearby.current(language: language)
            listLoaded = true
        }
        .onAppear { location.start() }
        .onDisappear { location.stop() }
    }

    // MARK: - Nearby list

    /// Updated every second, so the age counts up while the screen is open.
    private var nearbyList: some View {
        Section {
            if !listLoaded {
                ProgressView()
            } else if let list {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let status = NearbyListStatus(list: list, position: location.fix(at: context.date)?.coordinate,
                                                  now: context.date)
                    VStack(spacing: Theme.Spacing.unit) {
                        LabeledContent(SettingsTexts.list(screenLanguage), value: SettingsTexts.yes(screenLanguage))
                        LabeledContent(SettingsTexts.age(screenLanguage), value: status.ageS.map { "\($0) s" } ?? "—")
                        LabeledContent(SettingsTexts.distanceFromYou(screenLanguage),
                                       value: status.distanceM.map { "\($0) m" } ?? "—")
                    }
                    .monospacedDigit()
                }
            } else {
                LabeledContent(SettingsTexts.list(screenLanguage), value: SettingsTexts.none(screenLanguage))
            }
        } header: {
            ListSectionHeader(SettingsTexts.nearbyListSection(listLanguage: language, screenLanguage))
        } footer: {
            ListSectionFooter(SettingsTexts.nearbyListFooter(screenLanguage))
        }
        .themedRows()
    }

    // MARK: - Medians

    private func medians(_ entries: [PhotoTimingsEntry]) -> some View {
        let timings = entries.map(\.timings)
        let fresh = timings.filter(\.listFresh).count
        return Section {
            row(SettingsTexts.startToFirstStep(screenLanguage), milliseconds: timings.map(\.feedbackMs),
                of: timings.count)
            row(SettingsTexts.startToLikelyPlace(screenLanguage), milliseconds: timings.compactMap(\.guessMs),
                of: timings.count)
            row(SettingsTexts.placeSearch(screenLanguage), milliseconds: timings.compactMap(\.placeSearchMs),
                of: timings.count)
            row(SettingsTexts.articleText(screenLanguage), milliseconds: timings.compactMap(\.articleMs),
                of: timings.count)
            row(SettingsTexts.requestToFirstWords(screenLanguage), milliseconds: timings.compactMap(\.firstTextMs),
                of: timings.count)
            row(SettingsTexts.requestToCompleteStory(screenLanguage), milliseconds: timings.map(\.modelMs),
                of: timings.count)
            row(SettingsTexts.speechRequest(screenLanguage), milliseconds: timings.compactMap(\.speechMs),
                of: timings.count)
            row(SettingsTexts.listAge(screenLanguage),
                value: PhotoTimingsLog.median(timings.compactMap(\.listAgeS)).map { "\($0) s" },
                count: timings.compactMap(\.listAgeS).count, of: timings.count)
            row(SettingsTexts.articleCharacters(screenLanguage),
                value: PhotoTimingsLog.median(timings.map(\.articleChars)).map(String.init),
                count: timings.count, of: timings.count)
            LabeledContent(SettingsTexts.freshList(screenLanguage),
                           value: SettingsTexts.countOf(fresh, timings.count, screenLanguage))
        } header: {
            ListSectionHeader(SettingsTexts.medianSection(timings.count, screenLanguage))
        } footer: {
            ListSectionFooter(SettingsTexts.medianFooter(screenLanguage))
        }
        .themedRows()
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
        Section {
            ForEach(Array(entries.suffix(Self.recentCount).reversed().enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: Theme.Spacing.unit / 2) {
                    HStack {
                        Text(entry.at, format: .dateTime.day().month(.abbreviated).hour().minute())
                        Spacer()
                        // The words say fresh or not; the dimming only repeats it.
                        Text(listText(entry.timings))
                            .opacity(entry.timings.listFresh ? 1 : 0.75)
                    }
                    .font(.custom(Theme.FontName.regular, size: 15, relativeTo: .subheadline))
                    Text(details(entry.timings))
                        .font(Theme.Font.caption.monospacedDigit())
                        .opacity(0.75)
                }
            }
        } header: {
            ListSectionHeader(SettingsTexts.lastSection(min(Self.recentCount, entries.count), screenLanguage))
        }
        .themedRows()
    }

    /// "fresh, 120 s old" / "not fresh, no list".
    private func listText(_ t: PhotoStoryTimings) -> String {
        SettingsTexts.listState(fresh: t.listFresh, ageS: t.listAgeS, screenLanguage)
    }

    /// The entry's timings in milliseconds on one line (a missing value is left out), then the article length.
    private func details(_ t: PhotoStoryTimings) -> String {
        let label = SettingsTexts.timingLabels(screenLanguage)
        var parts = ["\(label.step) \(t.feedbackMs)"]
        if let v = t.guessMs { parts.append("\(label.guess) \(v)") }
        if let v = t.placeSearchMs { parts.append("\(label.search) \(v)") }
        if let v = t.articleMs { parts.append("\(label.article) \(v)") }
        if let v = t.firstTextMs { parts.append("\(label.firstWords) \(v)") }
        parts.append("\(label.story) \(t.modelMs)")
        if let v = t.speechMs { parts.append("\(label.speech) \(v)") }
        return "ms: " + parts.joined(separator: " · ") + " — \(label.articleChars) \(t.articleChars)"
    }
}
