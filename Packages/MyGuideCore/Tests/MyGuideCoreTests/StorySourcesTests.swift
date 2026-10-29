import Foundation
import Testing
@testable import MyGuideCore

/// «Kilder» on the story screen: only what the story drew on (design guidelines: sources for factual claims).
@Suite struct StorySourcesTests {
    static func candidate(id: String = "osm:way/42", name: String = "Pantheon", wikipediaTitle: String? = nil,
                          wikidata: String? = nil) -> Candidate {
        Candidate(id: id, name: name, coordinate: Coordinate(latitude: 41.8986, longitude: 12.4769), kind: "historic=yes",
                  wikipediaTitle: wikipediaTitle, wikidata: wikidata)
    }

    static func session(_ candidate: Candidate, matched: String?, confidence: SubjectConfidence = .certain,
                        address: Address? = nil, applePlaces: [ApplePlace]? = nil) -> StorySession {
        StorySession(id: UUID(), capture: GroundingTests.capture(heading: 0, acc: 10),
                     photoJPEG: Data(), thumbnailJPEG: Data(), language: .norwegian,
                     grounding: Grounding(candidates: [RankedCandidate(candidate: candidate, distance: 80, bearing: 10,
                                                                       inView: true)],
                                          address: address, failedSources: [], applePlaces: applePlaces),
                     identified: IdentifiedStory(subject: "Pantheon", confidence: confidence,
                                                 matchedCandidateID: matched, title: "T", era: "e", story: "S."),
                     levels: ["S."])
    }

