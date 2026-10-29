import Foundation
import Testing
@testable import MyGuideCore

/// The card's honesty rules while a photo story streams (spec 6, 14.10) and after it is decoded.
@Suite struct PlaceCardTests {
    /// 120 m due north of the photo at (0, 0): in the list and the guess.
    static let tower = Candidate(id: "osm:node/7", name: "Tower", coordinate: .at(north: 120), kind: "man_made=tower")
    /// 200 m due north: in the list, not the guess.
    static let hall = Candidate(id: "osm:node/9", name: "Hall", coordinate: .at(north: 200), kind: "building=yes")
    static let guess = RankedCandidate(candidate: tower, distance: 120, bearing: 0, inView: true)
    static let guessCard = PlaceCard(name: "Tower", distance: 120, bearing: 0, mark: .guess)

    static func card(_ partial: PartialFirstStory, guess: RankedCandidate? = guess) -> PlaceCard? {
        PlaceCard.streaming(partial, guess: guess, photo: .at(), listCandidates: [tower, hall])
    }

    @Test func noConfidenceYetKeepsTheGuess() {
        #expect(Self.card(PartialFirstStory()) == Self.guessCard)
        #expect(Self.card(PartialFirstStory(subject: "Hall")) == Self.guessCard)
        #expect(Self.card(PartialFirstStory(subject: "Hall"), guess: nil) == nil)
    }

    @Test func unsureShowsAtOnce() {
        #expect(Self.card(PartialFirstStory(subject: "X", confidence: "unsure")) == .unsure)
        #expect(Self.card(PartialFirstStory(subject: "X", confidence: "unsure"), guess: nil) == .unsure)
    }

    @Test(arguments: ["certain", "likely"])
    func confidenceBeforeTheIDKeepsMaybe(confidence: String) {
        // The id comes after the confidence in the schema; until it (or a later field) has arrived it may still be
        // invented, so the guess keeps "Kanskje".
        #expect(Self.card(PartialFirstStory(subject: "Hall", confidence: confidence)) == Self.guessCard)
    }

    @Test func idOfTheGuessShowsItIdentifiedInPlace() {
        let card = Self.card(PartialFirstStory(subject: "Tower", confidence: "certain", matchedCandidateID: "osm:node/7"))
        #expect(card == PlaceCard(name: "Tower", distance: 120, bearing: 0, mark: .identified))
    }

    @Test func idOfAnotherListPlaceIsPlacedFromThePhoto() throws {
        let card = try #require(Self.card(PartialFirstStory(subject: "Hall", confidence: "likely",
                                                            matchedCandidateID: "osm:node/9")))
        #expect(card.name == "Hall" && card.mark == .identified)
        // Hall is 200 m due north of the photo at (0, 0): distance 200 m (up to floating point), bearing 0°.
        #expect(abs(try #require(card.distance) - 200) < 0.01)
        #expect(abs(try #require(card.bearing)) < 0.01)
    }

    @Test func idNotInTheListShowsTheSubjectByName() {
        // Sent (from the fresh search) but neither the guess nor in the list: the model's subject, unplaced.
        let card = Self.card(PartialFirstStory(subject: "Old Gate", confidence: "likely", matchedCandidateID: "osm:node/1"))
        #expect(card == PlaceCard(name: "Old Gate", distance: nil, bearing: nil, mark: .identified))
    }

    @Test func aLaterFieldSettlesANullID() {
        // `title` arrived with no id before it: the id was null. The model's subject shows, as the decoded card will.
        let card = Self.card(PartialFirstStory(subject: "Old Gate", confidence: "likely", title: "T"))
        #expect(card == PlaceCard(name: "Old Gate", distance: nil, bearing: nil, mark: .identified))
        // No subject to show: the guess stays.
        #expect(Self.card(PartialFirstStory(subject: "", confidence: "likely", title: "T")) == Self.guessCard)
    }

    @Test func unknownIDNeverDropsMaybeWhileItIsTheLastField() {
        // The flow drops an id that was not sent (and "certain" on it becomes "likely"). While that id is the last
        // field in, the card keeps the guess with "Kanskje" rather than show anything identified.
        let raw = PartialFirstStory(subject: "Tower", confidence: "certain", matchedCandidateID: "osm:999")
        let checked = PhotoStoryFlow.checked(raw, sentIDs: ["osm:node/7", "osm:node/9"])
        #expect(checked.matchedCandidateID == nil && checked.confidence == "likely")
        #expect(Self.card(checked) == Self.guessCard)
        // Without the flow's check the raw id still never places a card: it is not in the list, so the subject
        // shows by name, never a placed (distance and direction) card for an id nobody sent.
        #expect(Self.card(raw)?.distance == nil)
    }

    @Test func streamedMarksNeverGoBackToMaybe() {
        // The whole stream of an invented-id story, chunk by chunk, through the parser, the flow's check and the card.
        let chunks = [#"{"subject":"Tower","confidence":"certain","#, #""matchedCandidateID":"osm:999","#,
                      #""title":"T","era":"e","story":"H"#, #"i."}"#]
        var parser = PartialStoryParser()
        var marks: [PlaceCard.Mark] = []
        var last: PlaceCard?
        for chunk in chunks {
            let partial = PhotoStoryFlow.checked(parser.append(chunk), sentIDs: ["osm:node/7", "osm:node/9"])
            last = Self.card(partial)
            if let mark = last?.mark { marks.append(mark) }
        }
        // Chunk 1: confidence, no id yet → guess. Chunk 2: the invented id is dropped and nothing later is in → guess.
        // Chunk 3: title arrived → the subject, identified. Chunk 4: unchanged.
        #expect(marks == [.guess, .guess, .identified, .identified])
        #expect(last == PlaceCard(name: "Tower", distance: nil, bearing: nil, mark: .identified))
    }

    // MARK: - Decoded story

    static func session(_ confidence: SubjectConfidence, matched: String?, subject: String = "Tower") -> StorySession {
        StorySession(id: UUID(), capture: GroundingTests.capture(heading: 0, acc: 10),
                     photoJPEG: Data(), thumbnailJPEG: Data(), language: .english,
                     grounding: Grounding(candidates: [guess], address: nil, failedSources: []),
                     identified: IdentifiedStory(subject: subject, confidence: confidence, matchedCandidateID: matched,
                                                 title: "T", era: "e", story: "S."),
                     levels: ["S."])
    }

    @Test func decodedIdentificationWins() {
        // Whatever the partials showed, the decoded story decides: "unsure" → not-sure card, even with a match.
        #expect(PlaceCard(session: Self.session(.unsure, matched: "osm:node/7")) == .unsure)
        // A match → the matched place, placed.
        #expect(PlaceCard(session: Self.session(.certain, matched: "osm:node/7"))
                == PlaceCard(name: "Tower", distance: 120, bearing: 0, mark: .identified))
        // No match (an invented id is dropped when decoding) → the subject by name.
        #expect(PlaceCard(session: Self.session(.likely, matched: nil, subject: "Old Gate"))
                == PlaceCard(name: "Old Gate", distance: nil, bearing: nil, mark: .identified))
    }
}
