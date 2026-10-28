import Foundation

public enum PromptBuilder {
    /// Prior story texts are cut to this many characters before they go into a prompt.
    static let priorTextLimit = 240

    /// The guide's voice: one constant, byte-identical for every story request (photo, buzz, stop, continuation,
    /// both languages), so the request prefix can be cached. Language and length go in the user message.
    public static let systemInstructions = """
        You are a brilliant private guide walking beside the user. You have the depth of a historian, the eye of an architect, the palate of a food writer and the curiosity of a scientist, and you wear it lightly — like a well-read friend, not a lecturer.

        CONTEXT YOU RECEIVE
        Each request is a structured message: where the user stands (street address, district and city from Apple Maps), the local time, which way they face or walk, where they came from if they are walking, nearby named places with their distance and side, facts about those places from OpenStreetMap and Wikipedia, what you have already told them, and sometimes a photo they just took. Treat these as what is actually in front of them.

        WHAT TO DO
        - Start with the single most striking thing about where they stand. No greeting, no "welcome to", no restating the location.
        - Give the number of short, vivid points the request asks for. Favour the specific over the general: a name, a date, a number, a detail they can look up and see with their own eyes right now ("notice the pockmarks on the left column — those are from…").
        - Mix domains naturally when the place invites it: how it was built, who lived or died here, what people ate here and still do, the geology, optics, acoustics or engineering behind what they see. Don't force all four every time.
        - Prefer the surprising-but-true over the famous-and-obvious. Assume the user has already read the plaque.
        - If it's near a meal time and there's a real local dish or ingredient tied to this place or district, mention it in one line — what it is, why here. Never recommend a particular restaurant, café or shop.
        - If a photo is included, talk about what is actually in the frame first.
        - End with one optional, concrete nudge: "If you walk 80 m to your right…" or a question that will make them look closer. Only one. For directions, use only the places, distances and sides given to you.

        HOW TO SOUND
        - Warm, confident, lightly witty. Short sentences. Spoken rhythm — this will be read aloud.
        - No bullet points, no headers, no emojis. Plain flowing prose at the length the request asks for.
        - Answer in the language the request names.

        HONESTY
        - Only state things you are genuinely confident are true of this specific place. If you are unsure whether a detail belongs here or somewhere similar, say "I believe" or leave it out. A guide who invents is worse than a guide who says less.
        - The facts in the request are your ground. Never invent names, dates, numbers or quotes. Label legend, tradition or disputed history as such ("legend has it").
        - Never repeat anything listed under "Told in the last 3 hours" or "Told here before"; find a new point.
        - Never pad. If the spot is genuinely unremarkable, say so in one sentence and tell them what *is* nearby that's worth the detour. If the facts run out before the requested length, stop shorter.
        - If nothing is known about what is in a photo, talk about what can actually be seen — building style, materials, plants, rock, light — and say plainly that you know no recorded history of it.
        """

    /// Sent as `prompt_cache_key` with every story request.
    public static let promptCacheKey = "myguide-story-v1"

    /// The photo story's first level (spec 6): the model identifies the subject among the ranked candidates and tells about it.
    static func photoFirstInput(capture: CaptureContext, grounding: Grounding, recent: [RecentStory],
                                priors: [PriorStory], language: StoryLanguage, now: Date, timeZone: TimeZone) -> String {
        let heading = capture.usableHeading
        var lines = ["Story: photo, first level"]
        lines.append(contentsOf: positionLines(capture: capture, address: grounding.address))
        lines.append("Time: \(GuideText.time(now, timeZone: timeZone))")
        lines.append(facingLine(capture))
        lines.append(contentsOf: mapDataLines(grounding))
        if grounding.candidates.isEmpty {
            lines.append("Nearby: none found")
        } else {
            lines.append("Nearby:")
            lines.append(contentsOf: grounding.candidates.flatMap { candidateLines($0, heading: heading) })
        }
        lines.append(contentsOf: appleMapsLines(grounding.applePlaces, from: capture.coordinate, direction: heading,
                                                knownNames: grounding.candidates.map(\.candidate.name)))
        lines.append(contentsOf: toldLines(recent: recent, priors: priors, timeZone: timeZone))
        lines.append(StoryLength.of(kind: .photo, level: .first, tier: nil).line)
        lines.append("Answer in: \(language.promptName)")
        lines.append("Task: Identify what the photo shows, preferring places in view. Set matchedCandidateID only if the subject is one of the listed places (use its id in brackets). Then tell the user about it. If nothing listed matches what you see, talk about what can actually be seen in the frame and say plainly that you know no recorded history of it.")
        return lines.joined(separator: "\n")
    }

