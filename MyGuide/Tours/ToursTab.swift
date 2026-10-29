import MyGuideCore
import SwiftUI
import UIKit

/// The «Turer» tab (tours spec 6): two cards, «Rundtur» with the duration chips and «Til et sted» with a destination
/// field (Apple Maps style suggestions), «Lag tur» with its progress line and cancel, and the preview pushed when a
/// tour is ready.
struct ToursTab: View {
    let model: TourBuilderModel
    let language: StoryLanguage
    /// «Start turen»: the seam to whatever starts a tour. HomeScreen passes it in; this screen only hands the routed
    /// tour over and closes the preview.
    let onStart: (RoutedTour) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.margin) {
                    Text(ToursTexts.tab(language))
                        .font(Theme.Font.display)
                        .accessibilityAddTraits(.isHeader)
                    LoopCard(model: model, language: language)
                    DestinationCard(model: model, search: model.search, language: language)
                    status
                    makeButton
                }
                .foregroundStyle(Theme.Colour.text)
                .padding(.horizontal, Theme.Spacing.margin)
                .padding(.vertical, Theme.Spacing.unit)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.Colour.background)
            .navigationTitle(ToursTexts.tab(language))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: previewShown) {
                TourPreviewView(model: model, language: language, onStart: onStart)
            }
        }
    }

    /// Pushed while the model shows a preview; popping it (back) closes the preview. `closePreview` ignores the pop
    /// SwiftUI reports when a new run replaced the preview.
    private var previewShown: Binding<Bool> {
        Binding(get: { model.preview != nil }, set: { shown in if !shown { model.closePreview() } })
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .planning(let step, let since):
            PlanningStatus(step: step, since: since, language: language, cancel: model.cancel)
        case .failed(let failure):
            FailureStatus(failure: failure, language: language, retry: model.makeTour)
        case .choosing, .preview:
            EmptyView()
        }
    }

    private var makeButton: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.unit) {
            Button(ToursTexts.makeTour(language)) {
                hideKeyboard()
                model.makeTour()
            }
            .buttonStyle(.themePrimary())
            .disabled(!model.canMakeTour)
            if model.mode == .destination, model.destination == nil {
                Text(ToursTexts.chooseDestinationFirst(language))
                    .font(Theme.Font.caption)
            }
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - Cards

/// A choosable card: ivory with a stone border, or, chosen, a forest border with a filled check (not colour alone).
private struct ModeCard<Content: View>: View {
    let title: String
    let detail: String
    let symbol: String
    let isChosen: Bool
    let choose: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: choose) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.custom(Theme.FontName.display, size: 22, relativeTo: .title3))
                        Text(detail).font(Theme.Font.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                }
                .contentShape(Rectangle())
                .frame(minHeight: Theme.minimumTouchHeight)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isChosen ? .isSelected : [])
            if isChosen { content() }
        }
        .foregroundStyle(Theme.Colour.text)
        .padding(Theme.Spacing.margin)
        .background(Theme.Colour.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(isChosen ? Theme.Colour.text : Theme.Colour.stone, lineWidth: isChosen ? 2 : 1))
    }
}

