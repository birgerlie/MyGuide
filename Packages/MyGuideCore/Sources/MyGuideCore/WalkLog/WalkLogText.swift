import Foundation

/// One short readable line per event, for the run timeline (spec 4.5). Distances are whole metres.
public enum WalkLogText {
    public static func line(_ kind: WalkLogEvent.Kind) -> String {
        switch kind {
        case .started(let s):
            return "Started (v\(s.appVersion) build \(s.build), location \(s.location.rawValue), motion \(s.motion.rawValue))"
        case .stopped(let reason): return "Stopped: \(reason.rawValue)"
        case .app(let foreground): return foreground ? "App in foreground" : "App in background"
        case .fix(let f):
            let flags = [f.paused ? "paused" : nil, f.dropped.map { "dropped \($0.rawValue)" }].compactMap { $0 }
            let suffix = flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))"
            return "Fix ±\(metres(f.accuracy)) m\(suffix)"
        case .gps(let found): return found ? "GPS found" : "GPS lost"
        case .fetchStarted: return "Fetching places"
        case .fetched(let count, let top, let good, _, _): return "Fetched \(count) places (\(top) top, \(good) good)"
        case .fetchFailed(let error): return "Fetch failed: \(error)"
        case .quiet(let reason, let due):
            guard !due.isEmpty else { return "Quiet: \(reason.rawValue)" }
            return "Quiet: \(reason.rawValue) · " + due.map { "\($0.name) \(metres($0.distance)) m" }.joined(separator: ", ")
        case .buzz(let b): return "Buzz: \(b.name) · \(metres(b.distance)) m" + (b.override ? " (override)" : "")
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
        case .paused(let trigger, _): return "Paused (\(trigger.rawValue))"
        case .resumed(let trigger, let seconds): return "Resumed (\(trigger.rawValue)) after \(Int((seconds / 60).rounded(.down))) min"
        case .failure(let context, let error): return "Failure in \(context): \(error)"
        }
    }

    private static func metres(_ value: Double) -> Int { Int(value.rounded()) }
}