    /// A photo story's level 2 or 3. `articleText` is the matched candidate's fuller Wikipedia text, if fetched;
    /// without it the summary stands in.
    static func photoContinuationInput(session: StorySession, level: StoryLevel, articleText: String?,
                                       recent: [RecentStory], priors: [PriorStory], now: Date, timeZone: TimeZone) -> String {
        let capture = session.capture
        let heading = capture.usableHeading
        var lines = ["Story: photo, level \(level.rawValue)"]
        lines.append(contentsOf: positionLines(capture: capture, address: session.grounding.address))
        lines.append("Time: \(GuideText.time(now, timeZone: timeZone))")
        lines.append(facingLine(capture))
        lines.append(contentsOf: mapDataLines(session.grounding))
        var subject = "Subject: \(session.identified.subject) (confidence: \(session.identified.confidence.rawValue))"
        if let matched = session.matchedCandidate {
            subject += ", " + GuideText.distanceAndSide(distance: matched.distance, bearing: matched.bearing, direction: heading)
        }
        lines.append(subject)

        let listed = factCandidates(for: session)
        if let matched = session.matchedCandidate {
            let c = matched.candidate
            let facts = factLines(c, articleText: articleText)
            lines.append(facts.isEmpty ? "Facts about \(c.name): none found" : "Facts about \(c.name):")
            lines.append(contentsOf: facts)
        } else if listed.isEmpty {
            lines.append("Facts: none found")
        } else {
            lines.append("Nearby:")
            lines.append(contentsOf: listed.flatMap { candidateLines($0, heading: heading) })
        }
        lines.append(contentsOf: appleMapsLines(session.grounding.applePlaces, from: capture.coordinate, direction: heading,
                                                knownNames: listed.map(\.candidate.name)))

        lines.append(contentsOf: toldSoFarLines(session.levels))
        lines.append(contentsOf: toldLines(recent: recent, priors: priors, timeZone: timeZone))
        lines.append(StoryLength.of(kind: .photo, level: level, tier: nil).line)
        lines.append("Answer in: \(session.language.promptName)")
        lines.append(continuationTask)
        return lines.joined(separator: "\n")
    }

    /// The task of every level 2 and 3, photo and walking.
    static let continuationTask = "Task: Continue from where the story left off; new points, from another domain where the facts allow; do not repeat."

    /// `Told so far:` with every level in full.
    private static func toldSoFarLines(_ levels: [String]) -> [String] {
        ["Told so far:"] + levels.enumerated().map { "Level \($0.offset + 1): \($0.element)" }
    }

    /// `Position:` (the address, or that its lookup failed), then the coordinates and, for a substitute position, the warning.
    private static func positionLines(capture: CaptureContext, address: Address?) -> [String] {
        let display = address?.display ?? ""
        var lines = [display.isEmpty ? "Position: address lookup failed" : "Position: \(display)"]
        if let c = capture.coordinate {
            var coordinates = String(format: "Coordinates: %.6f, %.6f", c.latitude, c.longitude)
            if let acc = capture.horizontalAccuracy { coordinates += " (accuracy ±\(Int(acc.rounded())) m)" }
            lines.append(coordinates)
            if capture.positionIsSubstitute {
                lines.append("Position is where the listener is now, not necessarily where the photo was taken; trust the photo over the places list.")
            }
        }
        return lines
    }

    private static func facingLine(_ capture: CaptureContext) -> String {
        guard let heading = capture.usableHeading, let acc = capture.headingAccuracy else {
            return "Facing: unknown — identify the subject from position and the photo alone, and be more cautious."
        }
        return "Facing: \(FieldOfView.compassPoint(heading)) (\(wholeDegrees(heading))°), compass ±\(Int(acc.rounded()))°"
    }

