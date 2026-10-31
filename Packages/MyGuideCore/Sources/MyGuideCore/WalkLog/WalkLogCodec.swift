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
        case .shown: "shown"
        case .server: "server"
        }
    }

    /// The `source` key is left out when the command was automatic.
    private static func withSource(_ fields: [String: Any], _ source: WalkSource?) -> [String: Any] {
        guard let source else { return fields }
        var o = fields
        o["source"] = source.rawValue
        return o
    }

    private static func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    private static func fields(of kind: WalkLogEvent.Kind) -> [String: Any] {
        switch kind {
        case .started(let s):
            var o: [String: Any] = ["appVersion": s.appVersion, "build": s.build, "location": s.location.rawValue,
                    "notifications": s.notifications.rawValue, "liveActivities": s.liveActivities,
                    "motion": s.motion.rawValue, "perHour": s.perHour, "battery": s.battery.map(number) ?? NSNull()]
            if let source = s.source { o["source"] = source.rawValue }
            return o
        case .stopped(let reason, let source):
            return withSource(["reason": reason.rawValue], source)
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
        case .fetched(let count, let top, let good, let wikiOnly, let places, let osmFailed, let osmErrors, let facts,
                      let dropped, let factsFailed, let stale, let factsSeconds, let factsCut):
            let list: [[String: Any]] = places.map {
                ["id": $0.id, "name": $0.name, "tier": $0.tier.rawValue,
                 "lat": coordinate($0.coordinate.latitude), "lon": coordinate($0.coordinate.longitude)]
            }
            var o: [String: Any] = ["count": count, "top": top, "good": good, "wikiOnly": wikiOnly, "places": list,
                                    "osmFailed": osmFailed]
            // Written only when there is something to say, so a line without a failure looks as before.
            if !osmErrors.isEmpty { o["osmErrors"] = osmErrors }
            if facts != 0 { o["facts"] = facts }
            if !dropped.isEmpty { o["dropped"] = dropped }
            if factsFailed != 0 { o["factsFailed"] = factsFailed }
            if stale { o["stale"] = true }
            if let factsSeconds { o["factsSeconds"] = seconds(factsSeconds) }
            if factsCut { o["factsCut"] = true }
            return o
        case .fetchFailed(let error, let osmErrors):
            var o: [String: Any] = ["error": error]
            if !osmErrors.isEmpty { o["osmErrors"] = osmErrors }
            return o
        case .quiet(let reason, let due, let heldBy):
            let list: [[String: Any]] = due.map {
                ["id": $0.id, "name": $0.name, "tier": $0.tier.rawValue, "distance": metres($0.distance), "excluded": $0.excluded]
            }
            var o: [String: Any] = ["reason": reason.rawValue, "due": list]
            if let heldBy { o["heldBy"] = ["id": heldBy.id, "name": heldBy.name] }
            return o
        case .buzz(let b):
            var o: [String: Any] = ["id": b.id.uuidString, "placeID": b.placeID, "name": b.name, "tier": b.tier.rawValue,
                                    "distance": metres(b.distance), "override": b.override, "detail": b.detail]
            if b.tourStop { o["tourStop"] = true }
            if b.behind { o["behind"] = true }
            return o
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
        case .paused(let reason, let at, let source):
            return withSource(["reason": reason.rawValue,
                    "lat": at.map { coordinate($0.latitude) } ?? NSNull(), "lon": at.map { coordinate($0.longitude) } ?? NSNull()], source)
        case .resumed(let reason, let pausedSeconds, let source):
            return withSource(["reason": reason.rawValue, "pausedSeconds": seconds(pausedSeconds)], source)
        case .failure(let context, let error):
            return ["context": context, "error": error]
        case .shown(let placeID, let name, let reason):
            return ["placeID": orNull(placeID), "name": orNull(name), "reason": reason.rawValue]
        case .server(let allowance):
            var o: [String: Any] = ["freeLeft": allowance.freeLeft]
            if let credits = allowance.credits { o["credits"] = credits }
            return o
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
    /// Optional source: absent or null is nil (old lines, automatic); a present value that is not a source makes the line unreadable.
    private static func optionalSource(_ o: [String: Any]) -> WalkSource?? {
        if o["source"] == nil || o["source"] is NSNull { return .some(nil) }
        guard let s = raw(o, "source", WalkSource.self) else { return nil }
        return .some(s)
    }
    /// Optional text: JSON null or absent is nil; a present value that is not text makes the line unreadable.
    private static func optionalString(_ o: [String: Any], _ k: String) -> String?? {
        if o[k] == nil || o[k] is NSNull { return .some(nil) }
        guard let s = string(o, k) else { return nil }
        return .some(s)
    }
    private static func objects(_ o: [String: Any], _ k: String) -> [[String: Any]]? { o[k] as? [[String: Any]] }
    /// Optional flag: absent is false; a present value that is not a Bool makes the line unreadable (nil).
    private static func optionalFlag(_ o: [String: Any], _ k: String) -> Bool? {
        guard o[k] != nil else { return false }
        return bool(o, k)
    }
    /// "osmErrors": absent (older lines, or nothing failed) → []; present, it must be an array of strings, else nil.
    private static func osmErrors(_ o: [String: Any]) -> [String]? {
        guard let value = o["osmErrors"] else { return [] }
        return value as? [String]
    }

    private static func kind(named name: String, from o: [String: Any]) -> WalkLogEvent.Kind? {
        switch name {
        case "started":
            guard let appVersion = string(o, "appVersion"), let build = string(o, "build"),
                  let location = raw(o, "location", LocationPermission.self),
                  let notifications = raw(o, "notifications", NotificationPermission.self),
                  let liveActivities = bool(o, "liveActivities"),
                  let motion = raw(o, "motion", MotionPermission.self),
                  let perHour = int(o, "perHour"), let source = optionalSource(o) else { return nil }
            return .started(WalkLogStart(appVersion: appVersion, build: build, location: location, notifications: notifications,
                                         liveActivities: liveActivities, motion: motion, perHour: perHour, battery: double(o, "battery"), source: source))
        case "stopped":
            guard let reason = raw(o, "reason", WalkStopReason.self), let source = optionalSource(o) else { return nil }
            return .stopped(reason, source: source)
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
            // Absent in lines written before it existed: no failure then. Present, it must be a Bool.
            var osmFailed = false
            if o["osmFailed"] != nil {
                guard let flag = bool(o, "osmFailed") else { return nil }
                osmFailed = flag
            }
            guard let osmErrors = osmErrors(o) else { return nil }
            // Absent in lines written before Wikidata facts (spec 19.8) and when there is nothing to say; present,
            // they must be readable.
            var facts = 0, factsFailed = 0
            var dropped: [String] = []
            if o["facts"] != nil {
                guard let value = int(o, "facts") else { return nil }
                facts = value
            }
            if o["factsFailed"] != nil {
                guard let value = int(o, "factsFailed") else { return nil }
                factsFailed = value
            }
            if let value = o["dropped"] {
                guard let names = value as? [String] else { return nil }
                dropped = names
            }
            // Absent in lines written before the stale list at start (spec 19.6) and for every fresh list.
            var stale = false
            if o["stale"] != nil {
                guard let flag = bool(o, "stale") else { return nil }
                stale = flag
            }
            // Absent in lines written before the facts time (re-review R3) and when nothing was looked up or cut.
            var factsSeconds: Double?
            if o["factsSeconds"] != nil {
                guard let value = double(o, "factsSeconds") else { return nil }
                factsSeconds = value
            }
            guard let factsCut = optionalFlag(o, "factsCut") else { return nil }
            return .fetched(count: count, top: top, good: good, wikiOnly: wikiOnly, places: places, osmFailed: osmFailed,
                            osmErrors: osmErrors, facts: facts, dropped: dropped, factsFailed: factsFailed,
                            stale: stale, factsSeconds: factsSeconds, factsCut: factsCut)
        case "fetchFailed":
            guard let error = string(o, "error"), let osmErrors = osmErrors(o) else { return nil }
            return .fetchFailed(error: error, osmErrors: osmErrors)
        case "quiet":
            guard let reason = raw(o, "reason", QuietReason.self), let list = objects(o, "due") else { return nil }
            var due: [DuePlace] = []
            for p in list {
                guard let id = string(p, "id"), let name = string(p, "name"), let tier = tier(p),
                      let distance = double(p, "distance"), let excluded = bool(p, "excluded") else { return nil }
                due.append(DuePlace(id: id, name: name, tier: tier, distance: distance, excluded: excluded))
            }
            // `heldBy` is newer than the line: missing reads as nil; present, it must hold an id and a name.
            var heldBy: HoldingPlace?
            if let value = o["heldBy"] {
                guard let holder = value as? [String: Any], let id = string(holder, "id"),
                      let name = string(holder, "name") else { return nil }
                heldBy = HoldingPlace(id: id, name: name)
            }
            return .quiet(reason, due: due, heldBy: heldBy)
        case "buzz":
            guard let id = uuid(o, "id"), let placeID = string(o, "placeID"), let name = string(o, "name"), let tier = tier(o),
                  let distance = double(o, "distance"), let override = bool(o, "override"), let detail = string(o, "detail")
            else { return nil }
            // `tourStop` and `behind` are newer than the line: missing reads as false; present, each must be a Bool.
            guard let tourStop = optionalFlag(o, "tourStop"), let behind = optionalFlag(o, "behind") else { return nil }
            return .buzz(WalkLogBuzz(id: id, placeID: placeID, name: name, tier: tier, distance: distance, override: override,
                                     detail: detail, tourStop: tourStop, behind: behind))
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
            guard let reason = raw(o, "reason", WalkPauseReason.self), let source = optionalSource(o) else { return nil }
            return .paused(reason, at: coord(o), source: source)
        case "resumed":
            guard let reason = raw(o, "reason", WalkPauseReason.self), let secs = double(o, "pausedSeconds"),
                  let source = optionalSource(o) else { return nil }
            return .resumed(reason, pausedSeconds: secs, source: source)
        case "failure":
            guard let context = string(o, "context"), let error = string(o, "error") else { return nil }
            return .failure(context: context, error: error)
        case "shown":
            guard let reason = raw(o, "reason", ShownReason.self),
                  let placeID = optionalString(o, "placeID"), let name = optionalString(o, "name") else { return nil }
            return .shown(placeID: placeID, name: name, reason: reason)
        case "server":
            // `freeLeft` must be an object of whole numbers; `credits` is absent when the server gave none, and
            // present it must be a whole number.
            guard let free = o["freeLeft"] as? [String: Any] else { return nil }
            var freeLeft: [String: Int] = [:]
            for key in free.keys {
                guard let count = int(free, key) else { return nil }
                freeLeft[key] = count
            }
            var credits: Int?
            if o["credits"] != nil {
                guard let value = int(o, "credits") else { return nil }
                credits = value
            }
            return .server(ServerAllowance(freeLeft: freeLeft, credits: credits))
        default:
            return nil
        }
    }
}
