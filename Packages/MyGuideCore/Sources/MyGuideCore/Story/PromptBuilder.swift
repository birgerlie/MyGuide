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
        """ + "\n\n" + honestySection

    /// The guide voice's HONESTY section, shared word for word by `systemInstructions` and `dayStoryInstructions`.
    static let honestySection = """
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
            lines.append(contentsOf: factsAboutLines(c.name, facts: factLines(c, articleText: articleText)))
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
        if let summary = c.summary.map(GuideText.oneLine), !summary.isEmpty { lines.append("  Summary: \(summary)") }
        if let osm = GuideText.osmFacts(c.tags) { lines.append("  \(osm)") }
        return lines
    }

    /// `Map data unavailable: …` naming the failed sources, or nothing when none failed.
    private static func mapDataLines(_ grounding: Grounding) -> [String] {
        guard !grounding.failedSources.isEmpty else { return [] }
        return ["Map data unavailable: \(grounding.failedSources.map(sourceName).joined(separator: ", ")). Be more cautious."]
    }

    /// The indented facts under `Facts about`: the OSM fact tags, then `Wikipedia:` with the fuller article text or,
    /// when it is missing or blank, the summary, collapsed to one line. Empty when there is neither.
    private static func factLines(_ c: Candidate, articleText: String?) -> [String] {
        var facts: [String] = []
        if let osm = GuideText.osmFacts(c.tags) { facts.append("  \(osm)") }
        if let text = [articleText, c.summary].compactMap({ $0.map(GuideText.oneLine) }).first(where: { !$0.isEmpty }) {
            facts.append("  Wikipedia: \(text)")
        }
        return facts
    }

    /// `Facts about Name:` and its `facts` (`factLines`), or `Facts about Name: none found`.
    private static func factsAboutLines(_ name: String, facts: [String]) -> [String] {
        [facts.isEmpty ? "Facts about \(name): none found" : "Facts about \(name):"] + facts
    }

    /// `Also on Apple Maps:` with the places `ApplePlaces.select` keeps (sights before at most two food places, nearest
    /// first, none repeating a name listed in the request), or nothing when none are left or there is no position.
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

    /// A buzz story's first level (spec 6): the buzzed place as the subject, `neighbours` (`buzzFacts`) as `Nearby:`.
    static func walkBuzzInput(buzz: Buzz, position: Coordinate, context: WalkContext, neighbours: [WalkingPlace],
                              articleText: String?, applePlaces: [ApplePlace]?, recent: [RecentStory], priors: [PriorStory],
                              language: StoryLanguage, now: Date, timeZone: TimeZone) -> String {
        let place = buzz.place.candidate
        let direction = usableDirection(context.bearing)
        var lines = ["Story: walking buzz, first level"]
        lines.append(contentsOf: walkPositionLines(context.address, position: position))
        lines.append("Time: \(GuideText.time(now, timeZone: timeZone))")
        lines.append(walkingLine(direction: direction, street: context.street))
        if let cameFrom = context.cameFrom, let line = cameFromLine(cameFrom, direction: direction) { lines.append(line) }
        lines.append("Subject: \(place.name) (\(place.kind)), "
                     + GuideText.distanceAndSide(distance: buzz.distance, bearing: buzz.bearing, direction: direction))
        let facts = factLines(place, articleText: articleText)
        lines.append(contentsOf: factsAboutLines(place.name, facts: facts))
        lines.append(contentsOf: walkPlaceLines("Nearby:", neighbours, from: position, direction: direction, facts: osmLines))
        lines.append(contentsOf: appleMapsLines(applePlaces, from: position, direction: direction,
                                                knownNames: [place.name] + neighbours.map(\.candidate.name)))
        lines.append(contentsOf: toldLines(recent: recent, priors: priors, timeZone: timeZone))
        // With nothing known about the place, the shortest length whatever its tier: less to say, less to invent.
        lines.append(StoryLength.of(kind: .buzz, level: .first, tier: facts.isEmpty ? nil : buzz.place.tier).line)
        lines.append("Answer in: \(language.promptName)")
        lines.append("Task: Tell the user about the subject they are passing.")
        return lines.joined(separator: "\n")
    }

    /// A stop story's first level: the best place here under `Facts about` and the rest as `Nearby:`, or, with nothing
    /// here, the places `Worth the detour:` with their facts and no Apple Maps places (spec 9 step 2). No came-from: a
    /// stop story follows a standstill. Sides are compass words: the walker has stopped and may have turned.
    static func walkStopInput(_ stop: WalkStop, position: Coordinate, context: WalkContext, articleText: String?,
                              applePlaces: [ApplePlace]?, recent: [RecentStory], priors: [PriorStory],
                              language: StoryLanguage, now: Date, timeZone: TimeZone) -> String {
        var lines = ["Story: stop, first level"]
        lines.append(contentsOf: walkPositionLines(context.address, position: position))
        lines.append("Time: \(GuideText.time(now, timeZone: timeZone))")
        lines.append(standingLine(direction: usableDirection(context.bearing), street: context.street))
        let tier: PlaceTier?
        let task: String
        switch stop {
        case .here(let listed):
            lines.append(contentsOf: stopHereLines(listed, from: position, articleText: articleText))
            lines.append(contentsOf: appleMapsLines(applePlaces, from: position, direction: nil,
                                                    knownNames: listed.map(\.candidate.name)))
            tier = listed.first?.tier
            task = "Task: Tell the user about the spot where they are standing."
        case .detour(let places):
            lines.append(contentsOf: walkPlaceLines("Worth the detour:", places, from: position, direction: nil,
                                                    facts: { factLines($0, articleText: nil) }))
            tier = nil
            task = "Task: There is little to tell right here: say so in one sentence, then point them to the place worth the detour."
        }
        lines.append(contentsOf: toldLines(recent: recent, priors: priors, timeZone: timeZone))
        lines.append(StoryLength.of(kind: .stop, level: .first, tier: tier).line)
        lines.append("Answer in: \(language.promptName)")
        lines.append(task)
        return lines.joined(separator: "\n")
    }

    /// A walking story's level 2 or 3. Position, address and direction are the stored story's (the flow has no fresher
    /// position on "More"); no came-from. A buzz keeps its subject and facts. A stop keeps its first level's structure
    /// over `stop` (the ladder around the story's position): the first place under `Facts about` (with `articleText`),
    /// the rest as `Nearby:` or `Worth the detour:`; a detour gets no Apple Maps places. With no place left (`stop` nil)
    /// it says `Facts: none found` and asks for a short level from what the model genuinely knows. `applePlaces` are
    /// the first level's, or a fresh search's when those are missing.
    static func walkContinuationInput(story: WalkStory, level: StoryLevel, stop: WalkStop?, articleText: String?,
                                      applePlaces: [ApplePlace]?, recent: [RecentStory], priors: [PriorStory],
                                      now: Date, timeZone: TimeZone) -> String {
        let direction = usableDirection(story.course)
        let street = GuideText.streetName(fromAddressLine: story.address?.line)
        let name = switch story.kind {
        case .buzz: "walking buzz"
        case .stop: "stop"
        }
        var task = continuationTask
        var lines = ["Story: \(name), level \(level.rawValue)"]
        lines.append(contentsOf: walkPositionLines(story.address, position: story.position,
                                                   lookedUp: story.addressLookedUp))
        lines.append("Time: \(GuideText.time(now, timeZone: timeZone))")
        switch story.kind {
        case .buzz:
            lines.append(walkingLine(direction: direction, street: street))
            if let place = story.place {
                lines.append("Subject: \(place.name) (\(place.kind)), "
                             + distanceAndSide(from: story.position, to: place.coordinate, direction: direction))
                lines.append(contentsOf: factsAboutLines(place.name, facts: factLines(place, articleText: articleText)))
            }
            lines.append(contentsOf: appleMapsLines(applePlaces, from: story.position, direction: direction,
                                                    knownNames: story.place.map { [$0.name] } ?? []))
        case .stop:
            lines.append(standingLine(direction: direction, street: street))
            switch stop {
            case .here(let listed):
                lines.append(contentsOf: stopHereLines(listed, from: story.position, articleText: articleText))
                lines.append(contentsOf: appleMapsLines(applePlaces, from: story.position, direction: nil,
                                                        knownNames: listed.map(\.candidate.name)))
            case .detour(let places):
                if let first = places.first {
                    lines.append(contentsOf: stopFactsAboutLines(first, from: story.position, articleText: articleText))
                }
                lines.append(contentsOf: walkPlaceLines("Worth the detour:", Array(places.dropFirst()), from: story.position,
                                                        direction: nil, facts: { factLines($0, articleText: nil) }))
            case nil:
                // Nothing within reach of the story's position any more: no facts to continue from.
                lines.append("Facts: none found")
                lines.append(contentsOf: appleMapsLines(applePlaces, from: story.position, direction: nil, knownNames: []))
                task = noFactsContinuationTask
            }
        }
        lines.append(contentsOf: toldSoFarLines(story.levels))
        lines.append(contentsOf: toldLines(recent: recent, priors: priors, timeZone: timeZone))
        lines.append(StoryLength.of(kind: storyKind(story.kind), level: level, tier: nil).line)
        lines.append("Answer in: \(story.language.promptName)")
        lines.append(task)
        return lines.joined(separator: "\n")
    }

    /// The task of a stop story's level 2 or 3 when no place is left to tell from.
    static let noFactsContinuationTask = "Task: Continue only with what you genuinely know about this spot; if you know little, say so in a sentence and stop short."

    /// The best place under `Facts about`, the rest as `Nearby:` with their OSM facts; compass sides.
    private static func stopHereLines(_ listed: [WalkingPlace], from: Coordinate, articleText: String?) -> [String] {
        guard let best = listed.first else { return [] }
        return stopFactsAboutLines(best, from: from, articleText: articleText)
            + walkPlaceLines("Nearby:", Array(listed.dropFirst()), from: from, direction: nil, facts: osmLines)
    }

    /// `Facts about Name (kind), 50 m, north:` and its facts, or `…: none found`. A stop story has no Subject line, so
    /// the header carries the place's kind, distance and (compass) side.
    private static func stopFactsAboutLines(_ place: WalkingPlace, from: Coordinate, articleText: String?) -> [String] {
        let c = place.candidate
        let header = "Facts about \(c.name) (\(c.kind)), " + distanceAndSide(from: from, to: c.coordinate, direction: nil)
        let facts = factLines(c, articleText: articleText)
        return [facts.isEmpty ? header + ": none found" : header + ":"] + facts
    }

    /// The `OSM:` line of a place, indented, or nothing.
    private static func osmLines(_ c: Candidate) -> [String] {
        GuideText.osmFacts(c.tags).map { ["  \($0)"] } ?? []
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

    /// `Position:` with the address, or else that its lookup failed (`unknown` when it was never looked up) plus the
    /// coordinates.
    private static func walkPositionLines(_ address: Address?, position: Coordinate, lookedUp: Bool = true) -> [String] {
        let display = address?.display ?? ""
        guard display.isEmpty else { return ["Position: \(display)"] }
        return [lookedUp ? "Position: address lookup failed" : "Position: unknown",
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
    /// nil for a blank street; a blank `along` is left out.
    private static func cameFromLine(_ cameFrom: CameFrom, direction: Double?) -> String? {
        guard !isBlank(cameFrom.street) else { return nil }
        let ago = cameFrom.minutesAgo <= 0 ? "under a minute ago" : "\(cameFrom.minutesAgo) min ago"
        let along = alongStreet(cameFrom.along)
        return "Came from: \(cameFrom.street), \(ago), "
            + GuideText.distanceAndSide(distance: cameFrom.distance, bearing: cameFrom.bearing, direction: direction)
            + (along.isEmpty ? "" : "," + along)
    }

    /// `heading` then `- Name (kind), 40 m, ahead` per place followed by its `facts` lines; nothing for no places.
    private static func walkPlaceLines(_ heading: String, _ places: [WalkingPlace], from: Coordinate, direction: Double?,
                                       facts: (Candidate) -> [String]) -> [String] {
        guard !places.isEmpty else { return [] }
        return [heading] + places.flatMap { place -> [String] in
            let c = place.candidate
            return ["- \(c.name) (\(c.kind)), " + distanceAndSide(from: from, to: c.coordinate, direction: direction)] + facts(c)
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

// MARK: Day story

extension PromptBuilder {
    /// The day story's instructions (spec 5.2): its task rules, then the guide voice's HONESTY section word for word.
    /// One constant for both languages, so the request prefix can be cached.
    public static let dayStoryInstructions = """
        You are a brilliant private guide looking back with the user on a day they spent exploring. You receive the day's date and city, the stories the app told them that day in time order, and their photos, attached as images in the order listed, each with a short id in brackets and the event it was taken near, if any.

        WHAT TO DO
        - Write a caption for each photo: what is in the frame first, then the matched event's facts. At most 40 words, warm and specific, no greetings.
        - Then write a 2–3 sentence summary of the day as a walk the user took.
        - Never state facts that are not in the event list or clearly visible in a photo.
        - The event list and what is clearly visible in the photos are the only facts you may use; leave out anything you know about a place from elsewhere.
        - This request has no "Told in the last 3 hours" or "Told here before" lists and no nearby places: the HONESTY rules about them do not apply, and never suggest a detour.
        - Use each photo's id in brackets exactly as given, one caption per id.
        - No bullet points, no headers, no emojis.
        - Answer in the language the request names.
        """ + "\n\n" + honestySection

    /// Sent as `prompt_cache_key` with every day story request.
    public static let dayPromptCacheKey = "myguide-day-v1"

    /// The id the model sees for the photo at `index` in the plan: `p1` for the first.
    static func dayPhotoID(_ index: Int) -> String {
        "p\(index + 1)"
    }

    /// The day story's user message (spec 5.2): the day, its events, the photos in plan order with their short ids,
    /// the language and the task. Clock times and the date are in `timeZone`.
    static func dayStoryInput(plan: DayStoryPlan, day: DiaryDay, language: StoryLanguage, timeZone: TimeZone) -> String {
        let city = day.city.map(GuideText.oneLine) ?? ""
        var lines = ["Day: \(GuideText.longDate(day.date, timeZone: timeZone))" + (city.isEmpty ? "" : ", \(city)")]
        if plan.events.isEmpty {
            lines.append("Events: none")
        } else {
            lines.append("Events:")
            lines.append(contentsOf: plan.events.map { dayEventLine($0, timeZone: timeZone) })
        }
        lines.append("Photos (in the order the images are attached):")
        lines.append(contentsOf: plan.photos.enumerated().map { index, photo in
            "- [\(dayPhotoID(index))] \(GuideText.clock(photo.time, timeZone: timeZone)), "
                + dayPhotoContext(photo, match: plan.matches[photo.id], timeZone: timeZone)
        })
        lines.append("Answer in: \(language.promptName)")
        lines.append("Task: Write one caption per photo id, then the day summary.")
        return lines.joined(separator: "\n")
    }

    /// `- 11:58 walking buzz: Akershus Fortress — "first sentence"`; the name and the sentence are left out when missing.
    private static func dayEventLine(_ event: DiaryEntry, timeZone: TimeZone) -> String {
        let kind = switch event.kind {
        case .photoStory: "photo story"
        case .buzz: "walking buzz"
        case .stop: "stop"
        case .libraryPhoto: "photo"
        }
        var line = "- \(GuideText.clock(event.time, timeZone: timeZone)) " + named(kind, DayStoryPlan.eventName(event))
        if let sentence = event.firstSentence.map(GuideText.oneLine), !sentence.isEmpty {
            line += " — \"\(sentence)\""
        }
        return line
    }

    /// `photo story: Oslo Cathedral`, `matches 11:58 Akershus Fortress` or `no matching event`.
    private static func dayPhotoContext(_ photo: DayStoryPhoto, match: DiaryEntry?, timeZone: TimeZone) -> String {
        if case .photoStory(let title) = photo.kind { return named("photo story", title) }
        guard let match else { return "no matching event" }
        let name = DayStoryPlan.eventName(match)
        return "matches \(GuideText.clock(match.time, timeZone: timeZone))" + (name.isEmpty ? "" : " \(name)")
    }

    /// `label: name`, or `label` alone for an empty name.
    private static func named(_ label: String, _ name: String) -> String {
        name.isEmpty ? label : "\(label): \(name)"
    }

    static let dayStorySchema: JSONValue = .object([
        "type": "object",
        "additionalProperties": false,
        "required": ["summary", "captions"],
        "properties": .object([
            "summary": .object(["type": "string", "description": "2–3 sentences about the day as a walk"]),
            "captions": .object([
                "type": "array",
                "items": .object([
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["photoID", "caption"],
                    "properties": .object([
                        "photoID": .object(["type": "string", "description": "The photo's id in brackets, e.g. p1"]),
                        "caption": .object(["type": "string", "description": "At most 40 words"]),
                    ]),
                ]),
            ]),
        ]),
    ])

    private struct DayStoryText: Decodable {
        struct Caption: Decodable { var photoID: String; var caption: String }
        var summary: String
        var captions: [Caption]
    }

    /// Unknown photo ids are dropped; an empty or blank summary throws OpenAIError.malformedResponse.
    /// `photoIDs` are the plan's photo ids in order: `p1` is `photoIDs[0]`. A blank caption counts as none, a repeated
    /// id keeps its first caption, and summary and captions come back trimmed.
    static func decodeDayStory(_ json: Data, photoIDs: [String]) throws -> (summary: String, captions: [String: String]) {
        let decoded: DayStoryText
        do {
            decoded = try JSONDecoder().decode(DayStoryText.self, from: json)
        } catch is DecodingError {
            throw OpenAIError.malformedResponse
        }
        let summary = decoded.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw OpenAIError.malformedResponse }
        let realIDs = Dictionary(uniqueKeysWithValues: photoIDs.enumerated().map { (dayPhotoID($0.offset), $0.element) })
        var captions: [String: String] = [:]
        for item in decoded.captions {
            let caption = item.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = realIDs[item.photoID], !caption.isEmpty, captions[id] == nil else { continue }
            captions[id] = caption
        }
        return (summary, captions)
    }
}