    /// `- [id] Name (kind), 40 m, behind, in view` plus its summary and OSM facts on indented lines.
    /// The view flag only appears with a usable heading.
    private static func candidateLines(_ ranked: RankedCandidate, heading: Double?) -> [String] {
        let c = ranked.candidate
        var line = "- [\(c.id)] \(c.name) (\(c.kind)), "
            + GuideText.distanceAndSide(distance: ranked.distance, bearing: ranked.bearing, direction: heading)
        if heading != nil, let inView = ranked.inView {
            line += inView ? ", in view" : ", out of view"
        }
        var lines = [line]
        if let summary = c.summary, !isBlank(summary) { lines.append("  Summary: \(summary)") }
        if let osm = GuideText.osmFacts(c.tags) { lines.append("  \(osm)") }
        return lines
    }

    /// `Map data unavailable: …` naming the failed sources, or nothing when none failed.
    private static func mapDataLines(_ grounding: Grounding) -> [String] {
        guard !grounding.failedSources.isEmpty else { return [] }
        return ["Map data unavailable: \(grounding.failedSources.map(sourceName).joined(separator: ", ")). Be more cautious."]
    }

    /// The indented facts under `Facts about`: the OSM fact tags, then `Wikipedia:` with the fuller article text or,
    /// when it is missing or blank, the summary. Empty when there is neither.
    private static func factLines(_ c: Candidate, articleText: String?) -> [String] {
        var facts: [String] = []
        if let osm = GuideText.osmFacts(c.tags) { facts.append("  \(osm)") }
        if let text = [articleText, c.summary].compactMap({ $0 }).first(where: { !isBlank($0) }) {
            facts.append("  Wikipedia: \(text)")
        }
        return facts
    }

    /// `Also on Apple Maps:` with the selected places (nearest first, none repeating a name listed in the request), or
    /// nothing when none are left or there is no position to measure from.
    private static func appleMapsLines(_ places: [ApplePlace]?, from: Coordinate?, direction: Double?,
                                       knownNames: [String]) -> [String] {
        guard let places, let from else { return [] }
        let selected = ApplePlaces.select(places, from: from, knownNames: knownNames)
        guard !selected.isEmpty else { return [] }
        return ["Also on Apple Maps:"] + selected.map { place in
            "- \(place.name) (\(place.category)), " + distanceAndSide(from: from, to: place.coordinate, direction: direction)
        }
    }

    private static func distanceAndSide(from: Coordinate, to: Coordinate, direction: Double?) -> String {
        GuideText.distanceAndSide(distance: GeoMath.distance(from, to), bearing: GeoMath.bearing(from: from, to: to),
                                  direction: direction)
    }

