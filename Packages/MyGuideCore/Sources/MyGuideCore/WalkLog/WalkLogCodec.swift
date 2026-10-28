import Foundation

/// One JSON object per line, keys sorted, values rounded as the spec says (4.2): coordinates to 6 decimals,
/// distances and accuracy to whole metres, seconds to one decimal.
public enum WalkLogCodec {
    // MARK: Encoding

    public static func line(_ event: WalkLogEvent) -> Data {
        var object = fields(of: event.kind)
        object["t"] = timestamp(event.at)
        object["e"] = name(of: event.kind)
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? JSONSerialization.data(withJSONObject: object, options: options)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    static func coordinate(_ x: Double) -> Any { number((x * 1e6).rounded() / 1e6) }
    static func metres(_ x: Double) -> Any { number(x.rounded()) }
    static func seconds(_ x: Double) -> Any { number((x * 10).rounded() / 10) }

    /// JSONSerialization prints a Double with 17 significant digits (59.912346 becomes 59.912345999999999). A Decimal
    /// built from the shortest round-trip text keeps the short form. NaN and infinity are not JSON: they become null
    /// (JSONSerialization would raise an Objective-C exception on them).
    static func number(_ x: Double) -> Any {
        guard x.isFinite, let d = Decimal(string: "\(x)") else { return NSNull() }
        return NSDecimalNumber(decimal: d)
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    private static func name(of kind: WalkLogEvent.Kind) -> String {
        switch kind {
        case .started: "started"
        case .stopped: "stopped"
        case .app: "app"
        case .fix: "fix"
        case .gps: "gps"
        case .fetchStarted: "fetchStarted"
        case .fetched: "fetched"
        case .fetchFailed: "fetchFailed"
        case .quiet: "quiet"
        case .buzz: "buzz"
        case .notified: "notified"
        case .notifyFailed: "notifyFailed"
        case .busy: "busy"
        case .storyPreparing: "storyPreparing"
        case .storyReady: "storyReady"
        case .storyFailed: "storyFailed"
        case .stopDetected: "stopDetected"
        case .stopStory: "stopStory"
        case .stopShown: "stopShown"
        case .motion: "motion"
        case .paused: "paused"
        case .resumed: "resumed"
        case .failure: "failure"
        }
    }

    private static func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    private static func fields(of kind: WalkLogEvent.Kind) -> [String: Any] {
        switch kind {
        case .started(let s):
            return ["appVersion": s.appVersion, "build": s.build, "location": s.location.rawValue,
                    "notifications": s.notifications.rawValue, "liveActivities": s.liveActivities,
                    "motion": s.motion.rawValue, "perHour": s.perHour, "battery": s.battery.map(number) ?? NSNull()]
        case .stopped(let reason):
            return ["reason": reason.rawValue]
        case .app(let foreground):
            return ["state": foreground ? "foreground" : "background"]
        case .fix(let f):
            var o: [String: Any] = [
                "lat": coordinate(f.coordinate.latitude), "lon": coordinate(f.coordinate.longitude),
                "accuracy": metres(f.accuracy), "speed": f.speed.map(number) ?? NSNull(), "course": f.course.map(number) ?? NSNull(), "paused": f.paused,
            ]
            if let dropped = f.dropped { o["dropped"] = dropped.rawValue }
            return o
        case .gps(let found):
            return ["state": found ? "found" : "lost"]
        case .fetchStarted(let c):
            return ["lat": coordinate(c.latitude), "lon": coordinate(c.longitude)]
        case .fetched(let count, let top, let good, let wikiOnly, let places):
            let list: [[String: Any]] = places.map {
                ["id": $0.id, "name": $0.name, "tier": $0.tier.rawValue,
                 "lat": coordinate($0.coordinate.latitude), "lon": coordinate($0.coordinate.longitude)]
            }
            return ["count": count, "top": top, "good": good, "wikiOnly": wikiOnly, "places": list]
        case .fetchFailed(let error):
            return ["error": error]
        case .quiet(let reason, let due):
            let list: [[String: Any]] = due.map {
                ["id": $0.id, "name": $0.name, "tier": $0.tier.rawValue, "distance": metres($0.distance), "excluded": $0.excluded]
            }
            return ["reason": reason.rawValue, "due": list]
        case .buzz(let b):
            return ["id": b.id.uuidString, "placeID": b.placeID, "name": b.name, "tier": b.tier.rawValue,
                    "distance": metres(b.distance), "override": b.override, "detail": b.detail]
        case .notified(let id, let kind, let s):
            return ["id": orNull(id?.uuidString), "kind": kind.rawValue,
                    "settings": ["authorization": s.authorization, "alert": s.alert, "sound": s.sound,
                                 "lockScreen": s.lockScreen, "notificationCenter": s.notificationCenter,
                                 "timeSensitive": s.timeSensitive]]
        case .notifyFailed(let id, let kind, let error):
            return ["id": orNull(id?.uuidString), "kind": kind.rawValue, "error": error]
        case .busy(let busy):
            return ["busy": busy]
        case .storyPreparing(let id):
            return ["id": id.uuidString]
        case .storyReady(let id, let secs):
            return ["id": id.uuidString, "seconds": seconds(secs)]
        case .storyFailed(let id, let secs, let error):
            return ["id": id.uuidString, "seconds": seconds(secs), "error": error]
        case .stopDetected(let c):
            return ["lat": coordinate(c.latitude), "lon": coordinate(c.longitude)]
        case .stopStory(let outcome, let title, let error):
            return ["outcome": outcome.rawValue, "title": orNull(title), "error": orNull(error)]
        case .stopShown(let via):
            return ["via": via.rawValue]
        case .motion(let activity, let confidence):
            return ["activity": activity.rawValue, "confidence": confidence.rawValue]
        case .paused(let trigger, let at):
            return ["reason": trigger.rawValue,
                    "lat": at.map { coordinate($0.latitude) } ?? NSNull(), "lon": at.map { coordinate($0.longitude) } ?? NSNull()]
        case .resumed(let trigger, let pausedSeconds):
            return ["reason": trigger.rawValue, "pausedSeconds": seconds(pausedSeconds)]
        case .failure(let context, let error):
            return ["context": context, "error": error]
        }
    }

    // MARK: Decoding

    /// nil for a line that is not a JSON object, lacks `t` or `e`, names an unknown event, or lacks a field.
    public static func event(from line: Data) -> WalkLogEvent? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let t = object["t"] as? String,
              let at = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(t),
              let e = object["e"] as? String,
              let kind = kind(named: e, from: object) else { return nil }
        return WalkLogEvent(at: at, kind: kind)
    }

    private static func string(_ o: [String: Any], _ k: String) -> String? { o[k] as? String }
    private static func double(_ o: [String: Any], _ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
    private static func int(_ o: [String: Any], _ k: String) -> Int? {
        guard let n = o[k] as? NSNumber, n.doubleValue == n.doubleValue.rounded() else { return nil }
        return n.intValue
    }
    private static func bool(_ o: [String: Any], _ k: String) -> Bool? { o[k] as? Bool }
    private static func uuid(_ o: [String: Any], _ k: String) -> UUID? { string(o, k).flatMap(UUID.init(uuidString:)) }
    private static func coord(_ o: [String: Any]) -> Coordinate? {
        guard let lat = double(o, "lat"), let lon = double(o, "lon") else { return nil }
        return Coordinate(latitude: lat, longitude: lon)
    }
    private static func tier(_ o: [String: Any]) -> PlaceTier? { int(o, "tier").flatMap(PlaceTier.init(rawValue:)) }
    private static func raw<R: RawRepresentable>(_ o: [String: Any], _ k: String, _ type: R.Type) -> R? where R.RawValue == String {
        string(o, k).flatMap(R.init(rawValue:))
    }
    /// Optional id: JSON null or absent is nil; a present value that is not a UUID makes the line unreadable.
    private static func optionalUUID(_ o: [String: Any], _ k: String) -> UUID?? {
        if o[k] == nil || o[k] is NSNull { return .some(nil) }
        guard let u = uuid(o, k) else { return nil }
        return .some(u)
    }
    private static func objects(_ o: [String: Any], _ k: String) -> [[String: Any]]? { o[k] as? [[String: Any]] }

    private static func kind(named name: String, from o: [String: Any]) -> WalkLogEvent.Kind? {
        switch name {
        case "started":
            guard let appVersion = string(o, "appVersion"), let build = string(o, "build"),
                  let location = raw(o, "location", LocationPermission.self),
                  let notifications = raw(o, "notifications", NotificationPermission.self),
                  let liveActivities = bool(o, "liveActivities"),
                  let motion = raw(o, "motion", MotionPermission.self),
                  let perHour = int(o, "perHour") else { return nil }
            return .started(WalkLogStart(appVersion: appVersion, build: build, location: location, notifications: notifications,
                                         liveActivities: liveActivities, motion: motion, perHour: perHour, battery: double(o, "battery")))
        case "stopped":
            return raw(o, "reason", WalkStopReason.self).map { .stopped($0) }
        case "app":
            switch string(o, "state") {
            case "foreground": return .app(foreground: true)
            case "background": return .app(foreground: false)
            default: return nil
            }
        case "fix":
            guard let c = coord(o), let accuracy = double(o, "accuracy"), let paused = bool(o, "paused") else { return nil }
            var drop: FixDrop?
            if o["dropped"] != nil {
                guard let d = raw(o, "dropped", FixDrop.self) else { return nil }
                drop = d
            }
            return .fix(WalkLogFix(coordinate: c, accuracy: accuracy, speed: double(o, "speed"), course: double(o, "course"),
                                   paused: paused, dropped: drop))
        case "gps":
            switch string(o, "state") {
            case "found": return .gps(found: true)
            case "lost": return .gps(found: false)
            default: return nil
            }
        case "fetchStarted":
            return coord(o).map { .fetchStarted($0) }
        case "fetched":
            guard let count = int(o, "count"), let top = int(o, "top"), let good = int(o, "good"),
                  let wikiOnly = int(o, "wikiOnly"), let list = objects(o, "places") else { return nil }
            var places: [WalkLogPlace] = []
            for p in list {
                guard let id = string(p, "id"), let name = string(p, "name"), let tier = tier(p), let c = coord(p) else { return nil }
                places.append(WalkLogPlace(id: id, name: name, tier: tier, coordinate: c))
            }
            return .fetched(count: count, top: top, good: good, wikiOnly: wikiOnly, places: places)
        case "fetchFailed":
            return string(o, "error").map { .fetchFailed(error: $0) }
        case "quiet":
            guard let reason = raw(o, "reason", QuietReason.self), let list = objects(o, "due") else { return nil }
            var due: [DuePlace] = []
            for p in list {
                guard let id = string(p, "id"), let name = string(p, "name"), let tier = tier(p),
                      let distance = double(p, "distance"), let excluded = bool(p, "excluded") else { return nil }
                due.append(DuePlace(id: id, name: name, tier: tier, distance: distance, excluded: excluded))
            }
            return .quiet(reason, due: due)
        case "buzz":
            guard let id = uuid(o, "id"), let placeID = string(o, "placeID"), let name = string(o, "name"), let tier = tier(o),
                  let distance = double(o, "distance"), let override = bool(o, "override"), let detail = string(o, "detail")
            else { return nil }
            return .buzz(WalkLogBuzz(id: id, placeID: placeID, name: name, tier: tier, distance: distance, override: override, detail: detail))
        case "notified":
            guard let id = optionalUUID(o, "id"), let kind = raw(o, "kind", WalkNotificationKind.self),
                  let s = o["settings"] as? [String: Any],
                  let authorization = string(s, "authorization"), let alert = string(s, "alert"), let sound = string(s, "sound"),
                  let lockScreen = string(s, "lockScreen"), let center = string(s, "notificationCenter"),
                  let timeSensitive = string(s, "timeSensitive") else { return nil }
            return .notified(id: id, kind: kind, settings: NotificationSettingsSnapshot(
                authorization: authorization, alert: alert, sound: sound, lockScreen: lockScreen,
                notificationCenter: center, timeSensitive: timeSensitive))
        case "notifyFailed":
            guard let id = optionalUUID(o, "id"), let kind = raw(o, "kind", WalkNotificationKind.self),
                  let error = string(o, "error") else { return nil }
            return .notifyFailed(id: id, kind: kind, error: error)
        case "busy":
            return bool(o, "busy").map { .busy($0) }
        case "storyPreparing":
            return uuid(o, "id").map { .storyPreparing(id: $0) }
        case "storyReady":
            guard let id = uuid(o, "id"), let secs = double(o, "seconds") else { return nil }
            return .storyReady(id: id, seconds: secs)
        case "storyFailed":
            guard let id = uuid(o, "id"), let secs = double(o, "seconds"), let error = string(o, "error") else { return nil }
            return .storyFailed(id: id, seconds: secs, error: error)
        case "stopDetected":
            return coord(o).map { .stopDetected($0) }
        case "stopStory":
            guard let outcome = raw(o, "outcome", StopStoryOutcome.self) else { return nil }
            return .stopStory(outcome: outcome, title: string(o, "title"), error: string(o, "error"))
        case "stopShown":
            return raw(o, "via", StopShownVia.self).map { .stopShown(via: $0) }
        case "motion":
            guard let a = raw(o, "activity", MotionActivity.self), let c = raw(o, "confidence", MotionConfidence.self) else { return nil }
            return .motion(a, confidence: c)
        case "paused":
            guard let reason = raw(o, "reason", PauseTrigger.self) else { return nil }
            return .paused(reason, at: coord(o))
        case "resumed":
            guard let reason = raw(o, "reason", PauseTrigger.self), let secs = double(o, "pausedSeconds") else { return nil }
            return .resumed(reason, pausedSeconds: secs)
        case "failure":
            guard let context = string(o, "context"), let error = string(o, "error") else { return nil }
            return .failure(context: context, error: error)
        default:
            return nil
        }
    }
}