    @Test func matchedPlaceListsArticleOSMAndWikidataThenApple() {
        let place = Self.candidate(wikipediaTitle: "it:Pantheon (Roma)", wikidata: "Q99309")
        let sources = StorySources.list(for: Self.session(place, matched: place.id, address: Address(city: "Roma")))
        #expect(sources == [
            StorySource(kind: .wikipedia, detail: "Pantheon (Roma)",
                        url: URL(string: "https://it.wikipedia.org/wiki/Pantheon_(Roma)")),
            StorySource(kind: .openStreetMap, detail: "way/42", url: URL(string: "https://www.openstreetmap.org/way/42")),
            StorySource(kind: .wikidata, detail: "Q99309", url: URL(string: "https://www.wikidata.org/wiki/Q99309")),
            StorySource(kind: .appleMaps, detail: nil, url: nil),
        ])
    }

    @Test func noMatchMeansNoPlaceSources() {
        let place = Self.candidate(wikipediaTitle: "it:Pantheon", wikidata: "Q99309")
        // The model named a subject but matched no candidate: nothing says this candidate is the story's place.
        #expect(StorySources.list(for: Self.session(place, matched: nil)) == [])
        #expect(StorySources.list(for: Self.session(place, matched: nil, address: Address(city: "Roma")))
                == [StorySource(kind: .appleMaps, detail: nil, url: nil)])
    }

    @Test func unsureListsNoPlaceSourcesEvenWithAnID() {
        let place = Self.candidate(wikipediaTitle: "it:Pantheon")
        #expect(StorySources.list(for: Self.session(place, matched: place.id, confidence: .unsure)) == [])
    }

    @Test func likelyStillListsTheMatchedPlace() {
        let place = Self.candidate()
        #expect(StorySources.list(for: Self.session(place, matched: place.id, confidence: .likely)).map(\.kind)
                == [.openStreetMap])
    }

    @Test func applePlacesAloneCountAsAppleMaps() {
        let place = Self.candidate()
        let apple = [ApplePlace(name: "Pantheon", category: "landmark", coordinate: place.coordinate)]
        #expect(StorySources.list(for: Self.session(place, matched: nil, applePlaces: apple))
                == [StorySource(kind: .appleMaps, detail: nil, url: nil)])
        // An empty Apple result is no source.
        #expect(StorySources.list(for: Self.session(place, matched: nil, applePlaces: [])) == [])
    }

    @Test func wikipediaOnlyCandidateLinksByPageID() {
        let place = Self.candidate(id: "wiki:no/12345", name: "Slottet")
        #expect(StorySources.list(for: Self.session(place, matched: place.id)) == [
            StorySource(kind: .wikipedia, detail: "Slottet", url: URL(string: "https://no.wikipedia.org/?curid=12345")),
        ])
    }

    @Test func articleTitleIsPercentEncoded() {
        let source = StorySources.wikipedia(Self.candidate(wikipediaTitle: "no:Akershus festning"))
        #expect(source?.url == URL(string: "https://no.wikipedia.org/wiki/Akershus_festning"))
        let accented = StorySources.wikipedia(Self.candidate(wikipediaTitle: "fr:Château d'If"))
        #expect(accented?.url?.absoluteString == "https://fr.wikipedia.org/wiki/Ch%C3%A2teau_d'If")
        // "?" and "#" would end the name: encoded.
        let question = StorySources.wikipedia(Self.candidate(wikipediaTitle: "en:Why? (film)"))
        #expect(question?.url?.absoluteString == "https://en.wikipedia.org/wiki/Why%3F_(film)")
    }

    @Test func malformedWikipediaValuesGiveNoArticle() {
        // No language prefix, an empty name, a code that is not a language, a non-numeric page id.
        #expect(StorySources.wikipedia(Self.candidate(wikipediaTitle: "Pantheon")) == nil)
        #expect(StorySources.wikipedia(Self.candidate(wikipediaTitle: "en:  ")) == nil)
        #expect(StorySources.wikipedia(Self.candidate(wikipediaTitle: "Category:Rome")) == nil)
        #expect(StorySources.wikipedia(Self.candidate(id: "wiki:en/abc")) == nil)
        #expect(StorySources.wikipedia(Self.candidate(id: "wiki:en/")) == nil)
        #expect(StorySources.wikipedia(Self.candidate(id: "osm:node/1")) == nil)
    }

    @Test func aTitleNeverLeavesWikipediaOrg() {
        // "https" passes as a language code, but the host is still a wikipedia.org subdomain.
        let odd = StorySources.wikipedia(Self.candidate(wikipediaTitle: "https://evil.example"))
        #expect(odd?.url?.host?.hasSuffix(".wikipedia.org") == true)
        #expect(odd?.url?.host == "https.wikipedia.org")
    }

    @Test func openStreetMapIDs() {
        #expect(StorySources.openStreetMap("osm:node/1")?.url == URL(string: "https://www.openstreetmap.org/node/1"))
        #expect(StorySources.openStreetMap("osm:relation/77")?.detail == "relation/77")
        #expect(StorySources.openStreetMap("osm:area/1") == nil)
        #expect(StorySources.openStreetMap("osm:node/x1") == nil)
        #expect(StorySources.openStreetMap("osm:node/") == nil)
        #expect(StorySources.openStreetMap("osm:node/1/2") == nil)
        #expect(StorySources.openStreetMap("wiki:en/1") == nil)
    }

    @Test func malformedWikidataIsLeftOut() {
        for bad in ["", "Q", "q123", "P31", "Q12a"] {
            let place = Self.candidate(wikidata: bad)
            #expect(StorySources.list(for: Self.session(place, matched: place.id)).map(\.kind) == [.openStreetMap])
        }
    }

    // MARK: - Location line

    @Test func locationLineIsCityAndCountry() {
        #expect(PlaceLocationLine.text(Address(line: "Piazza della Rotonda", district: "Pigna", city: "Roma",
                                               country: "Italia")) == "Roma, Italia")
    }

    @Test func locationLineFallsBackAndSkipsBlanks() {
        #expect(PlaceLocationLine.text(Address(district: "Pigna", country: "Italia")) == "Pigna, Italia")
        #expect(PlaceLocationLine.text(Address(city: "Roma")) == "Roma")
        #expect(PlaceLocationLine.text(Address(city: " ", country: "Italia")) == "Italia")
        #expect(PlaceLocationLine.text(Address(line: "Via 1")) == nil)
        #expect(PlaceLocationLine.text(nil) == nil)
    }

    // MARK: - Walk stories

    static func walkStory(kind: WalkStory.Kind = .buzz, place: Candidate?, address: Address? = nil,
                          applePlaces: [ApplePlace]? = nil) -> WalkStory {
        WalkStory(id: UUID(), kind: kind, place: place, position: .at(), course: nil, language: .norwegian, title: "T",
                  levels: ["S."], createdAt: .now, address: address, applePlaces: applePlaces)
    }

    @Test func walkStorySources() {
        let osm = StorySource(kind: .openStreetMap, detail: "way/42", url: URL(string: "https://www.openstreetmap.org/way/42"))
        let apple = StorySource(kind: .appleMaps, detail: nil, url: nil)
        let file = URL(string: "https://commons.wikimedia.org/wiki/File:Pantheon.jpg")
        let image = PlaceImageInfo(thumbnailURL: URL(string: "https://upload.wikimedia.org/p.jpg")!, author: "Ann",
                                   licence: "CC BY-SA 4.0", filePage: file)
        let credit = StorySource(kind: .imageCredit, detail: "Foto: Ann, CC BY-SA 4.0, Wikimedia Commons", url: file)
        let place = Self.candidate()
        #expect(StorySources.list(for: Self.walkStory(place: place), image: image, language: .norwegian) == [osm, credit])
        #expect(StorySources.list(for: Self.walkStory(place: place, address: Address(city: "Roma")), image: image,
                                  language: .norwegian) == [osm, apple, credit])
        // Apple places alone also count; a chosen story lists the same as a buzz story; English credit text.
        #expect(StorySources.list(for: Self.walkStory(kind: .chosen, place: place, applePlaces: [ApplePlace(name: "Bar", category: "bar", coordinate: .at())]),
                                  image: nil, language: .english) == [osm, apple])
        #expect(StorySources.list(for: Self.walkStory(place: place), image: image, language: .english).last?.detail
                == "Photo: Ann, CC BY-SA 4.0, Wikimedia Commons")
        // No author and no licence: no credit to show.
        let bare = PlaceImageInfo(thumbnailURL: image.thumbnailURL, author: nil, licence: " ", filePage: file)
        #expect(StorySources.list(for: Self.walkStory(place: place), image: bare, language: .norwegian) == [osm])
    }

    @Test func stopStorySourcesAreAppleMapsOnly() {
        let image = PlaceImageInfo(thumbnailURL: URL(string: "https://upload.wikimedia.org/p.jpg")!, author: "Ann",
                                   licence: "CC0")
        #expect(StorySources.list(for: Self.walkStory(kind: .stop, place: nil), image: image, language: .norwegian) == [])
        #expect(StorySources.list(for: Self.walkStory(kind: .stop, place: nil, address: Address(city: "Roma")), image: image,
                                  language: .norwegian) == [StorySource(kind: .appleMaps, detail: nil, url: nil)])
    }
}
