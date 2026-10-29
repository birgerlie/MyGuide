import Foundation
import Testing
@testable import MyGuideCore

@Suite struct FactLineTests {
    static func candidate(id: String = "osm:node/1", title: String? = nil, summary: String? = nil,
                          tags: [String: String]? = nil) -> Candidate {
        Candidate(id: id, name: "X", coordinate: Coordinate(latitude: 59.9, longitude: 10.7), kind: "historic=church",
                  summary: summary, wikipediaTitle: title, tags: tags)
    }

    @Test func firstSentenceOfSameLanguageSummary() {
        let c = Self.candidate(title: "no:Pantheon",
                               summary: "Pantheon er et romersk tempel. Det ble bygget under Hadrian.")
        #expect(FactLine.text(for: c, language: .norwegian) == "Pantheon er et romersk tempel.")
    }

    @Test func summaryInOtherLanguageFallsToKindLabel() {
        let c = Self.candidate(title: "en:Church", summary: "A church. Built long ago.", tags: ["historic": "church"])
        #expect(FactLine.text(for: c, language: .norwegian) == "Kirke")
        // same candidate, English story: the summary is used
        #expect(FactLine.text(for: c, language: .english) == "A church.")
    }

    @Test func summaryWithoutArticleLanguageIsNotUsed() {
        let c = Self.candidate(summary: "Noe. Mer.", tags: ["tourism": "museum"])
        #expect(FactLine.text(for: c, language: .norwegian) == "Museum")
    }

    @Test func wikiIDGivesLanguageWhenNoTitle() {
        let c = Self.candidate(id: "wiki:en/12", summary: "Hello there. More.")
        #expect(FactLine.text(for: c, language: .english) == "Hello there.")
    }

