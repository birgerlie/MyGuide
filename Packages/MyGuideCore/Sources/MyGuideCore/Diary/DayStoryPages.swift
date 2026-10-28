import Foundation

/// What the day story screen shows (spec 5.4): a summary page, then one page per photo that is still kept.
public struct DayStoryPages: Sendable, Equatable {
    public struct Photo: Sendable, Equatable, Identifiable {
        /// `capture:<uuid>` or `library:<uuid>`.
        public var id: String
        public var time: Date
        /// Nil when the story has no caption for the photo, or only a blank one.
        public var caption: String?

        public init(id: String, time: Date, caption: String?) {
            self.id = id
            self.time = time
            self.caption = caption
        }
    }

    public var summary: String
    /// "12 of 20 photos" when the story was written from fewer than all the day's photos; nil otherwise.
    public var countNote: String?
    /// The story's page order. Photos no longer kept are left out (spec 5.3), and a repeated id gets one page.
    /// The first is the summary page's background.
    public var photos: [Photo]

    /// `photoTimes` holds every photo still kept, id to the time it was taken.
    public init(story: DayStory, photoTimes: [String: Date]) {
        summary = story.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        // Counted from the story as written, not from the pages left: it says what the summary was written from.
        let sent = story.photoIDs.count
        countNote = story.totalPhotos > sent ? "\(sent) of \(story.totalPhotos) photos" : nil
        var seen: Set<String> = []
        photos = story.photoIDs.compactMap { id in
            guard let time = photoTimes[id], seen.insert(id).inserted else { return nil }
            let caption = story.captions[id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Photo(id: id, time: time, caption: caption?.isEmpty == false ? caption : nil)
        }
    }
}

/// A diary photo id taken apart: `capture:<uuid>` or `library:<uuid>`.
public enum DiaryPhotoID: Sendable, Equatable {
    case capture(UUID)
    case library(UUID)

    /// Nil for any other prefix (prefixes are case-sensitive) or a malformed UUID.
    public init?(_ id: String) {
        guard let colon = id.firstIndex(of: ":"), let uuid = UUID(uuidString: String(id[id.index(after: colon)...]))
        else { return nil }
        switch id[..<colon] {
        case "capture": self = .capture(uuid)
        case "library": self = .library(uuid)
        default: return nil
        }
    }
}

extension Diary {
    /// The start of the day named by a `yyyy-MM-dd` key in `timeZone`; nil for anything `dayKey` would not produce,
    /// such as 2026-02-30.
    public static func startOfDay(dayKey key: String, timeZone: TimeZone) -> Date? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        let calendar = calendar(timeZone)
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        // The calendar rolls 30 February over into March; the round trip catches it.
        let start = calendar.startOfDay(for: date)
        return dayKey(start, timeZone: timeZone) == key ? start : nil
    }
}
