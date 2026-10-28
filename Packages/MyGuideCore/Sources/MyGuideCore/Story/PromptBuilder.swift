import Foundation

public enum PromptBuilder {
    /// Prior story texts are cut to this many characters before they go into a prompt.
    static let priorTextLimit = 240

    static func systemInstructions(language: StoryLanguage) -> String {
        """
        You are MyGuide, a friend who knows this city well, walking beside the listener. You tell short, true stories about the people who were here and what this spot was like back then: the sounds, the smells, who walked past. Dates, architects and styles appear only when they support a story about people.

        Rules:
        1. Never present invented history as fact. If something is legend, tradition or disputed, say so plainly ("legend has it", "the story goes", "historians doubt it"). Prefer a less colourful true story over an invented one.
        2. Use the supplied places, summaries and address as your factual ground. You may add well-established history you are confident of; never invent names, dates, quotes or events.
        3. If you are not sure what the photo shows, say so in the story itself, then tell the story of the most likely candidate or of the spot itself.
        4. Do not repeat anything listed under "Already told". Take a new angle.
        5. Speak directly to the listener in a warm, conversational voice. No lists, no headings, no "Welcome to".
        6. Never mention shops, restaurants or cafés unless the subject is one with real history.
        7. Write in \(language.promptName). Aim for the requested length, but if the facts run out, stop shorter rather than invent. It will be read aloud at about 150 words per minute.
        """
    }

    static func firstStoryInput(capture: CaptureContext, grounding: Grounding, priors: [PriorStory]) -> String {
        var lines = [StoryLength.of(kind: .photo, level: .first, tier: nil).line]

        if let c = capture.coordinate {
            var position = String(format: "Position: %.6f, %.6f", c.latitude, c.longitude)
            if let acc = capture.horizontalAccuracy { position += " (accuracy ±\(Int(acc.rounded())) m)" }
            lines.append(position)
            if capture.positionIsSubstitute {
                lines.append("Position is where the listener is now, not necessarily where the photo was taken; trust the photo over the places list.")
            }
        } else {
            lines.append("Position: unknown")
        }

        let usableHeading = capture.usableHeading
        if let heading = usableHeading, let acc = capture.headingAccuracy {
            lines.append("Facing: \(wholeDegrees(heading))° (\(FieldOfView.compassPoint(heading))), compass accuracy ±\(Int(acc.rounded()))°")
        } else {
            lines.append("Facing: unknown — identify the subject from position and the photo alone, and be more cautious.")
        }

        if let address = grounding.address {
            lines.append("Address: \(address.display)")
        }

        if !grounding.failedSources.isEmpty {
            lines.append("Map data unavailable: \(grounding.failedSources.map(sourceName).joined(separator: ", ")). Be more cautious.")
        }

        if grounding.candidates.isEmpty {
            lines.append("Places nearby: none found")
        } else {
            lines.append("Places nearby (in view first, nearest first):")
            for ranked in grounding.candidates {
                let c = ranked.candidate
                var line = "- [\(c.id)] \(c.name) — \(c.kind) — \(Int(ranked.distance.rounded())) m, bearing \(wholeDegrees(ranked.bearing))°"
                if usableHeading != nil, let inView = ranked.inView {
                    line += inView ? ", in view" : ", out of view"
                }
                lines.append(line)
                if let summary = c.summary, !summary.isEmpty {
                    lines.append("  Summary: \(summary)")
                }
            }
        }

        if priors.isEmpty {
            lines.append("Already told: nothing yet")
        } else {
            lines.append("Already told:")
            lines.append(contentsOf: priors.map(priorLine))
        }

        lines.append("Task: Identify what the photo shows, preferring places in view. Set matchedCandidateID only if the subject is one of the listed places (use its id in brackets). Then write the first story.")
        return lines.joined(separator: "\n")
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
                            "description": "The past era the story mostly paints, e.g. 'around 1780'"]),
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

    static func continuationInput(session: StorySession, level: StoryLevel, priors: [PriorStory]) -> String {
        var lines = [StoryLength.of(kind: .photo, level: level, tier: nil).line,
                     "Subject: \(session.identified.subject) (confidence: \(session.identified.confidence.rawValue))"]
        if let address = session.grounding.address {
            lines.append("Address: \(address.display)")
        }

        let facts = factCandidates(for: session)
        if facts.isEmpty {
            lines.append("Facts: none found")
        } else {
            lines.append("Facts:")
            for ranked in facts {
                let c = ranked.candidate
                lines.append("- \(c.name) — \(c.kind)")
                if let summary = c.summary, !summary.isEmpty {
                    lines.append("  Summary: \(summary)")
                }
            }
        }

        lines.append("Told so far:")
        for (index, text) in session.levels.enumerated() {
            lines.append("Level \(index + 1): \(text)")
        }

        if priors.isEmpty {
            lines.append("Already told on earlier visits: nothing")
        } else {
            lines.append("Already told on earlier visits:")
            lines.append(contentsOf: priors.map(priorLine))
        }

        lines.append("Task: Continue the story from where it left off. Do not restart or repeat. Take a new angle: another person, another moment in time, or something the listener can still see today that connects to it. If the facts below are thin, say less.")
        return lines.joined(separator: "\n")
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