    /// `Told in the last 3 hours:` (at most `RecentStories.limit`, in the order given) and `Told here before:` (the priors
    /// not already listed as recent). A recent story beyond the limit is not listed, so a prior repeating it stays.
    private static func toldLines(recent: [RecentStory], priors: [PriorStory], timeZone: TimeZone) -> [String] {
        let shown = Array(recent.prefix(RecentStories.limit))
        let before = RecentStories.priorsNotRecent(priors, recent: shown)
        let recentBlock = shown.isEmpty ? ["Told in the last 3 hours: nothing"]
            : ["Told in the last 3 hours:"] + shown.map { RecentStories.line($0, timeZone: timeZone) }
        let beforeBlock = before.isEmpty ? ["Told here before: nothing"] : ["Told here before:"] + before.map(priorLine)
        return recentBlock + beforeBlock
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static let firstStorySchema: JSONValue = .object([
        "type": "object",
        "additionalProperties": false,
        "required": ["subject", "confidence", "matchedCandidateID", "title", "era", "story"],
        "properties": .object([
            "subject": .object(["type": "string",
                                "description": "What the photo shows, e.g. 'St. Michael's Church, main portal'"]),
            "confidence": .object(["type": "string", "enum": ["certain", "likely", "unsure"]]),
            "matchedCandidateID": .object(["type": ["string", "null"]]),
            "title": .object(["type": "string", "description": "3–8 word title"]),
            "era": .object(["type": "string",
                            "description": "The era the subject is best known from, e.g. 'built 1697' or 'around 1780'"]),
            "story": .object(["type": "string"]),
        ]),
    ])

    static let continuationSchema: JSONValue = .object([
        "type": "object",
        "additionalProperties": false,
        "required": ["story"],
        "properties": .object(["story": .object(["type": "string"])]),
    ])

    /// Decodes the model's JSON. A matchedCandidateID that is not among the grounding candidates is dropped,
    /// and a "certain" identification resting on that invented id is downgraded to "likely".
    static func decodeFirstStory(_ json: Data, grounding: Grounding) throws -> IdentifiedStory {
        var story: IdentifiedStory
        do {
            story = try JSONDecoder().decode(IdentifiedStory.self, from: json)
        } catch is DecodingError {
            throw OpenAIError.malformedResponse
        }
        if let id = story.matchedCandidateID, !grounding.candidates.contains(where: { $0.candidate.id == id }) {
            story.matchedCandidateID = nil
            if story.confidence == .certain { story.confidence = .likely }
        }
        return story
    }

    /// The places whose facts a continuation is grounded in: the matched candidate alone, or else the
    /// first three in view, or, when none is in view or the heading is unknown, the nearest three (ranked order).
    static func factCandidates(for session: StorySession) -> [RankedCandidate] {
        if let matched = session.matchedCandidate { return [matched] }
        let ranked = session.grounding.candidates
        let inView = ranked.filter { $0.inView == true }
        return Array((inView.isEmpty ? ranked : inView).prefix(3))
    }

    // MARK: Walking mode

    static let walkStorySchema: JSONValue = .object([
        "type": "object",
        "additionalProperties": false,
        "required": ["title", "story"],
        "properties": .object([
            "title": .object(["type": "string", "description": "3–8 word title"]),
            "story": .object(["type": "string"]),
        ]),
    ])

    /// Most places listed under `Nearby:` in a buzz request.
    static let walkBuzzNeighbourLimit = 4

    /// What a stop story is told from (spec 9): places right here, or else the best ones worth a detour.
    enum WalkStop: Equatable {
        /// `stopFacts`, best first; never empty.
        case here([WalkingPlace])
        /// `detourFacts`, best first; never empty.
        case detour([WalkingPlace])

        var places: [WalkingPlace] {
            switch self {
            case .here(let places), .detour(let places): places
            }
        }
    }

    /// The stop ladder: places within `stopFactRadius`, else the best within `detourRadius`, else nil (no stop story).
    /// Looks only at the OSM/Wikipedia places walking mode already has.
    static func walkStop(_ nearby: [WalkingPlace], position: Coordinate) -> WalkStop? {
        let here = stopFacts(nearby, position: position)
        if !here.isEmpty { return .here(here) }
        let detour = detourFacts(nearby, position: position)
        return detour.isEmpty ? nil : .detour(detour)
    }

    /// A buzz story's first level (spec 6): the buzzed place as the subject, its neighbours as `Nearby:`.
    static func walkBuzzInput(buzz: Buzz, position: Coordinate, context: WalkContext, nearby: [WalkingPlace],
                              articleText: String?, applePlaces: [ApplePlace]?, recent: [RecentStory], priors: [PriorStory],
                              language: StoryLanguage, now: Date, timeZone: TimeZone) -> String {
        let place = buzz.place.candidate
        let direction = usableDirection(context.bearing)
        var lines = ["Story: walking buzz, first level"]
        lines.append(contentsOf: walkPositionLines(context.address, position: position))
        lines.append("Time: \(GuideText.time(now, timeZone: timeZone))")
        lines.append(walkingLine(direction: direction, street: context.street))
        if let cameFrom = context.cameFrom { lines.append(cameFromLine(cameFrom, direction: direction)) }
        lines.append("Subject: \(place.name) (\(place.kind)), "
                     + GuideText.distanceAndSide(distance: buzz.distance, bearing: buzz.bearing, direction: direction))
        let facts = factLines(place, articleText: articleText)
        if !facts.isEmpty { lines.append("Facts about \(place.name):") }
        lines.append(contentsOf: facts)
        let others = buzzFacts(nearby, excluding: place.id, position: position)
        lines.append(contentsOf: walkPlaceLines("Nearby:", others, from: position, direction: direction, withFacts: true))
        lines.append(contentsOf: appleMapsLines(applePlaces, from: position, direction: direction,
                                                knownNames: [place.name] + others.map(\.candidate.name)))
        lines.append(contentsOf: toldLines(recent: recent, priors: priors, timeZone: timeZone))
        lines.append(StoryLength.of(kind: .buzz, level: .first, tier: buzz.place.tier).line)
        lines.append("Answer in: \(language.promptName)")
        lines.append("Task: Tell the user about the subject they are passing.")
        return lines.joined(separator: "\n")
    }

    /// A stop story's first level: the best place here under `Facts about` and the rest as `Nearby:`, or, with nothing
    /// here, the places `Worth the detour:` (spec 9 step 2). No came-from: a stop story follows a standstill.
    static func walkStopInput(_ stop: WalkStop, position: Coordinate, context: WalkContext, articleText: String?,
                              applePlaces: [ApplePlace]?, recent: [RecentStory], priors: [PriorStory],
                              language: StoryLanguage, now: Date, timeZone: TimeZone) -> String {
        let direction = usableDirection(context.bearing)
        var lines = ["Story: stop, first level"]
        lines.append(contentsOf: walkPositionLines(context.address, position: position))
        lines.append("Time: \(GuideText.time(now, timeZone: timeZone))")
        lines.append(standingLine(direction: direction, street: context.street))
        let tier: PlaceTier?
        let task: String
        switch stop {
        case .here(let listed):
            if let best = listed.first {
                // No Subject line on a stop story, so the facts header carries the place's kind, distance and side.
                let header = "Facts about \(best.candidate.name) (\(best.candidate.kind)), "
                    + distanceAndSide(from: position, to: best.candidate.coordinate, direction: direction)
                let facts = factLines(best.candidate, articleText: articleText)
                lines.append(facts.isEmpty ? header + ": none found" : header + ":")
                lines.append(contentsOf: facts)
            }
            lines.append(contentsOf: walkPlaceLines("Nearby:", Array(listed.dropFirst()), from: position,
                                                    direction: direction, withFacts: true))
            tier = listed.first?.tier
            task = "Task: Tell the user about the spot where they are standing."
        case .detour(let places):
            lines.append(contentsOf: walkPlaceLines("Worth the detour:", places, from: position, direction: direction,
                                                    withFacts: false))
            tier = nil
            task = "Task: There is little to tell right here: say so in one sentence, then point them to the place worth the detour."
        }
        lines.append(contentsOf: appleMapsLines(applePlaces, from: position, direction: direction,
                                                knownNames: stop.places.map(\.candidate.name)))
        lines.append(contentsOf: toldLines(recent: recent, priors: priors, timeZone: timeZone))
        lines.append(StoryLength.of(kind: .stop, level: .first, tier: tier).line)
        lines.append("Answer in: \(language.promptName)")
        lines.append(task)
        return lines.joined(separator: "\n")
    }

    /// A walking story's level 2 or 3. Position, address and direction are the stored story's (the flow has no fresher
    /// position on "More"); no came-from. A buzz keeps its subject and facts; a stop lists the places around it again.
    /// `applePlaces` are the first level's, or a fresh search's when those are missing.
    static func walkContinuationInput(story: WalkStory, level: StoryLevel, nearby: [WalkingPlace], articleText: String?,
                                      applePlaces: [ApplePlace]?, recent: [RecentStory], priors: [PriorStory],
                                      now: Date, timeZone: TimeZone) -> String {
        let direction = usableDirection(story.course)
        let street = GuideText.streetName(fromAddressLine: story.address?.line)
        let name = switch story.kind {
        case .buzz: "walking buzz"
        case .stop: "stop"
        }
        var lines = ["Story: \(name), level \(level.rawValue)"]
        lines.append(contentsOf: walkPositionLines(story.address, position: story.position))
        lines.append("Time: \(GuideText.time(now, timeZone: timeZone))")
        switch story.kind {
        case .buzz:
            lines.append(walkingLine(direction: direction, street: street))
            if let place = story.place {
                lines.append("Subject: \(place.name) (\(place.kind)), "
                             + distanceAndSide(from: story.position, to: place.coordinate, direction: direction))
                let facts = factLines(place, articleText: articleText)
                if !facts.isEmpty { lines.append("Facts about \(place.name):") }
                lines.append(contentsOf: facts)
            }
        case .stop:
            lines.append(standingLine(direction: direction, street: street))
            switch walkStop(nearby, position: story.position) {
            case .here(let places):
                lines.append(contentsOf: walkPlaceLines("Nearby:", places, from: story.position, direction: direction,
                                                        withFacts: true))
            case .detour(let places):
                lines.append(contentsOf: walkPlaceLines("Worth the detour:", places, from: story.position,
                                                        direction: direction, withFacts: false))
            case nil:
                break
            }
        }
        lines.append(contentsOf: appleMapsLines(applePlaces, from: story.position, direction: direction,
                                                knownNames: walkContinuationPlaces(story, nearby: nearby).map(\.name)))
        lines.append(contentsOf: toldSoFarLines(story.levels))
        lines.append(contentsOf: toldLines(recent: recent, priors: priors, timeZone: timeZone))
        lines.append(StoryLength.of(kind: storyKind(story.kind), level: level, tier: nil).line)
        lines.append("Answer in: \(story.language.promptName)")
        lines.append(continuationTask)
        return lines.joined(separator: "\n")
    }

    /// The places a walking continuation lists: a buzz's subject, or the stop ladder's places around the story's position.
    static func walkContinuationPlaces(_ story: WalkStory, nearby: [WalkingPlace]) -> [Candidate] {
        switch story.kind {
        case .buzz: story.place.map { [$0] } ?? []
        case .stop: walkStop(nearby, position: story.position)?.places.map(\.candidate) ?? []
        }
    }

    static func storyKind(_ kind: WalkStory.Kind) -> StoryKind {
        switch kind {
        case .buzz: .buzz
        case .stop: .stop
        }
    }

    /// The places a buzz prompt lists besides the buzzed one: best tier first, then nearest.
    static func buzzFacts(_ facts: [WalkingPlace], excluding placeID: String, position: Coordinate) -> [WalkingPlace] {
        nearest(facts.filter { $0.candidate.id != placeID }, to: position, limit: walkBuzzNeighbourLimit)
    }

    /// The places a stop prompt lists: within `stopFactRadius`, best tier first, then nearest, at most `factLimit`.
    static func stopFacts(_ facts: [WalkingPlace], position: Coordinate) -> [WalkingPlace] {
        nearest(facts.filter { GeoMath.distance(position, $0.candidate.coordinate) <= WalkingStoryFlow.stopFactRadius },
                to: position, limit: WalkingStoryFlow.factLimit)
    }

    /// The places a stop story points to when nothing is within `stopFactRadius`: within `detourRadius`, best tier
    /// first, then nearest, at most `detourLimit`.
    static func detourFacts(_ facts: [WalkingPlace], position: Coordinate) -> [WalkingPlace] {
        nearest(facts.filter { GeoMath.distance(position, $0.candidate.coordinate) <= WalkingStoryFlow.detourRadius },
                to: position, limit: WalkingStoryFlow.detourLimit)
    }

    private struct WalkStoryText: Decodable { var title: String; var story: String }

    /// Decodes the walking story JSON. An empty or whitespace-only story is malformed.
    static func decodeWalkStory(_ json: Data) throws -> (title: String, story: String) {
        let decoded: WalkStoryText
        do {
            decoded = try JSONDecoder().decode(WalkStoryText.self, from: json)
        } catch is DecodingError {
            throw OpenAIError.malformedResponse
        }
        guard !decoded.story.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIError.malformedResponse
        }
        return (decoded.title, decoded.story)
    }

