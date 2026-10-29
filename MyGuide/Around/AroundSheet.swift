import CoreLocation
import MyGuideCore
import SwiftUI

/// A story from History for «Sist oppdaget» (spec 16.3).
struct RecentStory: Identifiable, Equatable {
    enum Source: Hashable {
        case photo(UUID)
        case walk(UUID)
    }

    let source: Source
    let title: String
    let date: Date

    var id: Source { source }

    /// The newest `limit` of both kinds, newest first.
    static func newest(photos: [(id: UUID, title: String, at: Date)], walks: [(id: UUID, title: String, at: Date)],
                       limit: Int) -> [RecentStory] {
        let all = photos.map { RecentStory(source: .photo($0.id), title: $0.title, date: $0.at) }
            + walks.map { RecentStory(source: .walk($0.id), title: $0.title, date: $0.at) }
        return Array(all.sorted { $0.date > $1.date }.prefix(limit))
    }
}

/// The ivory sheet over the bottom of the map (spec 14, 16.3): a grabber, «Rundt deg» in Playfair with the list's
/// age when it is old, the place card (or the state in words), and «Gå en tur», or the walking panel while a walk
/// runs. Dragged or tapped open it adds the places nearby, nearest first (a tap selects one; this list is also how
/// VoiceOver reaches the markers), and «Sist oppdaget» when there are stories.
struct AroundSheet: View {
    let model: AroundModel
    let walking: WalkingController
    let placeImages: PlaceImages
    let memoryFallback: MemoryFallback?
    let authorization: CLAuthorizationStatus
    let language: StoryLanguage
    let recent: [RecentStory]
    @Binding var isExpanded: Bool
    /// The most the expanded lists may take, so the sheet never covers the whole map.
    let maxListHeight: CGFloat
    let openSelected: () -> Void
    let openCamera: () -> Void
    let openRecent: (RecentStory) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let corner: CGFloat = 24
    /// A drag of at least this many points opens or closes the sheet.
    private static let dragThreshold: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.margin) {
            header
            if let memoryFallback {
                // Rounded, not a capsule: the background-launch text wraps over two or three lines.
                MemoryUnavailableNotice(fallback: memoryFallback).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            card
            walkSection
            if isExpanded {
                ScrollView {
                    expandedLists
                }
                .frame(maxHeight: max(maxListHeight, 0))
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(.horizontal, Theme.Spacing.wideMargin)
        .padding(.bottom, Theme.Spacing.margin)
        .foregroundStyle(Theme.Colour.text)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: Self.corner, topTrailingRadius: Self.corner, style: .continuous)
                .fill(Theme.Colour.background)
                .shadow(color: .black.opacity(0.12), radius: 8, y: -2)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: - Header

    /// The grabber and the title; a drag here or a tap on the grabber opens or closes the sheet.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                Capsule()
                    .fill(Theme.Colour.stone)
                    .frame(width: 40, height: 5)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? AroundTexts.showLess(language) : AroundTexts.showMore(language))
            Text(AroundTexts.title(language))
                .font(Theme.Font.display)
                .accessibilityAddTraits(.isHeader)
            if let age = AroundText.listAgeLine(seconds: model.listAge, language: language) {
                Label(age, systemImage: "clock")
                    .font(Theme.Font.caption)
                    .opacity(0.75)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    let dy = value.translation.height
                    if dy < -Self.dragThreshold, !isExpanded { toggle() }
                    if dy > Self.dragThreshold, isExpanded { toggle() }
                }
        )
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) { isExpanded.toggle() }
    }

    // MARK: - Card

    @ViewBuilder
    private var card: some View {
        switch AroundCardState.of(model, authorization: authorization) {
        case .selected(let selected):
            AroundPlaceCard(selected: selected, stories: walking.stories, placeImages: placeImages,
                            language: language, listen: model.listen, open: openSelected, takePhoto: openCamera)
                // A new place is a new card: its picture state starts empty, so the old picture never shows with the
                // new name.
                .id(selected.vector.place.candidate.id)
        case let state:
            AroundCardStateView(state: state, language: language, takePhoto: openCamera)
        }
    }

    // MARK: - Walking

    /// Off: «Gå en tur» starts a walk. Running: the walking panel. Paused (spec 16.4): «Fortsett turen» resumes the
    /// walk already there (never a second one), with its status under it and a quiet way to end it.
    @ViewBuilder
    private var walkSection: some View {
        if walking.isOn, !walking.isPaused {
            WalkingPanel(walking: walking, language: language)
        } else {
            VStack(spacing: Theme.Spacing.unit) {
                walkButton
                if walking.isOn {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if let status = WalkingStatus.text(isOn: true, lastFixAt: walking.lastFixAt,
                                                           buzzCount: walking.buzzCount, now: context.date,
                                                           pause: walking.pauseKind, language: language) {
                            Label(status, systemImage: "pause.circle")
                                .font(.custom(Theme.FontName.regular, size: 15, relativeTo: .subheadline))
                                .opacity(0.75)
                        }
                    }
                    Button(AroundTexts.stopWalk(language)) { walking.stop() }
                        .font(Theme.Font.bodyMedium)
                        .underline()
                        .buttonStyle(.plain)
                        .frame(minHeight: Theme.minimumTouchHeight)
                } else {
                    Text(AroundTexts.walkLine(language))
                        .font(.custom(Theme.FontName.regular, size: 15, relativeTo: .subheadline))
                        .multilineTextAlignment(.center)
                        .opacity(0.75)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        // The first thing that keeps walking mode from starting, or that it lacks while on (e.g. location Always).
        if let problem = walking.problems.first {
            Label(problem.text(language), systemImage: "exclamationmark.triangle")
                .font(Theme.Font.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The wide coral button: «Gå en tur» starts walking mode; while a walk is paused, «Fortsett turen» resumes it.
    private var walkButton: some View {
        let paused = walking.isOn
        return Button {
            if paused {
                walking.resume(source: .phone)
            } else {
                Task { await walking.start() }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: paused ? "play.fill" : "figure.walk")
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityHidden(true)
                Text(paused ? AroundTexts.continueWalk(language) : AroundTexts.goForAWalk(language))
                    .font(.custom(Theme.FontName.medium, size: 20, relativeTo: .title3))
                Spacer(minLength: 0)
                if walking.isStarting {
                    ProgressView().tint(Theme.Colour.forest)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 17, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 56)
        }
        .buttonStyle(.themePrimary(.coral))
        .disabled(walking.isStarting)
    }

    // MARK: - Expanded

    private var expandedLists: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.unit) {
            let places = nearbyPlaces
            if !places.isEmpty {
                sectionLabel(AroundTexts.nearbyPlaces(language))
                ForEach(places, id: \.place.candidate.id) { entry in
                    placeRow(entry.place.candidate, distance: entry.distance)
                }
            }
            if !recent.isEmpty {
                if !places.isEmpty { divider.padding(.vertical, Theme.Spacing.unit) }
                sectionLabel(AroundTexts.recentlyDiscovered(language))
                ForEach(recent) { story in
                    recentRow(story)
                }
            }
        }
        .padding(.bottom, Theme.Spacing.unit)
    }

    /// Nearest first from the owner's position; without one, in list order with no distance.
    private var nearbyPlaces: [(place: WalkingPlace, distance: Double?)] {
        guard let position = model.position else { return model.places.map { ($0, nil) } }
        return model.places.enumerated()
            .map { (index: $0.offset, place: $0.element, distance: GeoMath.distance(position, $0.element.candidate.coordinate)) }
            .sorted { ($0.distance, $0.index) < ($1.distance, $1.index) }
            .map { ($0.place, $0.distance) }
    }

    private var selectedID: String? {
        if case .selected(let selected) = model.selection { return selected.vector.place.candidate.id }
        return nil
    }

    private func placeRow(_ candidate: Candidate, distance: Double?) -> some View {
        let isSelected = candidate.id == selectedID
        return Button {
            model.choose(candidate.id)
            toggle()
        } label: {
            HStack(spacing: 12) {
                PlaceSymbolTile(symbol: PlaceSymbol.systemName(for: candidate), size: 36)
                Text(candidate.name)
                    .font(isSelected ? Theme.Font.bodyMedium : Theme.Font.body)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let distance {
                    Text(AroundTexts.distance(distance))
                        .font(Theme.Font.caption)
                        .opacity(0.75)
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: Theme.minimumTouchHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rowLabel(candidate.name, distance: distance, isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func rowLabel(_ name: String, distance: Double?, isSelected: Bool) -> String {
        let named = AroundTexts.markerLabel(name, isSelected: isSelected, language)
        guard let distance else { return named }
        return "\(named), \(AroundTexts.distance(distance))"
    }

    private func recentRow(_ story: RecentStory) -> some View {
        Button {
            openRecent(story)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: story.isPhoto ? "camera" : "figure.walk")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Theme.Colour.stone, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(Theme.Colour.forest)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(story.title)
                        .font(Theme.Font.body)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(story.date.formatted(date: .abbreviated, time: .shortened))
                        .font(Theme.Font.caption)
                        .opacity(0.75)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .opacity(0.5)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Theme.minimumTouchHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    /// Small spaced capitals, as on the story screen.
    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.custom(Theme.FontName.medium, size: 13, relativeTo: .caption))
            .tracking(1.6)
            .opacity(0.75)
            .padding(.top, Theme.Spacing.unit)
            .accessibilityAddTraits(.isHeader)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.Colour.stone)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

private extension RecentStory {
    var isPhoto: Bool {
        if case .photo = source { return true }
        return false
    }
}
