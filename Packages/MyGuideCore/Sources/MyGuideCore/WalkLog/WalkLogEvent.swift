import Foundation

public enum LocationPermission: String, Sendable, Codable { case always, whenInUse, denied, notDetermined }
public enum NotificationPermission: String, Sendable, Codable { case allowed, denied, notDetermined }
public enum MotionPermission: String, Sendable, Codable { case authorized, denied, restricted, notDetermined, unavailable }
public enum WalkStopReason: String, Sendable, Codable { case user, timeLimit, lowBattery, pausedTooLong, locationDenied }
public enum FixDrop: String, Sendable, Codable { case stale, invalid }
public enum WalkNotificationKind: String, Sendable, Codable { case buzz, more, stop, storyFailed, autoOff }
public enum StopStoryOutcome: String, Sendable, Codable { case told, silent, failed }
/// Why a pause is logged: the detector's triggers, plus the user's command. Log side only; `PauseTrigger` stays the detector's.
public enum WalkPauseReason: String, Sendable, Codable {
    case motion, gps, manual

    public init(_ trigger: PauseTrigger) {
        switch trigger {
        case .motion: self = .motion
        case .gps: self = .gps
        }
    }
}
/// Who gave a command; nil in the log means automatic.
public enum WalkSource: String, Sendable, Codable { case phone, watch }
public enum StopShownVia: String, Sendable, Codable { case liveActivity, notification }

public struct WalkLogStart: Sendable, Equatable {
    public var appVersion: String
    public var build: String
    public var location: LocationPermission
    public var notifications: NotificationPermission
    public var liveActivities: Bool
    public var motion: MotionPermission
    public var perHour: Int
    public var battery: Double?
    /// Who started the walk; nil when not known.
    public var source: WalkSource?

    public init(appVersion: String, build: String, location: LocationPermission, notifications: NotificationPermission,
                liveActivities: Bool, motion: MotionPermission, perHour: Int, battery: Double?, source: WalkSource? = nil) {
        self.appVersion = appVersion
        self.build = build
        self.location = location
        self.notifications = notifications
        self.liveActivities = liveActivities
        self.motion = motion
        self.perHour = perHour
        self.battery = battery
        self.source = source
    }
}

public struct WalkLogFix: Sendable, Equatable {
    public var coordinate: Coordinate
    public var accuracy: Double
    public var speed: Double?
    public var course: Double?
    public var paused: Bool
    public var dropped: FixDrop?

    public init(coordinate: Coordinate, accuracy: Double, speed: Double?, course: Double?, paused: Bool, dropped: FixDrop?) {
        self.coordinate = coordinate
        self.accuracy = accuracy
        self.speed = speed
        self.course = course
        self.paused = paused
        self.dropped = dropped
    }
}

public struct WalkLogPlace: Sendable, Equatable {
    public var id: String
    public var name: String
    public var tier: PlaceTier
    public var coordinate: Coordinate

    public init(id: String, name: String, tier: PlaceTier, coordinate: Coordinate) {
        self.id = id
        self.name = name
        self.tier = tier
        self.coordinate = coordinate
    }
}

public struct WalkLogBuzz: Sendable, Equatable {
    public var id: UUID
    public var placeID: String
    public var name: String
    public var tier: PlaceTier
    public var distance: Double
    public var override: Bool
    public var detail: String

    public init(id: UUID, placeID: String, name: String, tier: PlaceTier, distance: Double, override: Bool, detail: String) {
        self.id = id
        self.placeID = placeID
        self.name = name
        self.tier = tier
        self.distance = distance
        self.override = override
        self.detail = detail
    }

    public init(_ buzz: Buzz) {
        self.init(id: buzz.id, placeID: buzz.place.candidate.id, name: buzz.title, tier: buzz.place.tier,
                  distance: buzz.distance, override: buzz.usedOverride, detail: buzz.detail)
    }
}

public struct NotificationSettingsSnapshot: Sendable, Equatable {
    public var authorization: String
    public var alert: String
    public var sound: String
    public var lockScreen: String
    public var notificationCenter: String
    public var timeSensitive: String

    public init(authorization: String, alert: String, sound: String, lockScreen: String, notificationCenter: String, timeSensitive: String) {
        self.authorization = authorization
        self.alert = alert
        self.sound = sound
        self.lockScreen = lockScreen
        self.notificationCenter = notificationCenter
        self.timeSensitive = timeSensitive
    }
}

/// One line of a walk log (spec 4.2).
public struct WalkLogEvent: Sendable, Equatable {
    public var at: Date
    public var kind: Kind

    public init(at: Date, kind: Kind) {
        self.at = at
        self.kind = kind
    }

    public enum Kind: Sendable, Equatable {
        case started(WalkLogStart)
        case stopped(WalkStopReason, source: WalkSource?)
        case app(foreground: Bool)
        case fix(WalkLogFix)
        case gps(found: Bool)
        case fetchStarted(Coordinate)
        /// `osmFailed`: OpenStreetMap failed (both endpoints) and only Wikipedia and carried places are listed
        /// (spec 13.6); false in a line written before the field existed.
        case fetched(count: Int, top: Int, good: Int, wikiOnly: Int, places: [WalkLogPlace], osmFailed: Bool)
        case fetchFailed(error: String)
        case quiet(QuietReason, due: [DuePlace])
        case buzz(WalkLogBuzz)
        case notified(id: UUID?, kind: WalkNotificationKind, settings: NotificationSettingsSnapshot)
        case notifyFailed(id: UUID?, kind: WalkNotificationKind, error: String)
        case busy(Bool)
        case storyPreparing(id: UUID)
        case storyReady(id: UUID, seconds: Double)
        case storyFailed(id: UUID, seconds: Double, error: String)
        case stopDetected(Coordinate)
        case stopStory(outcome: StopStoryOutcome, title: String?, error: String?)
        case stopShown(via: StopShownVia)
        case motion(MotionActivity, confidence: MotionConfidence)
        case paused(WalkPauseReason, at: Coordinate?, source: WalkSource?)
        case resumed(WalkPauseReason, pausedSeconds: Double, source: WalkSource?)
        case failure(context: String, error: String)
    }

    public static let maxErrorLength = 300
    public static let maxFetchedPlaces = 150

    /// `String(describing:)`, cut to 300 characters.
    public static func errorText(_ error: Error) -> String {
        String(String(describing: error).prefix(maxErrorLength))
    }

    /// Counts over every place; the listed places are capped at 150 by tier, then distance from `around`.
    public static func fetched(_ places: [WalkingPlace], around: Coordinate, osmFailed: Bool) -> Kind {
        let ranked = places
            .map { ($0, GeoMath.distance(around, $0.candidate.coordinate)) }
            .sorted { a, b in
                if a.0.tier != b.0.tier { return a.0.tier < b.0.tier }
                if a.1 != b.1 { return a.1 < b.1 }
                return a.0.candidate.id < b.0.candidate.id
            }
            .prefix(maxFetchedPlaces)
            .map { WalkLogPlace(id: $0.0.candidate.id, name: $0.0.candidate.name, tier: $0.0.tier, coordinate: $0.0.candidate.coordinate) }
        return .fetched(
            count: places.count,
            top: places.filter { $0.tier == .top }.count,
            good: places.filter { $0.tier == .good }.count,
            wikiOnly: places.filter { $0.tier == .wikiOnly }.count,
            places: Array(ranked),
            osmFailed: osmFailed)
    }
}