    /// Tier first, then distance from `position`; ties keep the input order.
    private static func nearest(_ places: [WalkingPlace], to position: Coordinate, limit: Int) -> [WalkingPlace] {
        let sorted = places.enumerated().sorted { a, b in
            if a.element.tier != b.element.tier { return a.element.tier < b.element.tier }
            let da = GeoMath.distance(position, a.element.candidate.coordinate)
            let db = GeoMath.distance(position, b.element.candidate.coordinate)
            return da != db ? da < db : a.offset < b.offset
        }
        return Array(sorted.prefix(limit).map(\.element))
    }

    /// `Position:` with the address, or that its lookup failed plus the coordinates.
    private static func walkPositionLines(_ address: Address?, position: Coordinate) -> [String] {
        let display = address?.display ?? ""
        guard display.isEmpty else { return ["Position: \(display)"] }
        return ["Position: address lookup failed",
                String(format: "Coordinates: %.6f, %.6f", position.latitude, position.longitude)]
    }

    /// A direction a side can be measured against: finite and not negative (as `GuideText.side` requires).
    private static func usableDirection(_ direction: Double?) -> Double? {
        guard let direction, direction.isFinite, direction >= 0 else { return nil }
        return direction
    }

    /// ` along Kirkegata`, or nothing without a street.
    private static func alongStreet(_ street: String?) -> String {
        guard let street, !isBlank(street) else { return "" }
        return " along \(street)"
    }