    @Test func sentenceBoundaries() {
        func first(_ s: String) -> String? {
            FactLine.text(for: Self.candidate(title: "en:A", summary: s), language: .english)
        }
        #expect(first("Is it old? Yes it is.") == "Is it old?")
        #expect(first("Wow! Nice.") == "Wow!")
        #expect(first("Built in 1890. 12 people lived here.") == "Built in 1890.")
        // lowercase after the period is not a boundary
        #expect(first("Founded in the 13th c. by monks. Later rebuilt.") == "Founded in the 13th c. by monks.")
        // no terminator: whole text
        #expect(first("No full stop here") == "No full stop here")
        // single sentence ending the text
        #expect(first("Only one.") == "Only one.")
        // Norwegian capital letters count
        #expect(FactLine.text(for: Self.candidate(title: "no:A", summary: "Første. Åpnet 1900."), language: .norwegian)
                == "Første.")
        // empty / blank summary falls through
        #expect(first("   ") == nil)
    }

    @Test func longSentenceCutAtWord() {
        // 40 words of "abcde " = 6 chars each → 240 chars, no sentence end until the final period.
        let sentence = String(repeating: "abcde ", count: 39) + "abcde."
        #expect(sentence.count == 240)
        let r = FactLine.text(for: Self.candidate(title: "en:A", summary: sentence), language: .english)!
        #expect(r.count <= 140)
        #expect(r.hasSuffix("…"))
        // Words are 5 chars at indices 6k..6k+4, spaces at 6k+5. Last space at index ≤139: 6*23+5 = 143 > 139;
        // 6*22+5 = 137 ≤ 139 → cut to 137 chars + "…" = 138.
        #expect(r.count == 138)
        #expect(r.dropLast().split(separator: " ").allSatisfy { $0 == "abcde" })
    }

    @Test func sentenceOfExactlyMaxLengthIsKept() {
        let s = String(repeating: "a", count: 139) + "."
        #expect(s.count == 140)
        #expect(FactLine.text(for: Self.candidate(title: "en:A", summary: s), language: .english) == s)
        let t = String(repeating: "a", count: 140) + "."  // 141 chars, no space: hard cut at 139 + "…"
        let r = FactLine.text(for: Self.candidate(title: "en:A", summary: t), language: .english)!
        #expect(r.count == 140)
        #expect(r == String(repeating: "a", count: 139) + "…")
    }

    @Test func kindLabelWithYearAndHeritage() {
        let y = Self.candidate(tags: ["historic": "church", "start_date": "1697-05"])
        #expect(FactLine.text(for: y, language: .norwegian) == "Kirke · fra 1697")
        #expect(FactLine.text(for: y, language: .english) == "Church · from 1697")
        let h = Self.candidate(tags: ["historic": "church", "start_date": "c. 1700", "heritage": "2"])
        #expect(FactLine.text(for: h, language: .norwegian) == "Kirke · fredet")
        #expect(FactLine.text(for: h, language: .english) == "Church · listed")
        // year wins over heritage
        let both = Self.candidate(tags: ["historic": "church", "start_date": "1697", "heritage": "2"])
        #expect(FactLine.text(for: both, language: .norwegian) == "Kirke · fra 1697")
        // three digits is not a year
        let short = Self.candidate(tags: ["historic": "church", "start_date": "999"])
        #expect(FactLine.text(for: short, language: .norwegian) == "Kirke")
    }

    @Test func nothingKnownGivesNil() {
        #expect(FactLine.text(for: Self.candidate(), language: .norwegian) == nil)
        #expect(FactLine.text(for: Self.candidate(tags: [:]), language: .norwegian) == nil)
        #expect(FactLine.text(for: Self.candidate(tags: ["shop": "bakery"]), language: .english) == nil)
        // suffix alone is never shown
        #expect(FactLine.text(for: Self.candidate(tags: ["start_date": "1697"]), language: .english) == nil)
    }

    @Test func statueBeatsMemorial() {
        #expect(FactLine.kindLabel(tags: ["historic": "memorial", "memorial": "statue"], language: .norwegian) == "Statue")
        #expect(FactLine.kindLabel(tags: ["historic": "memorial", "memorial": "plaque"], language: .norwegian) == "Minnesmerke")
        #expect(FactLine.kindLabel(tags: ["historic": "memorial"], language: .english) == "Memorial")
    }

    @Test func kindLabelTable() {
        let rows: [([String: String], String, String)] = [
            (["historic": "castle"], "Slott", "Castle"),
            (["building": "castle"], "Slott", "Castle"),
            (["historic": "palace"], "Palass", "Palace"),
            (["building": "palace"], "Palass", "Palace"),
            (["historic": "fort"], "Festning", "Fortress"),
            (["historic": "city_gate"], "Byport", "City gate"),
            (["historic": "citywalls"], "Bymur", "City wall"),
            (["historic": "ruins"], "Ruin", "Ruins"),
            (["historic": "archaeological_site"], "Arkeologisk sted", "Archaeological site"),
            (["historic": "battlefield"], "Slagmark", "Battlefield"),
            (["historic": "monument"], "Monument", "Monument"),
            (["historic": "tower"], "Tårn", "Tower"),
            (["building": "cathedral"], "Domkirke", "Cathedral"),
            (["historic": "church"], "Kirke", "Church"),
            (["building": "church"], "Kirke", "Church"),
            (["amenity": "place_of_worship"], "Gudshus", "Place of worship"),
            (["historic": "monastery"], "Kloster", "Monastery"),
            (["historic": "manor"], "Herregård", "Manor"),
            (["tourism": "museum"], "Museum", "Museum"),
            (["tourism": "gallery"], "Galleri", "Gallery"),
            (["tourism": "attraction"], "Severdighet", "Attraction"),
            (["historic": "building"], "Historisk bygning", "Historic building"),
        ]
        for (tags, nb, en) in rows {
            #expect(FactLine.kindLabel(tags: tags, language: .norwegian) == nb)
            #expect(FactLine.kindLabel(tags: tags, language: .english) == en)
        }
    }

    @Test func kindLabelFirstMatchingRowWins() {
        // castle row precedes museum; cathedral precedes place_of_worship
        #expect(FactLine.kindLabel(tags: ["historic": "castle", "tourism": "museum"], language: .english) == "Castle")
        #expect(FactLine.kindLabel(tags: ["building": "cathedral", "amenity": "place_of_worship"], language: .english) == "Cathedral")
    }

    @Test func articleLanguageFromTitleAndID() {
        #expect(FactLine.articleLanguage(Self.candidate(title: "no:Foo")) == "no")
        #expect(FactLine.articleLanguage(Self.candidate(id: "wiki:en/12")) == "en")
        // title wins over id
        #expect(FactLine.articleLanguage(Self.candidate(id: "wiki:en/12", title: "de:Foo")) == "de")
        #expect(FactLine.articleLanguage(Self.candidate()) == nil)
        #expect(FactLine.articleLanguage(Self.candidate(title: "NoColon")) == nil)
        #expect(FactLine.articleLanguage(Self.candidate(title: ":Foo")) == nil)
        #expect(FactLine.articleLanguage(Self.candidate(id: "osm:node/1", title: "")) == nil)
    }
}
