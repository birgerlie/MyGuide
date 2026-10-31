import Testing
@testable import MyGuideCore

struct StoryLengthTests {
    @Test func buzzFirstLevelScalesWithTier() {
        // spec 5: tier 1 → 75, tier 2 → 60, tier 3 / none → 40
        #expect(StoryLength.of(kind: .buzz, level: .first, tier: .top).words == 75)
        #expect(StoryLength.of(kind: .buzz, level: .first, tier: .good).words == 60)
        #expect(StoryLength.of(kind: .buzz, level: .first, tier: .wikiOnly).words == 40)
        #expect(StoryLength.of(kind: .buzz, level: .first, tier: nil).words == 40)
        #expect(StoryLength.of(kind: .buzz, level: .first, tier: .top).points == "2–3")
    }
    @Test func stopFirstLevelIsCappedAt50() {
        // min(75, 50) = 50; min(60, 50) = 50; min(40, 50) = 40
        #expect(StoryLength.of(kind: .stop, level: .first, tier: .top).words == 50)
        #expect(StoryLength.of(kind: .stop, level: .first, tier: .good).words == 50)
        #expect(StoryLength.of(kind: .stop, level: .first, tier: nil).words == 40)
    }
    @Test func photoFirstLevelOpensShortWhateverTheTier() {
        // 75 words · 60 / 150 = 30 s: what it is and why it matters; the tier does not change it.
        for tier in [PlaceTier.top, .good, .wikiOnly, nil] as [PlaceTier?] {
            #expect(StoryLength.of(kind: .photo, level: .first, tier: tier) == StoryLength(words: 75, points: "2–3"))
        }
        #expect(StoryLength.of(kind: .photo, level: .first, tier: nil).seconds == 30)
    }
    @Test func ownerTriggeredLevelsAre200ThenEvenMore300() {
        for kind in [StoryKind.photo, .buzz, .stop] {
            #expect(StoryLength.of(kind: kind, level: .more, tier: .top) == StoryLength(words: 200, points: "3–4"))
            #expect(StoryLength.of(kind: kind, level: .evenMore, tier: nil) == StoryLength(words: 300, points: "as many as the facts carry"))
        }
    }
    @Test func lineSpellsSecondsOrMinutes() {
        // 75·60/150 = 30 s; 40·60/150 = 16 s; 200·60/150 = 80 s; 300·60/150 = 120 s = 2 minutes
        #expect(StoryLength(words: 75, points: "2–3").line == "Length: about 75 words (30 seconds spoken), 2–3 points")
        #expect(StoryLength(words: 40, points: "2–3").line == "Length: about 40 words (16 seconds spoken), 2–3 points")
        #expect(StoryLength(words: 200, points: "3–4").line == "Length: about 200 words (80 seconds spoken), 3–4 points")
        #expect(StoryLength(words: 300, points: "as many as the facts carry").line
                == "Length: about 300 words (2 minutes spoken), as many as the facts carry")
    }
    @Test func exactlyOneMinuteIsSingular() {
        // 150·60/150 = 60 s = 1 minute
        #expect(StoryLength(words: 150, points: "3–4").line == "Length: about 150 words (1 minute spoken), 3–4 points")
        // 149·60/150 = 59.6 → 59 s: below a minute
        #expect(StoryLength(words: 149, points: "3–4").seconds == 59)
    }
}
