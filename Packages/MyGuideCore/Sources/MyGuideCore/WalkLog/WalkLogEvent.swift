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
/// Why the map shows what it shows while walking (spec 19.7, `ShownLogGate`):
/// - `heading`: the selector's automatic rules picked the place (the phone heading, else the nearest; also the place
///   whose story is playing, which the selector keeps);
/// - `tap`: the owner tapped it, or the selector still holds that tapped place;
/// - `buzz`: a buzz selected it;
/// - `cleared`: no place has been selected for `ShownLogGate.clearedConfirmation` (5) seconds (a fix worse than
///   50 m, no fix, or an empty list).
public enum ShownReason: String, Sendable, Codable, CaseIterable { case heading, tap, buzz, cleared }

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
    /// The buzz of a tour's stop (tours spec 6), not the engine's. Written only when true; lines from before it read
    /// as false.
    public var tourStop: Bool
    /// A «behind you» buzz after a story (spec 20.6.6, `Buzz.behindYou`). Written only when true; lines from before
    /// it read as false.
    public var behind: Bool

    public init(id: UUID, placeID: String, name: String, tier: PlaceTier, distance: Double, override: Bool, detail: String,
                tourStop: Bool = false, behind: Bool = false) {
        self.id = id
        self.placeID = placeID
        self.name = name
        self.tier = tier
        self.distance = distance
        self.override = override
        self.detail = detail
        self.tourStop = tourStop
        self.behind = behind
    }

    public init(_ buzz: Buzz, tourStop: Bool = false) {
        self.init(id: buzz.id, placeID: buzz.place.candidate.id, name: buzz.title, tier: buzz.place.tier,
                  distance: buzz.distance, override: buzz.usedOverride, detail: buzz.detail, tourStop: tourStop,
                  behind: buzz.behindYou)
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
        /// `osmFailed`: OpenStreetMap failed (every endpoint) and only Wikipedia and carried places are listed
        /// (spec 13.6); false in a line written before the field existed. `osmErrors`: one short line per Overpass
        /// endpoint tried when it failed ("overpass-api.de: timed out", or "slow" when it ran out of time); empty
        /// otherwise and in older lines. `facts`: how many candidates got Wikidata facts; `dropped`: the names of the
        /// Wikipedia-only candidates dropped for their Wikidata class; `factsFailed`: Wikidata batches that failed (spec 19.8).
        /// All three are 0 or empty in lines written before they existed. `stale`: a stored list standing in at the
        /// start of a walk until the fresh one arrives (spec 19.6); false in lines written before it existed.
        case fetched(count: Int, top: Int, good: Int, wikiOnly: Int, places: [WalkLogPlace], osmFailed: Bool,
                     osmErrors: [String] = [], facts: Int = 0, dropped: [String] = [], factsFailed: Int = 0,
                     stale: Bool = false)
        /// `osmErrors` as in `fetched`, when the failure was every Overpass endpoint's.
        case fetchFailed(error: String, osmErrors: [String] = [])
        /// `heldBy`: the place that held a `held` decision (spec 20.6.6); nil for other reasons and in lines written
        /// before it existed.
        case quiet(QuietReason, due: [DuePlace], heldBy: HoldingPlace? = nil)
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
        /// The place the map selected while walking, or nil id and name when it was cleared (spec 19.7). Which
        /// selections are written is `ShownLogGate`'s call.
        case shown(placeID: String?, name: String?, reason: ShownReason)
    }

    public static let maxErrorLength = 300
    public static let maxFetchedPlaces = 150

    /// `String(describing:)`, cut to 300 characters. An `OverpassFailure` is described by its first error, as before
    /// it existed; its endpoint lines go to `osmErrors`.
    public static func errorText(_ error: Error) -> String {
        let shown = (error as? OverpassFailure)?.first ?? error
        return String(String(describing: shown).prefix(maxErrorLength))
    }

    /// `fetchFailed` for `error`, with the Overpass endpoint lines when every endpoint failed.
    public static func fetchFailed(_ error: Error) -> Kind {
        .fetchFailed(error: errorText(error), osmErrors: (error as? OverpassFailure)?.endpointErrors ?? [])
    }

    /// Counts over every place; the listed places are capped at 150 by tier, then distance from `around`.
    public static func fetched(_ places: [WalkingPlace], around: Coordinate, osmFailed: Bool,
                               osmErrors: [String] = [], facts: Int = 0, dropped: [String] = [],
                               factsFailed: Int = 0, stale: Bool = false) -> Kind {
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
            osmFailed: osmFailed,
            osmErrors: osmErrors,
            facts: facts,
            dropped: dropped,
            factsFailed: factsFailed,
            stale: stale)
    }
}