/// «Rundtur» with the six duration chips, three to a row.
private struct LoopCard: View {
    @Bindable var model: TourBuilderModel
    let language: StoryLanguage

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.unit), count: 3)

    var body: some View {
        ModeCard(title: ToursTexts.loopTitle(language), detail: ToursTexts.loopDetail(language),
                 symbol: "arrow.triangle.2.circlepath", isChosen: model.mode == .loop,
                 choose: { model.mode = .loop }) {
            LazyVGrid(columns: columns, spacing: Theme.Spacing.unit) {
                ForEach(TourBuilderModel.durations, id: \.self) { minutes in
                    chip(minutes)
                }
            }
            .disabled(model.isPlanning)
            .accessibilityLabel(ToursTexts.durationLabel(language))
        }
    }

    private func chip(_ minutes: Int) -> some View {
        let chosen = model.minutes == minutes
        return Button {
            model.minutes = minutes
        } label: {
            HStack(spacing: 4) {
                if chosen {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                }
                Text(ToursTexts.duration(minutes: minutes, language))
                    .font(chosen ? Theme.Font.bodyMedium : Theme.Font.body)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(Theme.Colour.forest)
            .frame(maxWidth: .infinity, minHeight: Theme.minimumTouchHeight)
            .background(chosen ? Theme.Colour.coral : Theme.Colour.stone, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// «Til et sted» with the search field, its suggestions, and the chosen destination.
private struct DestinationCard: View {
    @Bindable var model: TourBuilderModel
    @Bindable var search: DestinationSearch
    let language: StoryLanguage

    @State private var resolving: Task<Void, Never>?
    @State private var resolvingID: Int?
    @State private var notFound = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ModeCard(title: ToursTexts.destinationTitle(language), detail: ToursTexts.destinationDetail(language),
                 symbol: "flag.checkered", isChosen: model.mode == .destination,
                 choose: chooseMode) {
            VStack(alignment: .leading, spacing: Theme.Spacing.unit) {
                field
                if let destination = model.destination, destination.name == search.query {
                    Label(ToursTexts.chosenDestination(destination.name, language), systemImage: "checkmark.circle.fill")
                        .font(Theme.Font.bodyMedium)
                } else {
                    suggestions
                }
                if notFound {
                    Label(ToursTexts.destinationNotFound(language), systemImage: "exclamationmark.circle")
                        .font(Theme.Font.caption)
                }
            }
            .disabled(model.isPlanning)
        }
        .onChange(of: search.query) { _, query in
            notFound = false
            // Editing the text after choosing un-chooses the destination.
            if let destination = model.destination, destination.name != query { model.destination = nil }
        }
        .onDisappear { resolving?.cancel() }
    }

    private func chooseMode() {
        model.mode = .destination
        model.biasSearch()
        if model.destination == nil { fieldFocused = true }
    }

    private var field: some View {
        HStack(spacing: Theme.Spacing.unit) {
            Image(systemName: "magnifyingglass")
                .accessibilityHidden(true)
            TextField(ToursTexts.searchPlaceholder(language), text: $search.query)
                .font(Theme.Font.body)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($fieldFocused)
            if !search.query.isEmpty {
                Button {
                    search.clear()
                    model.destination = nil
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: Theme.minimumTouchHeight, height: Theme.minimumTouchHeight)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ToursTexts.clearSearch(language))
            }
        }
        .padding(.leading, 12)
        .frame(minHeight: Theme.minimumTouchHeight)
        .background(Theme.Colour.stone.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var suggestions: some View {
        switch search.status {
        case .idle:
            EmptyView()
        case .noResults:
            Text(ToursTexts.noResults(language)).font(Theme.Font.caption)
        case .failed:
            Label(ToursTexts.searchFailed(language), systemImage: "wifi.exclamationmark")
                .font(Theme.Font.caption)
        case .results:
            VStack(spacing: 0) {
                ForEach(search.suggestions) { suggestion in
                    Button { pick(suggestion) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title).font(Theme.Font.bodyMedium)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle).font(Theme.Font.caption).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if resolvingID == suggestion.id { ProgressView().tint(Theme.Colour.text) }
                        }
                        .padding(.vertical, Theme.Spacing.unit)
                        .frame(minHeight: Theme.minimumTouchHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if suggestion.id != search.suggestions.last?.id {
                        Divider().overlay(Theme.Colour.stone)
                    }
                }
            }
        }
    }

    private func pick(_ suggestion: DestinationSearch.Suggestion) {
        resolving?.cancel()
        resolvingID = suggestion.id
        notFound = false
        resolving = Task {
            let destination = await search.resolve(suggestion)
            guard !Task.isCancelled else { return }
            resolvingID = nil
            guard let destination else {
                notFound = true
                return
            }
            fieldFocused = false
            // Destination first, so the query change below finds the names equal and keeps it.
            model.destination = destination
            search.query = destination.name
        }
    }
}

// MARK: - Status

/// «Finner steder …» / «Lager rute …» with a spinner and «Avbryt»; after 10 s of routing, why it takes time.
private struct PlanningStatus: View {
    let step: TourBuilderModel.Step
    let since: Date
    let language: StoryLanguage
    let cancel: () -> Void

    /// Routing slower than this explains itself.
    private static let slowRouting: TimeInterval = 10

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.unit) {
            HStack(spacing: 12) {
                ProgressView().tint(Theme.Colour.text)
                Text(text).font(Theme.Font.bodyMedium)
                Spacer(minLength: Theme.Spacing.unit)
                Button(ToursTexts.cancel(language), action: cancel)
                    .font(Theme.Font.bodyMedium)
                    .frame(minHeight: Theme.minimumTouchHeight)
            }
            if step == .routing {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    if context.date.timeIntervalSince(since) >= Self.slowRouting {
                        Text(ToursTexts.routingTakesTime(language)).font(Theme.Font.caption)
                    }
                }
            }
        }
        .padding(Theme.Spacing.margin)
        .background(Theme.Colour.stone.opacity(0.45), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var text: String {
        switch step {
        case .locating: ToursTexts.locating(language)
        case .findingPlaces: ToursTexts.findingPlaces(language)
        case .routing: ToursTexts.routing(language)
        }
    }
}

/// Why no tour came, in words with a symbol, and what to do about it.
private struct FailureStatus: View {
    let failure: TourBuilderModel.Failure
    let language: StoryLanguage
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).frame(width: 24)
                Text(text).font(Theme.Font.body).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            if failure == .locationDenied {
                Button(ToursTexts.openSettings(language)) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.themeSecondary)
            } else {
                Button(ToursTexts.tryAgain(language), action: retry)
                    .buttonStyle(.themeSecondary)
            }
        }
        .padding(Theme.Spacing.margin)
        .background(Theme.Colour.stone.opacity(0.45), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var symbol: String {
        switch failure {
        case .locationDenied: "location.slash"
        case .noPosition: "location.magnifyingglass"
        case .placesFailed: "wifi.exclamationmark"
        }
    }

    private var text: String {
        switch failure {
        case .locationDenied: ToursTexts.locationDenied(language)
        case .noPosition: ToursTexts.noPosition(language)
        case .placesFailed: ToursTexts.placesFailed(language)
        }
    }
}
