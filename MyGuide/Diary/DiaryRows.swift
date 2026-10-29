import MyGuideCore
import SwiftUI
import UIKit

extension DiaryEntry {
    /// The record's id: the part after the `capture:`, `walk:` or `library:` prefix.
    var recordID: UUID? {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        return UUID(uuidString: String(id[id.index(after: colon)...]))
    }
}

/// Weekday and date in Playfair (the day is the heading), the city under it, and the stone button to the day's story
/// (enabled when the day has a photo).
struct DiaryDayHeader: View {
    let day: DiaryDay
    let language: StoryLanguage
    let openDayStory: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.margin) {
            VStack(alignment: .leading, spacing: Theme.Spacing.unit / 2) {
                Text(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                    .font(.custom(Theme.FontName.display, size: 20, relativeTo: .headline))
                    .accessibilityAddTraits(.isHeader)
                if let city = day.city, !city.isEmpty {
                    Text(city)
                        .font(Theme.Font.caption)
                        .opacity(0.75)
                }
            }
            Spacer(minLength: 0)
            Button(action: openDayStory) {
                Label(DiaryTexts.dayStoryButton(language), systemImage: "book.pages")
                    .font(.custom(Theme.FontName.medium, size: 15, relativeTo: .subheadline))
                    .foregroundStyle(Theme.Colour.forest)
                    .padding(.horizontal, Theme.Spacing.margin - 4)
                    .frame(minHeight: Theme.minimumTouchHeight)
                    .background(Theme.Colour.stone, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(!hasPhoto)
            .opacity(hasPhoto ? 1 : 0.5)
        }
        .foregroundStyle(Theme.Colour.text)
        .textCase(nil)
        .padding(.vertical, Theme.Spacing.unit / 2)
    }

    private var hasPhoto: Bool { day.entries.contains(where: \.hasPhoto) }
}

/// One diary line. Photo story: thumbnail, title, time. Buzz: walking icon, title, place, time; a story chosen on the
/// map has the map icon and «Valgt på kartet» under its place. Stop: pin icon, title, time. Library photo: thumbnail, time and its day-story caption when there is one.
struct DiaryRow: View {
    let entry: DiaryEntry
    let caption: String?
    let language: StoryLanguage
    /// The stored thumbnail of a photo story or library photo; nil when it is gone or unreadable.
    let loadThumbnail: (DiaryEntry) -> UIImage?

    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: Theme.Spacing.unit + 4) {
            leading
            VStack(alignment: .leading, spacing: Theme.Spacing.unit / 4) {
                switch entry.kind {
                case .photoStory, .stop:
                    Text(entry.title).font(Theme.Font.bodyMedium).lineLimit(2)
                case .buzz:
                    Text(entry.title).font(Theme.Font.bodyMedium).lineLimit(2)
                    if let place = entry.placeName, !place.isEmpty {
                        Text(place).font(Theme.Font.caption).opacity(0.75).lineLimit(1)
                    }
                    if entry.isChosen {
                        Text(DiaryTexts.chosenOnMap(language)).font(Theme.Font.caption).opacity(0.75).lineLimit(1)
                    }
                case .libraryPhoto:
                    if let caption, !caption.isEmpty {
                        Text(caption).font(Theme.Font.body).lineLimit(3)
                    }
                }
                Text(entry.time.formatted(date: .omitted, time: .shortened))
                    .font(Theme.Font.caption)
                    .opacity(0.75)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: Theme.minimumTouchHeight)
        .foregroundStyle(Theme.Colour.text)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .task(id: entry.id) {
            guard entry.hasPhoto else { return }
            thumbnail = loadThumbnail(entry)
        }
    }

    @ViewBuilder
    private var leading: some View {
        switch entry.kind {
        case .photoStory, .libraryPhoto:
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.Colour.stone)
                    .frame(width: 56, height: 56)
            }
        case .buzz:
            // A chosen story keeps the walk's look, with the map's symbol: the icon is never its only sign.
            icon(entry.isChosen ? "map" : "figure.walk")
        case .stop:
            icon("mappin.and.ellipse")
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(Theme.Colour.forest)
            .frame(width: 56, height: 56)
            .background(Theme.Colour.stone, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var accessibilityText: String {
        DiaryTexts.rowLabel(kind: entry.kind, isChosen: entry.isChosen, title: entry.title, place: entry.placeName,
                            caption: caption, time: entry.time.formatted(date: .omitted, time: .shortened), language)
    }
}
