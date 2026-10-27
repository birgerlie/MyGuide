import Testing
import Foundation
@testable import MyGuideCore

@Suite struct StoryBadgesTests {
    private func session(_ confidence: SubjectConfidence, failed: [GroundingSource]) -> StorySession {
        let capture = CaptureContext(coordinate: Coordinate(latitude: 48.2082, longitude: 16.3738),
                                     horizontalAccuracy: 8, heading: nil, headingAccuracy: nil,
                                     horizontalFOV: 54.88, takenAt: Date(timeIntervalSinceReferenceDate: 0),
                                     source: .camera)
        let identified = IdentifiedStory(subject: "St. Michael's Gate", confidence: confidence, matchedCandidateID: nil,
                                         title: "The gate", era: "1890s", story: "A story.")
        return StorySession(id: UUID(), capture: capture, photoJPEG: Data(), thumbnailJPEG: Data(), language: .english,
                            grounding: Grounding(candidates: [], address: nil, failedSources: failed),
                            identified: identified, levels: ["A story."])
    }

    @Test func confidenceBadges() {
        #expect(StoryBadges.badges(for: session(.certain, failed: [])) == [])
        #expect(StoryBadges.badges(for: session(.likely, failed: [])) == ["Probably St. Michael's Gate"])
        #expect(StoryBadges.badges(for: session(.unsure, failed: [])) == ["Not sure: St. Michael's Gate?"])
    }

    @Test func mapDataBadgeOnlyForMapSources() {
        let mapBadge = "Less certain: map data unavailable"
        #expect(StoryBadges.badges(for: session(.certain, failed: [.openStreetMap])) == [mapBadge])
        #expect(StoryBadges.badges(for: session(.certain, failed: [.wikipedia])) == [mapBadge])
        #expect(StoryBadges.badges(for: session(.certain, failed: [.openStreetMap, .wikipedia, .geocoder])) == [mapBadge])
        // A street-address miss is not map data.
        #expect(StoryBadges.badges(for: session(.certain, failed: [.geocoder])) == [])
    }

    @Test func combinedBadgesKeepOrder() {
        #expect(StoryBadges.badges(for: session(.unsure, failed: [.geocoder, .wikipedia]))
                == ["Not sure: St. Michael's Gate?", "Less certain: map data unavailable"])
    }
}
