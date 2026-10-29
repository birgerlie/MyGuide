import Foundation

/// The one factual line under a place in a notification. Comes only from the place's own data (spec 7.2, 12.7).
public enum FactLine {
    public static let maxLength = 140

    /// First sentence of the summary when the summary's article language (`articleLanguage`) is the story language;
    /// else kind label (+ " · fra 1697" / " · fredet"); else nil.
    public static func text(for candidate: Candidate, language: StoryLanguage) -> String? {
        if let summary = candidate.summary, articleLanguage(candidate) == language.wikipediaCode,
           let sentence = firstSentence(summary) {
            return limit(sentence)
        }
        guard let tags = candidate.tags, let label = kindLabel(tags: tags, language: language) else { return nil }
        let nb = language == .norwegian
        if let date = tags["start_date"], date.count >= 4, date.prefix(4).allSatisfy({ $0.isASCII && $0.isNumber }) {
            return label + (nb ? " · fra " : " · from ") + date.prefix(4)
        }
        if tags["heritage"] != nil { return label + (nb ? " · fredet" : " · listed") }
        return label
    }

    /// The language of the article `summary` came from. `summaryLanguage` wins (a merged OSM place can carry an
    /// "it:" title and a Norwegian summary); else "no:Foo" → "no"; "wiki:en/12" → "en"; nil otherwise. The title
    /// wins over the id.
    public static func articleLanguage(_ candidate: Candidate) -> String? {
        if let code = candidate.summaryLanguage, !code.isEmpty { return code }
        if let title = candidate.wikipediaTitle, let colon = title.firstIndex(of: ":") {
            let code = title[..<colon]
            if !code.isEmpty { return String(code) }
        }
        if candidate.id.hasPrefix("wiki:") {
            let rest = candidate.id.dropFirst("wiki:".count)
            if let slash = rest.firstIndex(of: "/") {
                let code = rest[..<slash]
                if !code.isEmpty { return String(code) }
            }
        }
        return nil
    }

    public static func kindLabel(tags: [String: String], language: StoryLanguage) -> String? {
        let nb = language == .norwegian
        for row in kindRows where row.matches(tags) { return nb ? row.nb : row.en }
        return nil
    }

    // MARK: - Private

    private struct KindRow {
        let any: [(String, String)]
        let also: (String, String)?
        let nb: String
        let en: String
        func matches(_ tags: [String: String]) -> Bool {
            if let also, tags[also.0] != also.1 { return false }
            return any.contains { tags[$0.0] == $0.1 }
        }
    }

    /// The first matching row wins, so order matters (statue before memorial, cathedral before church).
    private static let kindRows: [KindRow] = [
        KindRow(any: [("historic", "castle"), ("building", "castle")], also: nil, nb: "Slott", en: "Castle"),
        KindRow(any: [("historic", "palace"), ("building", "palace")], also: nil, nb: "Palass", en: "Palace"),
        KindRow(any: [("historic", "fort")], also: nil, nb: "Festning", en: "Fortress"),
        KindRow(any: [("historic", "city_gate")], also: nil, nb: "Byport", en: "City gate"),
        KindRow(any: [("historic", "citywalls")], also: nil, nb: "Bymur", en: "City wall"),
        KindRow(any: [("historic", "ruins")], also: nil, nb: "Ruin", en: "Ruins"),
        KindRow(any: [("historic", "archaeological_site")], also: nil, nb: "Arkeologisk sted", en: "Archaeological site"),
        KindRow(any: [("historic", "battlefield")], also: nil, nb: "Slagmark", en: "Battlefield"),
        KindRow(any: [("historic", "monument")], also: nil, nb: "Monument", en: "Monument"),
        KindRow(any: [("historic", "memorial")], also: ("memorial", "statue"), nb: "Statue", en: "Statue"),
        KindRow(any: [("historic", "memorial")], also: nil, nb: "Minnesmerke", en: "Memorial"),
        KindRow(any: [("historic", "tower")], also: nil, nb: "Tårn", en: "Tower"),
        KindRow(any: [("building", "cathedral")], also: nil, nb: "Domkirke", en: "Cathedral"),
        KindRow(any: [("historic", "church"), ("building", "church")], also: nil, nb: "Kirke", en: "Church"),
        KindRow(any: [("amenity", "place_of_worship")], also: nil, nb: "Gudshus", en: "Place of worship"),
        KindRow(any: [("historic", "monastery")], also: nil, nb: "Kloster", en: "Monastery"),
        KindRow(any: [("historic", "manor")], also: nil, nb: "Herregård", en: "Manor"),
        KindRow(any: [("tourism", "museum")], also: nil, nb: "Museum", en: "Museum"),
        KindRow(any: [("tourism", "gallery")], also: nil, nb: "Galleri", en: "Gallery"),
        KindRow(any: [("tourism", "attraction")], also: nil, nb: "Severdighet", en: "Attraction"),
        KindRow(any: [("historic", "building")], also: nil, nb: "Historisk bygning", en: "Historic building"),
    ]

