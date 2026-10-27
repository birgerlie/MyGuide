import Foundation

/// One row of the per-kind table in the buzz log.
public struct KindCount: Sendable, Equatable {
    public var kind: String
    public var buzzes, heard, skipped, ignored: Int

    public init(kind: String, buzzes: Int, heard: Int, skipped: Int, ignored: Int) {
        self.kind = kind
        self.buzzes = buzzes
        self.heard = heard
        self.skipped = skipped
        self.ignored = ignored
    }
}

/// The buzz log as a table of counts and as a CSV file.
public enum BuzzLogExport {
    public static let header = "time,place,kind,tier,distance_m,outcome,level"

    /// Per kind: buzzes (every entry, a pending one included) and how they ended. Most buzzes first, then by kind.
    public static func counts(_ entries: [BuzzLogEntry]) -> [KindCount] {
        var byKind: [String: KindCount] = [:]
        for entry in entries {
            var count = byKind[entry.kind] ?? KindCount(kind: entry.kind, buzzes: 0, heard: 0, skipped: 0, ignored: 0)
            count.buzzes += 1
            switch entry.outcome {
            case .heard: count.heard += 1
            case .skipped: count.skipped += 1
            case .ignored: count.ignored += 1
            case .pending: break
            }
            byKind[entry.kind] = count
        }
        return byKind.values.sorted { $0.buzzes != $1.buzzes ? $0.buzzes > $1.buzzes : $0.kind < $1.kind }
    }

    /// The header and one line per entry (in the given order), each ending in "\n".
    public static func csv(_ entries: [BuzzLogEntry]) -> String {
        let formatter = Date.ISO8601FormatStyle(timeZone: .gmt)
        var out = header + "\n"
        for entry in entries {
            let fields = [entry.at.formatted(formatter), entry.placeName, entry.kind, String(entry.tier),
                          String(Int(entry.distance.rounded())), entry.outcome.rawValue, String(entry.deepestLevel)]
            out += fields.map(field).joined(separator: ",") + "\n"
        }
        return out
    }

    /// RFC 4180: a field with a comma, a quote or a line break is quoted, inner quotes doubled.
    private static func field(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
