import Foundation

/// One line of the diary: a photo story, a heard buzz story, a stop story or an imported library photo.
public struct DiaryEntry: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case photoStory, buzz, stop, libraryPhoto }

    /// `capture:<uuid>`, `walk:<uuid>` or `library:<uuid>`.
    public var id: String
    public var kind: Kind
    public var time: Date
    /// Capture title or walk story title; empty for library photos.
    public var title: String
    /// The buzz's place name or the capture's subject.
    public var placeName: String?
    /// Buzz: the place; stop: where the story was made; photo story and library photo: where the photo was taken.
    /// Nil when unknown (a library photo without a location, or a stored place that cannot be read back).
    public var coordinate: Coordinate?
    /// `RecentStories.firstSentence` of level 1; nil for library photos and for a story without a level 1.
    public var firstSentence: String?
    /// `Address.city` when known.
    public var city: String?
    /// Photo stories and library photos.
    public var hasPhoto: Bool
    /// A `.buzz` entry whose story the walker chose on the map rather than a buzz offered; it is listed and grouped
    /// like a buzz and only labelled apart. False for every other entry.
    public var isChosen: Bool

    public init(id: String, kind: Kind, time: Date, title: String, placeName: String?, coordinate: Coordinate?,
                firstSentence: String?, city: String?, hasPhoto: Bool, isChosen: Bool = false) {
        self.id = id
        self.kind = kind
        self.time = time
        self.title = title
        self.placeName = placeName
        self.coordinate = coordinate
        self.firstSentence = firstSentence
        self.city = city
        self.hasPhoto = hasPhoto
        self.isChosen = isChosen
    }
}

/// The entries of one local day.
public struct DiaryDay: Sendable, Equatable, Identifiable {
    /// `Diary.dayKey`.
    public var id: String
    /// Start of the day in the time zone it was grouped in.
    public var date: Date
    /// The city of the day's first entry (by time) that has one.
    public var city: String?
    /// Oldest first.
    public var entries: [DiaryEntry]

    public init(id: String, date: Date, city: String?, entries: [DiaryEntry]) {
        self.id = id
        self.date = date
        self.city = city
        self.entries = entries
    }
}

public enum Diary {
    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// `yyyy-MM-dd` of `date` in `timeZone`, on the Gregorian calendar.
    public static func dayKey(_ date: Date, timeZone: TimeZone) -> String {
        let parts = calendar(timeZone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Newest day first; entries oldest first, ties by id. A day's city is that of its first entry (by time) with one.
    public static func days(_ entries: [DiaryEntry], timeZone: TimeZone) -> [DiaryDay] {
        let calendar = calendar(timeZone)
        let grouped = Dictionary(grouping: entries) { dayKey($0.time, timeZone: timeZone) }
        return grouped.map { key, group in
            let sorted = group.sorted { ($0.time, $0.id) < ($1.time, $1.id) }
            return DiaryDay(id: key, date: calendar.startOfDay(for: sorted[0].time),
                            city: sorted.lazy.compactMap(\.city).first, entries: sorted)
        }
        // Zero-padded keys sort as dates.
        .sorted { $0.id > $1.id }
    }
}