    // MARK: - Shared with NotificationText

    /// A sentence shorter than this (in characters) is joined with the next one while the text continues, so a
    /// stray fragment like "Built 1890." or an unlisted abbreviation never stands alone.
    static let minimumSentenceLength = 20

    /// Lower-cased abbreviations whose "." never ends a sentence, even before a capital or a digit ("ca. 125",
    /// "St. Olav"). Any single letter before "." ("f. 1810", "John F. Kennedy") counts too. "e.Kr.", "f.Kr." and
    /// "osv." are left out on purpose: they usually close a sentence ("bygget ca. 125 e.Kr. Senere …"), so they
    /// keep the ordinary rule.
    static let abbreviations: Set<String> = [
        "ca.", "f.", "d.", "st.", "bl.a.", "dvs.", "mr.", "dr.", "nr.", "jf.", "kl.",
    ]

    /// Up to and including the first ./!/? followed by whitespace + uppercase/digit, or by the end of the text.
    /// A "." closing an abbreviation is not a boundary, and a boundary that would leave fewer than
    /// `minimumSentenceLength` characters is passed over. The whole text when no boundary qualifies.
    static func firstSentence(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let chars = Array(t)
        for i in chars.indices where ".!?".contains(chars[i]) {
            var j = i + 1
            if j == chars.count { return String(chars[...i]) }
            guard chars[j].isWhitespace else { continue }
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            guard j == chars.count || chars[j].isUppercase || chars[j].isNumber else { continue }
            if chars[i] == ".", isAbbreviation(chars, endingAt: i) { continue }
            // i + 1 = characters up to and including the terminator.
            if i + 1 < minimumSentenceLength { continue }
            return String(chars[...i])
        }
        return t
    }

    /// The whitespace-delimited token ending at `end` (a "."), stripped of leading non-letters such as "(" or «,
    /// is a listed abbreviation or one letter + ".".
    private static func isAbbreviation(_ chars: [Character], endingAt end: Int) -> Bool {
        var start = end
        while start > 0, !chars[start - 1].isWhitespace { start -= 1 }
        while start < end, !chars[start].isLetter { start += 1 }
        let token = String(chars[start...end]).lowercased()
        if token.count == 2, token.first?.isLetter == true { return true }
        return abbreviations.contains(token)
    }

    /// At most `maxLength` characters: longer text is cut at the last space at or before index maxLength − 1, plus "…".
    static func limit(_ s: String, to maxLength: Int = maxLength) -> String {
        guard s.count > maxLength else { return s }
        let head = Array(s.prefix(maxLength))
        let cut = head.lastIndex(of: " ") ?? (maxLength - 1)
        // cut ≤ maxLength − 1, so at most maxLength − 1 characters + "…". Without any space the hard cut keeps
        // maxLength − 1.
        let kept = head[..<cut]
        return String(kept).trimmingCharacters(in: .whitespaces) + "…"
    }
}
