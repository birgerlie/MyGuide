import Foundation

/// A photo a day story can caption: a library photo or a photo story's photo.
public struct DayStoryPhoto: Sendable, Equatable {
    /// `library:<uuid>` or `capture:<uuid>`.
    public var id: String
    public var time: Date
    public var coordinate: Coordinate?
    public var kind: Kind

    public enum Kind: Sendable, Equatable {
        /// Imported from the library; matched to an event by time and place.
        case library
        /// A photo story's photo, which belongs to its own story. `title` is the story's name
        /// (`DayStoryPlan.eventName`), empty when it has none.
        case photoStory(title: String)
    }

    public init(id: String, time: Date, coordinate: Coordinate?, kind: Kind) {
        self.id = id
        self.time = time
        self.coordinate = coordinate
        self.kind = kind
    }
}

/// What one day story request is made of (spec 5.1): the day's events, the photos sent and what each library photo matched.
public struct DayStoryPlan: Sendable, Equatable {
    /// A library photo matches an event at most this many seconds before or after it.
    public static let matchWindow: TimeInterval = 600
    /// When photo and event both have positions, they are at most this many metres apart.
    public static let matchDistance = 150.0
    /// Most photos sent in one request.
    public static let photoCap = 12

    /// The photos sent, time order, at most `photoCap`.
    public var photos: [DayStoryPhoto]
    /// Library photo id → matched event, for the library photos in `photos` that have one.
    public var matches: [String: DiaryEntry]
    /// The day's entries that are not library photos (photo, buzz and stop stories), time order.
    public var events: [DiaryEntry]
    /// Every photo of the day, sent or not.
    public var totalPhotos: Int

    public static func make(day: DiaryDay) -> DayStoryPlan {
        let ordered = day.entries.sorted { ($0.time, $0.id) < ($1.time, $1.id) }
        let events = ordered.filter { $0.kind != .libraryPhoto }
        let all = ordered.compactMap { entry -> DayStoryPhoto? in
            switch entry.kind {
            case .libraryPhoto:
                DayStoryPhoto(id: entry.id, time: entry.time, coordinate: entry.coordinate, kind: .library)
            case .photoStory:
                DayStoryPhoto(id: entry.id, time: entry.time, coordinate: entry.coordinate,
                              kind: .photoStory(title: eventName(entry)))
            case .buzz, .stop:
                nil
            }
        }
        let photos = choose(all, cap: photoCap)
        var matches: [String: DiaryEntry] = [:]
        // A photo story's photo belongs to its own story; only library photos are matched.
        for photo in photos where photo.kind == .library {
            matches[photo.id] = match(photo, events: events)
        }
        return DayStoryPlan(photos: photos, matches: matches, events: events, totalPhotos: all.count)
    }

    /// First and last always; the rest at indices round(i·(n−1)/(cap−1)).
    static func choose(_ photos: [DayStoryPhoto], cap: Int) -> [DayStoryPhoto] {
        guard photos.count > cap else { return photos }
        guard cap >= 2 else { return Array(photos.prefix(max(cap, 0))) }
        let span = photos.count - 1, steps = cap - 1
        // round(i·span/steps), half up, in integers: floor((2·i·span + steps) / (2·steps)). With span > steps the
        // indices strictly increase, so none repeats.
        return (0..<cap).map { photos[(2 * $0 * span + steps) / (2 * steps)] }
    }

    /// Smallest time gap within ±10 min; when both have positions also ≤ 150 m. Equal gaps go to the earlier event.
    static func match(_ photo: DayStoryPhoto, events: [DiaryEntry]) -> DiaryEntry? {
        let inReach = events.filter { event in
            guard abs(event.time.timeIntervalSince(photo.time)) <= matchWindow else { return false }
            guard let a = photo.coordinate, let b = event.coordinate else { return true }
            // A micrometre of slack: haversine puts a point placed exactly 150 m away at 150.00000000000003 m.
            return GeoMath.distance(a, b) <= matchDistance + 1e-6
        }
        return inReach.min { a, b in
            let gapA = abs(a.time.timeIntervalSince(photo.time)), gapB = abs(b.time.timeIntervalSince(photo.time))
            return gapA != gapB ? gapA < gapB : (a.time, a.id) < (b.time, b.id)
        }
    }

    /// How the request names an event, collapsed to one line: a buzz by its place, else its title; a photo or stop
    /// story by its title, else its place. Empty when it has neither.
    static func eventName(_ entry: DiaryEntry) -> String {
        let title = GuideText.oneLine(entry.title)
        let place = GuideText.oneLine(entry.placeName ?? "")
        let preferred = entry.kind == .buzz ? [place, title] : [title, place]
        return preferred.first { !$0.isEmpty } ?? ""
    }
}
