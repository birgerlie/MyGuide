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
        if !grounding.failedSources.isEmpty {
            lines.append("Map data unavailable: \(grounding.failedSources.map(sourceName).joined(separator: ", ")). Be more cautious.")
        }
        if grounding.candidates.isEmpty {
            lines.append("Nearby: none found")
        } else {
            lines.append("Nearby:")
            lines.append(contentsOf: grounding.candidates.flatMap { candidateLines($0, heading: heading) })
        }
        lines.append(contentsOf: appleMapsLines(grounding, capture: capture))
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
        var lines = ["Story: photo, level \(level.rawValue)"]
        lines.append(contentsOf: positionLines(capture: capture, address: session.grounding.address))
        lines.append("Time: \(GuideText.time(now, timeZone: timeZone))")
        lines.append(facingLine(capture))
        lines.append("Subject: \(session.identified.subject) (confidence: \(session.identified.confidence.rawValue))")

        if let matched = session.matchedCandidate {
            let c = matched.candidate
            var facts: [String] = []
            if let osm = GuideText.osmFacts(c.tags) { facts.append("  \(osm)") }
            if let text = [articleText, c.summary].compactMap({ $0 }).first(where: { !isBlank($0) }) {
                facts.append("  Wikipedia: \(text)")
            }
            lines.append(facts.isEmpty ? "Facts about \(c.name): none found" : "Facts about \(c.name):")
            lines.append(contentsOf: facts)
        } else {
            let facts = factCandidates(for: session)
            if facts.isEmpty {
                lines.append("Facts: none found")
            } else {
                lines.append("Nearby:")
                lines.append(contentsOf: facts.flatMap { candidateLines($0, heading: capture.usableHeading) })
            }
        }
        lines.append(contentsOf: appleMapsLines(session.grounding, capture: capture))

        lines.append("Told so far:")
        for (index, text) in session.levels.enumerated() {
            lines.append("Level \(index + 1): \(text)")
        }
        lines.append(contentsOf: toldLines(recent: recent, priors: priors, timeZone: timeZone))
        lines.append(StoryLength.of(kind: .photo, level: level, tier: nil).line)
        lines.append("Answer in: \(session.language.promptName)")
        lines.append("Task: Continue from where the story left off; new points, from another domain where the facts allow; do not repeat.")
        return lines.joined(separator: "\n")
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

    /// `Also on Apple Maps:` with the selected places (nearest first, none repeating a candidate's name), or nothing
    /// when none are left or the capture has no coordinate to measure from.
    private static func appleMapsLines(_ grounding: Grounding, capture: CaptureContext) -> [String] {
        guard let places = grounding.applePlaces, let from = capture.coordinate else { return [] }
        let selected = ApplePlaces.select(places, from: from, knownNames: grounding.candidates.map(\.candidate.name))
        guard !selected.isEmpty else { return [] }
        return ["Also on Apple Maps:"] + selected.map { place in
            "- \(place.name) (\(place.category)), "
                + GuideText.distanceAndSide(distance: GeoMath.distance(from, place.coordinate),
                                            bearing: GeoMath.bearing(from: from, to: place.coordinate),
                                            direction: capture.usableHeading)
        }
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

    /// Most places listed as "Other places nearby" in a buzz prompt.
    static let walkBuzzNeighbourLimit = 4

    static func walkBuzzInput(buzz: Buzz, course: Double?, facts: [WalkingPlace], position: Coordinate,
                              priors: [PriorStory]) -> String {
        let place = buzz.place.candidate
        var lines = ["The listener is walking, not looking at a photo. Tell the story of the place they are passing.",
                     "Place: \(place.name) (\(place.kind)), \(buzz.detail)."]
        if let course, course.isFinite, course >= 0 {
            lines.append("Walking direction: \(wholeDegrees(course))° (\(FieldOfView.compassPoint(course)))")
        }
        if let summary = place.summary, !summary.isEmpty {
            lines.append("Summary: \(summary)")
        }
        let others = buzzFacts(facts, excluding: place.id, position: position)
        if !others.isEmpty {
            lines.append("Other places nearby:")
            lines.append(contentsOf: others.map { factLine($0, from: position) })
        }
        lines.append(contentsOf: priorsBlock(priors))
        lines.append(StoryLength.of(kind: .buzz, level: .first, tier: buzz.place.tier).line)
        return lines.joined(separator: "\n")
    }

    static func walkStopInput(address: Address?, facts: [WalkingPlace], position: Coordinate, priors: [PriorStory]) -> String {
        var lines = ["The listener has stopped walking and is standing here for a while. Tell a short story about this spot.",
                     whereLine(address)]
        let near = stopFacts(facts, position: position)
        if !near.isEmpty {
            lines.append("Places within \(Int(WalkingStoryFlow.stopFactRadius)) m:")
            lines.append(contentsOf: near.map { factLine($0, from: position) })
        }
        lines.append(contentsOf: priorsBlock(priors))
        lines.append(StoryLength.of(kind: .stop, level: .first, tier: near.map(\.tier).min()).line)
        return lines.joined(separator: "\n")
    }

    static func walkContinuationInput(story: WalkStory, level: StoryLevel, priors: [PriorStory]) -> String {
        var lines = [StoryLength.of(kind: story.kind == .buzz ? .buzz : .stop, level: level, tier: nil).line]
        if let place = story.place {
            lines.append("Place: \(place.name) (\(place.kind))" + (story.detail.map { ", \($0)" } ?? "") + ".")
            if let summary = place.summary, !summary.isEmpty { lines.append("Summary: \(summary)") }
        } else {
            lines.append(whereLine(story.address))
        }
        lines.append("Told so far:")
        for (index, text) in story.levels.enumerated() {
            lines.append("Level \(index + 1): \(text)")
        }
        lines.append(contentsOf: priorsBlock(priors, heading: "Already told on earlier visits:", none: "Already told on earlier visits: nothing"))
        lines.append("Task: Continue the story from where it left off. Do not restart or repeat. Take a new angle: another person, another moment in time, or something the listener can still see today that connects to it. If the facts are thin, say less.")
        return lines.joined(separator: "\n")
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

    private static func whereLine(_ address: Address?) -> String {
        let display = address?.display ?? ""
        return display.isEmpty ? "Where: unknown street" : "Where: \(display)"
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

    private static func factLine(_ place: WalkingPlace, from position: Coordinate) -> String {
        let metres = BuzzText.roundedDistance(GeoMath.distance(position, place.candidate.coordinate))
        return "- \(place.candidate.name) (\(place.candidate.kind)), \(metres) m"
    }

    private static func priorsBlock(_ priors: [PriorStory], heading: String = "Already told:",
                                    none: String = "Already told: nothing yet") -> [String] {
        priors.isEmpty ? [none] : [heading] + priors.map(priorLine)
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