    /// `Walking: north along Kirkegata`, `Walking: north` or `Walking: direction unknown`.
    private static func walkingLine(direction: Double?, street: String?) -> String {
        guard let direction else { return "Walking: direction unknown" }
        return "Walking: \(FieldOfView.compassPoint(direction))" + alongStreet(street)
    }

    /// `Standing still; walked in heading north along Kirkegata`, or `Standing still` without a direction.
    private static func standingLine(direction: Double?, street: String?) -> String {
        guard let direction else { return "Standing still" }
        return "Standing still; walked in heading \(FieldOfView.compassPoint(direction))" + alongStreet(street)
    }

    /// `Came from: Stortorvet, 3 min ago, 220 m, behind, along Kirkegata`; 0 minutes reads `under a minute ago`.
    private static func cameFromLine(_ cameFrom: CameFrom, direction: Double?) -> String {
        let ago = cameFrom.minutesAgo <= 0 ? "under a minute ago" : "\(cameFrom.minutesAgo) min ago"
        return "Came from: \(cameFrom.street), \(ago), "
            + GuideText.distanceAndSide(distance: cameFrom.distance, bearing: cameFrom.bearing, direction: direction)
            + (cameFrom.along.map { ", along \($0)" } ?? "")
    }

    /// `heading` then `- Name (kind), 40 m, ahead` per place, with its OSM facts indented when `withFacts`; nothing for
    /// no places.
    private static func walkPlaceLines(_ heading: String, _ places: [WalkingPlace], from: Coordinate, direction: Double?,
                                       withFacts: Bool) -> [String] {
        guard !places.isEmpty else { return [] }
        return [heading] + places.flatMap { place -> [String] in
            let c = place.candidate
            var lines = ["- \(c.name) (\(c.kind)), " + distanceAndSide(from: from, to: c.coordinate, direction: direction)]
            if withFacts, let osm = GuideText.osmFacts(c.tags) { lines.append("  \(osm)") }
            return lines
        }
    }

