import Foundation

/// Labels shown next to a story when its subject or grounding is uncertain (spec 8.1.5).
public enum StoryBadges {
    public static let mapDataUnavailable = "Less certain: map data unavailable"

    public static func badges(for session: StorySession) -> [String] {
        var badges: [String] = []
        switch session.identified.confidence {
        case .certain: break
        case .likely: badges.append("Probably \(session.identified.subject)")
        case .unsure: badges.append("Not sure: \(session.identified.subject)?")
        }
        // Only the place sources are map data; a missing street address (geocoder) is not.
        let failed = session.grounding.failedSources
        if failed.contains(.openStreetMap) || failed.contains(.wikipedia) {
            badges.append(mapDataUnavailable)
        }
        return badges
    }
}
