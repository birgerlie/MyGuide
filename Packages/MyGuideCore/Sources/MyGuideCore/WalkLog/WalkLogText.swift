import Foundation

/// One short readable line per event, for the run timeline (spec 4.5). Distances are whole metres.
public enum WalkLogText {
    public static func line(_ kind: WalkLogEvent.Kind) -> String {
        switch kind {
        case .started(let s):
            return "Started (v\(s.appVersion) build \(s.build), location \(s.location.rawValue), motion \(s.motion.rawValue))"
        case .stopped(let reason, let source): return "Stopped: \(reason.rawValue)" + (source.map { " (\($0.rawValue))" } ?? "")
        case .app(let foreground): return foreground ? "App in foreground" : "App in background"
        case .fix(let f):
            let flags = [f.paused ? "paused" : nil, f.dropped.map { "dropped \($0.rawValue)" }].compactMap { $0 }
            let suffix = flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))"
            return "Fix ±\(whole(f.accuracy)) m\(suffix)"
        case .gps(let found): return found ? "GPS found" : "GPS lost"
        case .fetchStarted: return "Fetching places"
        case .fetched(let count, let top, let good, _, _, let osmFailed, let osmErrors, _, let dropped, _, let stale):
            return "Fetched \(count) places (\(top) top, \(good) good)" + (osmFailed ? " · OpenStreetMap failed" : "")
                + endpoints(osmErrors) + (dropped.isEmpty ? "" : " · dropped \(dropped.joined(separator: ", "))")
                + (stale ? " · stored list" : "")
        case .fetchFailed(let error, let osmErrors): return "Fetch failed: \(error)" + endpoints(osmErrors)
        case .quiet(let reason, let due):
            guard !due.isEmpty else { return "Quiet: \(reason.rawValue)" }
            return "Quiet: \(reason.rawValue) · " + due.map { "\($0.name) \(whole($0.distance)) m" }.joined(separator: ", ")
        case .buzz(let b):
            return "Buzz: \(b.name) · \(whole(b.distance)) m" + (b.override ? " (override)" : "") + (b.tourStop ? " (tour stop)" : "")
        case .notified(_, let kind, _): return "Notification added (\(kind.rawValue))"
        case .notifyFailed(_, let kind, let error): return "Notification failed (\(kind.rawValue)): \(error)"
        case .busy(let busy): return busy ? "Story engine busy" : "Story engine idle"
        case .storyPreparing: return "Story preparing"
        case .storyReady(_, let seconds): return "Story ready after \(String(format: "%.1f", seconds)) s"
        case .storyFailed(_, let seconds, let error): return "Story failed after \(String(format: "%.1f", seconds)) s: \(error)"
        case .stopDetected: return "Stop detected"
        case .stopStory(let outcome, let title, let error):
            switch outcome {
            case .told: return "Stop story told" + (title.map { ": \($0)" } ?? "")
            case .silent: return "Stop story silent"
            case .failed: return "Stop story failed" + (error.map { ": \($0)" } ?? "")
            }
        case .stopShown(let via): return "Stop story shown (\(via.rawValue))"
        case .motion(let activity, let confidence): return "Motion: \(activity.rawValue) (\(confidence.rawValue))"
        case .paused(let reason, _, let source): return "Paused (\(label(reason, source)))"
        case .resumed(let reason, let seconds, let source): return "Resumed (\(label(reason, source))) after \(whole((seconds / 60).rounded(.down))) min"
        case .failure(let context, let error): return "Failure in \(context): \(error)"
        case .shown(let placeID, let name, let reason):
            return "Map shows \(name ?? placeID ?? "nothing") (\(reason.rawValue))"
        }
    }

    /// The reason, then the source after a comma when a command gave it: "manual, watch".
    private static func label(_ reason: WalkPauseReason, _ source: WalkSource?) -> String {
        [reason.rawValue, source?.rawValue].compactMap { $0 }.joined(separator: ", ")
    }

    /// Whole number as text; "?" for NaN or infinity, clamped to the Int range (a hand-edited log must not crash the timeline).
    private static func whole(_ value: Double) -> String {
        guard value.isFinite else { return "?" }
        let rounded = value.rounded()
        if let exact = Int(exactly: rounded) { return String(exact) }
        return String(rounded < 0 ? Int.min : Int.max)
    }

    /// " (overpass-api.de: timed out; …)" for the endpoint lines; "" for none.
    private static func endpoints(_ errors: [String]) -> String {
        errors.isEmpty ? "" : " (\(errors.joined(separator: "; ")))"
    }
}
