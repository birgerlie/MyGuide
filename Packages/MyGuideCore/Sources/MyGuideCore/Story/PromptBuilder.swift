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
        7. Write in \(language.promptName). Hit the requested length closely; it will be read aloud at about 150 words per minute.
        """
    }

    static func firstStoryInput(capture: CaptureContext, grounding: Grounding, priors: [PriorStory]) -> String {
        var lines = ["Story length: \(StoryLevel.first.lengthPhrase)."]

        if let c = capture.coordinate {
            var position = String(format: "Position: %.6f, %.6f", c.latitude, c.longitude)
            if let acc = capture.horizontalAccuracy { position += " (accuracy ±\(Int(acc.rounded())) m)" }
            lines.append(position)
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

    /// Decodes the model's JSON. A matchedCandidateID that is not among the grounding candidates is dropped.
    static func decodeFirstStory(_ json: Data, grounding: Grounding) throws -> IdentifiedStory {
        var story: IdentifiedStory
        do {
            story = try JSONDecoder().decode(IdentifiedStory.self, from: json)
        } catch is DecodingError {
            throw OpenAIError.malformedResponse
        }
        if let id = story.matchedCandidateID, !grounding.candidates.contains(where: { $0.candidate.id == id }) {
            story.matchedCandidateID = nil
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
        var lines = ["Story length: \(level.lengthPhrase).",
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

        lines.append("Task: Continue the story from where it left off. Do not restart or repeat. Take a new angle: another person, another moment in time, or something the listener can still see today that connects to it.")
        return lines.joined(separator: "\n")
    }

    private struct Continuation: Decodable { var story: String }

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