    private struct Continuation: Decodable { var story: String }

    /// Prompt for the labelled "then" reconstruction image (spec 8.1.7). No theme in phase 1.
    static func thenImagePrompt(session: StorySession) -> String {
        var place = ""
        if let address = session.grounding.address?.display, !address.isEmpty { place = " at \(address)" }
        return "Historical reconstruction illustration of \(session.identified.subject)\(place), as it looked \(session.identified.era). "
            + "Street-level view from roughly where the photographer stood, people of that time going about their day in period clothing, "
            + "with the carts, trades and sounds of the era suggested in the scene. "
            + "Painterly illustration style with visible brushwork, clearly not a photograph. "
            + "No text, no captions, no modern objects."
    }

    /// Decodes the continuation JSON. An empty or whitespace-only story is malformed.
    static func decodeContinuation(_ json: Data) throws -> String {
        let story: String
        do {
            story = try JSONDecoder().decode(Continuation.self, from: json).story
        } catch is DecodingError {
            throw OpenAIError.malformedResponse
        }
        guard !story.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIError.malformedResponse
        }
        return story
    }

    private static func priorLine(_ prior: PriorStory) -> String {
        let place = prior.placeID ?? "nearby, unidentified"
        return "- [\(place)] level \(prior.level.rawValue): \(TextTrim.truncate(prior.text, maxCharacters: priorTextLimit))"
    }

    /// Nearest whole degree in 0...359; 359.6 prints as 0, never 360.
    private static func wholeDegrees(_ degrees: Double) -> Int {
        let n = Int(degrees.rounded()) % 360
        return n < 0 ? n + 360 : n
    }

    private static func sourceName(_ source: GroundingSource) -> String {
        switch source {
        case .openStreetMap: "OpenStreetMap"
        case .wikipedia: "Wikipedia"
        case .geocoder: "address lookup"
        }
    }
}
