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

/// Weekday, date and city, with the button to the day's story (enabled when the day has a photo).
struct DiaryDayHeader: View {
    let day: DiaryDay
    let openDayStory: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let city = day.city, !city.isEmpty {
                    Text(city).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button("Day story", systemImage: "book.pages", action: openDayStory)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!day.entries.contains(where: \.hasPhoto))
        }
        .textCase(nil)
    }
}

/// One diary line. Photo story: thumbnail, title, time. Buzz: walking icon, title, place, time. Stop: pin icon,
/// title, time. Library photo: thumbnail, time and its day-story caption when there is one.
struct DiaryRow: View {
    let entry: DiaryEntry
    let caption: String?
    /// The stored thumbnail of a photo story or library photo; nil when it is gone or unreadable.
    let loadThumbnail: (DiaryEntry) -> UIImage?

    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                switch entry.kind {
                case .photoStory, .stop:
                    Text(entry.title).font(.headline).lineLimit(2)
                case .buzz:
                    Text(entry.title).font(.headline).lineLimit(2)
                    if let place = entry.placeName, !place.isEmpty {
                        Text(place).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                case .libraryPhoto:
                    if let caption, !caption.isEmpty {
                        Text(caption).font(.subheadline).lineLimit(3)
                    }
                }
                Text(entry.time.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
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
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 56, height: 56)
            }
        case .buzz:
            icon("figure.walk")
        case .stop:
            icon("mappin.and.ellipse")
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.title3)
            .foregroundStyle(.tint)
            .frame(width: 56, height: 56)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var accessibilityText: String {
        let time = entry.time.formatted(date: .omitted, time: .shortened)
        switch entry.kind {
        case .photoStory: return "Photo story, \(entry.title), \(time)"
        case .buzz: return "Walk story, \(entry.title)\(entry.placeName.map { ", \($0)" } ?? ""), \(time)"
        case .stop: return "Stop story, \(entry.title), \(time)"
        case .libraryPhoto: return "Photo, \(time)\(caption.map { ", \($0)" } ?? "")"
        }
    }
}
