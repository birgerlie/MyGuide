import Foundation

/// The place card above a photo story: name, distance and direction (spec 6, 14.10). The app words it in the story
/// language ("Kanskje:" / "Maybe:" for a guess, the not-sure sentence for "unsure").
public struct PlaceCard: Sendable, Equatable {
    public enum Mark: Sendable, Equatable {
        /// From the nearby list before the model has identified the place: "Kanskje:" / "Maybe:".
        case guess
        /// The model's identification ("certain" or "likely").
        case identified
        /// The model is not sure: the card shows the not-sure sentence instead of a place.
        case unsure
    }

    public var name: String
    /// Metres from the photo; nil when the place is known by name only.
    public var distance: Double?
    /// Degrees clockwise from north; nil when the place is known by name only.
    public var bearing: Double?
    public var mark: Mark

    public static let unsure = PlaceCard(name: "", distance: nil, bearing: nil, mark: .unsure)

    public init(name: String, distance: Double?, bearing: Double?, mark: Mark) {
        self.name = name
        self.distance = distance
        self.bearing = bearing
        self.mark = mark
    }

    public init(guess: RankedCandidate) {
        self.init(name: guess.candidate.name, distance: guess.distance, bearing: guess.bearing, mark: .guess)
    }

    public init(identified: RankedCandidate) {
        self.init(name: identified.candidate.name, distance: identified.distance, bearing: identified.bearing,
                  mark: .identified)
    }

    /// The decoded story's card, which replaces whatever the partials showed: the not-sure sentence, the matched
    /// place, or the model's subject by name (an invented id was already dropped when the story was decoded).
    public init(session: StorySession) {
        if session.identified.confidence == .unsure {
            self = .unsure
        } else if let matched = session.matchedCandidate {
            self.init(identified: matched)
        } else {
            self.init(name: session.identified.subject, distance: nil, bearing: nil, mark: .identified)
        }
    }

    /// The card while the story streams, from a partial identification already checked by the flow
    /// (`PhotoStoryProgress.partial`: an id that was not sent is dropped there).
    ///
    /// The schema sends `subject`, `confidence`, `matchedCandidateID`, `title`, `era`, `story` in that order, so the
    /// id is settled once it has arrived or any later field has (then it was null, or dropped as not sent):
    /// - no confidence yet: the guess stays, marked "Kanskje:" / "Maybe:" (nil without a guess);
    /// - "unsure": the not-sure card at once;
    /// - "certain" or "likely" with the id not yet settled: the guess stays, still "Kanskje:", so the card never
    ///   loses "Kanskje" on an id that may turn out invented;
    /// - settled with an id: the matched place, placed from `guess` when it is that place, else from
    ///   `listCandidates` relative to `photo`; otherwise the model's subject by name;
    /// - settled without an id: the model's subject by name, as the decoded story's card will show it;
    /// - no subject to show: the guess stays.
    public static func streaming(_ partial: PartialFirstStory, guess: RankedCandidate?, photo: Coordinate?,
                                 listCandidates: [Candidate]) -> PlaceCard? {
        let guessCard = guess.map(PlaceCard.init(guess:))
        guard let confidence = partial.confidence.flatMap(SubjectConfidence.init(rawValue:)) else { return guessCard }
        if confidence == .unsure { return .unsure }
        let idSettled = partial.matchedCandidateID != nil || partial.title != nil || partial.era != nil
            || partial.story != nil
        guard idSettled else { return guessCard }
        if let id = partial.matchedCandidateID {
            if let guess, guess.candidate.id == id { return PlaceCard(identified: guess) }
            if let photo, let candidate = listCandidates.first(where: { $0.id == id }) {
                return PlaceCard(name: candidate.name, distance: GeoMath.distance(photo, candidate.coordinate),
                                 bearing: GeoMath.bearing(from: photo, to: candidate.coordinate), mark: .identified)
            }
        }
        guard let subject = partial.subject, !subject.isEmpty else { return guessCard }
        return PlaceCard(name: subject, distance: nil, bearing: nil, mark: .identified)
    }
}
