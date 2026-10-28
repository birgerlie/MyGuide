import Foundation
import Testing
@testable import MyGuideCore

@Suite struct WalkPromptTests {
    static let origin = Coordinate(latitude: 0, longitude: 0)
    /// Places at whole metres north/east of `origin` (`.at`): the distance is exact, the bearing 0 (north), 90 (east),
    /// 180 (south, negative north) or 270 (west, negative east).
    static func place(_ id: String, _ name: String, _ kind: String, north: Double = 0, east: Double = 0, tier: PlaceTier,
                      summary: String? = nil, title: String? = nil, tags: [String: String]? = nil) -> WalkingPlace {
        WalkingPlace(candidate: Candidate(id: id, name: name, coordinate: .at(north: north, east: east), kind: kind,
                                          summary: summary, wikipediaTitle: title, tags: tags), tier: tier)
    }
    static let gate = place("osm:node/1", "Michaelertor", "historic=city_gate", north: 50, tier: .top,
                            summary: "Gate of the palace.", title: "de:Michaelertor", tags: ["start_date": "1725"])
    static let church = place("osm:node/2", "Peterskirche", "amenity=place_of_worship", north: 80, tier: .good,
                              tags: ["architect": "Hildebrandt"])
    static let plaque = place("osm:node/3", "Mozart plaque", "historic=memorial", east: 30, tier: .wikiOnly)
    static let castle = place("osm:node/4", "Hofburg", "historic=castle", north: 200, tier: .top)
    static let facts = [gate, church, plaque, castle]
    static let buzz = Buzz(id: UUID(), place: gate, distance: 40, bearing: 90, title: "Michaelertor", detail: "40 m right",
                           usedOverride: false)
    static let prior = PriorStory(placeID: "osm:node/1", level: .first, text: "Told before.", toldAt: .now)
    static let utc = TimeZone(identifier: "UTC")!
    // 1 000 000 s after 1970 = 11 d 13 h 46 m 40 s → 13:46 UTC on 12 January 1970; 1 January 1970 was a Thursday,
    // + 11 days = Monday.
    static let now = Date(timeIntervalSince1970: 1_000_000)
    /// Ten minutes before `now`: 13:36 UTC.
    static let recent = RecentStory(toldAt: now - 600, placeName: "Akershus Fortress", level: .first,
                                    text: "Built in 1299. Then rebuilt.", prepared: false)
    static let address = Address(line: "Kirkegata 15", district: "Kvadraturen", city: "Oslo")
    static let cameFrom = CameFrom(street: "Stortorvet", minutesAgo: 3, distance: 220, bearing: 180, along: "Kirkegata")
    static let context = WalkContext(address: address, bearing: 0, street: "Kirkegata", cameFrom: cameFrom)
    /// 120 m east of `origin`: bearing 90.
    static let library = ApplePlace(name: "Deichman", category: "library", coordinate: .at(east: 120))

    static func buzzInput(_ buzz: Buzz = WalkPromptTests.buzz, context: WalkContext = WalkPromptTests.context,
                          nearby: [WalkingPlace] = WalkPromptTests.facts, articleText: String? = nil,
                          applePlaces: [ApplePlace]? = [WalkPromptTests.library], recent: [RecentStory] = [WalkPromptTests.recent],
                          priors: [PriorStory] = [WalkPromptTests.prior], language: StoryLanguage = .english) -> String {
        PromptBuilder.walkBuzzInput(buzz: buzz, position: origin, context: context, nearby: nearby, articleText: articleText,
                                    applePlaces: applePlaces, recent: recent, priors: priors, language: language,
                                    now: now, timeZone: utc)
    }
    static func stopInput(_ nearby: [WalkingPlace], context: WalkContext = WalkPromptTests.context, articleText: String? = nil,
                          applePlaces: [ApplePlace]? = nil, priors: [PriorStory] = []) throws -> String {
        let stop = try #require(PromptBuilder.walkStop(nearby, position: origin))
        return PromptBuilder.walkStopInput(stop, position: origin, context: context, articleText: articleText,
                                           applePlaces: applePlaces, recent: [], priors: priors, language: .english,
                                           now: now, timeZone: utc)
    }
    static func lines(_ s: String) -> [String] { s.components(separatedBy: "\n") }
    /// The field names of the top-level lines (not list items or indented facts or told-so-far levels).
    static func fields(_ s: String) -> [String] {
        lines(s).filter { !$0.hasPrefix(" ") && !$0.hasPrefix("- ") && !$0.hasPrefix("Level ") }
            .map { String($0.prefix { $0 != ":" && $0 != ";" }) }
    }
    static func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

    // MARK: - Buzz

    @Test func buzzInputFieldOrderAndLines() {
        let s = Self.buzzInput()
        #expect(Self.fields(s) == ["Story", "Position", "Time", "Walking", "Came from", "Subject", "Facts about Michaelertor",
                                   "Nearby", "Also on Apple Maps", "Told in the last 3 hours", "Told here before",
                                   "Length", "Answer in", "Task"])
        let l = Self.lines(s)
        #expect(l.first == "Story: walking buzz, first level")
        #expect(l.contains("Position: Kirkegata 15, Kvadraturen, Oslo"))
        #expect(l.contains("Time: 13:46 Monday"))
        #expect(l.contains("Walking: north along Kirkegata"))
        // Walking bearing 0, came-from bearing 180: r = 180 − 0 = 180 > 150 → behind; 220 rounds to 220.
        #expect(l.contains("Came from: Stortorvet, 3 min ago, 220 m, behind, along Kirkegata"))
        // r = 90 − 0 = 90 → 60 < 90 ≤ 120, positive → to your right; 40 rounds to 40.
        #expect(l.contains("Subject: Michaelertor (historic=city_gate), 40 m, to your right"))
        #expect(s.contains("\nFacts about Michaelertor:\n  OSM: start_date=1725\n  Wikipedia: Gate of the palace.\nNearby:\n"))
        // Nearby, tier then distance, the buzzed gate left out: castle .top 200 m (bearing 0 → ahead), church .good 80 m
        // (ahead), plaque .wikiOnly 30 m east (r = 90 → to your right).
        #expect(s.contains("\nNearby:\n- Hofburg (historic=castle), 200 m, ahead\n"
                           + "- Peterskirche (amenity=place_of_worship), 80 m, ahead\n  OSM: architect=Hildebrandt\n"
                           + "- Mozart plaque (historic=memorial), 30 m, to your right\nAlso on Apple Maps:\n"))
        // Library 120 m east: r = 90 → to your right.
        #expect(s.contains("\nAlso on Apple Maps:\n- Deichman (library), 120 m, to your right\nTold in the last 3 hours:\n"))
        #expect(s.contains("\nTold in the last 3 hours:\n- 13:36 Akershus Fortress level 1: \"Built in 1299.\"\n"))
        #expect(s.contains("\nTold here before:\n- [osm:node/1] level 1: Told before.\n"))
        // gate is .top: buzz first level 75 words; 75 · 60 / 150 = 30 s. (A .good place: 60 words, 24 s.)
        #expect(l.contains("Length: about 75 words (30 seconds spoken), 2–3 points"))
        #expect(l.contains("Answer in: English"))
        #expect(l.last == "Task: Tell the user about the subject they are passing.")
        #expect(!s.contains("Already told") && Self.count("Answer in:", in: s) == 1)
    }
    @Test func buzzWithoutAddressSaysLookupFailed() {
        let s = Self.buzzInput(context: WalkContext(address: nil, bearing: 0, street: nil, cameFrom: nil))
        // origin is (0, 0).
        #expect(s.contains("\nPosition: address lookup failed\nCoordinates: 0.000000, 0.000000\nTime: "))
        // An address with no parts is a failed lookup too.
        let empty = Self.buzzInput(context: WalkContext(address: Address(), bearing: 0, street: nil, cameFrom: nil))
        #expect(empty.contains("\nPosition: address lookup failed\n"))
        // Without a street the walking line is the direction alone; without came-from the field is left out.
        #expect(s.contains("\nWalking: north\n") && !s.contains("Came from"))
        // A good address prints no coordinates.
        #expect(!Self.buzzInput().contains("Coordinates:"))
    }
    @Test func buzzWithoutDirectionSaysUnknown() {
        for bearing in [nil, -1, .nan] as [Double?] {
            let s = Self.buzzInput(context: WalkContext(address: Self.address, bearing: bearing, street: "Kirkegata", cameFrom: Self.cameFrom))
            #expect(s.contains("\nWalking: direction unknown\n"))
            // Without a direction, sides are compass words: subject bearing 90 → east; came-from bearing 180 → south.
            #expect(s.contains("\nSubject: Michaelertor (historic=city_gate), 40 m, east\n"))
            #expect(s.contains("\nCame from: Stortorvet, 3 min ago, 220 m, south, along Kirkegata\n"))
            // Library bearing 90 → east; castle bearing 0 → north.
            #expect(s.contains("- Deichman (library), 120 m, east\n") && s.contains("- Hofburg (historic=castle), 200 m, north\n"))
        }
    }
    @Test func cameFromUnderAMinuteAndWithoutAlong() {
        let recentStreet = CameFrom(street: "Prinsens gate", minutesAgo: 0, distance: 64, bearing: 225, along: nil)
        let s = Self.buzzInput(context: WalkContext(address: Self.address, bearing: 90, street: "Kirkegata", cameFrom: recentStreet))
        // 64 → 60 m; r = 225 − 90 = 135 → 120 < 135 ≤ 150, positive → behind-right. Bearing 90 → "Walking: east".
        #expect(s.contains("\nWalking: east along Kirkegata\nCame from: Prinsens gate, under a minute ago, 60 m, behind-right\n"))
    }
    @Test func buzzFactsBlockIsOmittedWhenEmptyAndNeighboursCappedAtFour() {
        let bare = Self.place("osm:node/9", "Bare", "k", north: 40, tier: .good)
        let b = Buzz(id: UUID(), place: bare, distance: 40, bearing: 0, title: "Bare", detail: "40 m ahead", usedOverride: false)
        let many = (0..<7).map { Self.place("osm:node/1\($0)", "P\($0)", "k", north: Double(100 + $0 * 10), tier: .good) }
        let s = Self.buzzInput(b, nearby: [bare] + many, applePlaces: nil)
        #expect(!s.contains("Facts about") && !s.contains("Also on Apple Maps"))
        // Seven .good places 100…160 m: the nearest four, 100–130 m.
        #expect(Self.lines(s).filter { $0.hasPrefix("- P") }.count == 4)
        #expect(s.contains("- P3 (k), 130 m, ahead") && !s.contains("- P4 "))
        // .good subject: 60 words; 60 · 60 / 150 = 24 s.
        #expect(s.contains("\nLength: about 60 words (24 seconds spoken), 2–3 points\n"))
        // Alone: no Nearby field at all.
        #expect(!Self.buzzInput(b, nearby: [bare], applePlaces: nil).contains("Nearby"))
    }
    @Test func buzzArticleTextReplacesTheSummary() {
        let s = Self.buzzInput(articleText: "FULL TEXT")
        #expect(s.contains("\n  Wikipedia: FULL TEXT\n") && !s.contains("Gate of the palace."))
        for missing in [nil, "", " \n "] as [String?] {
            #expect(Self.buzzInput(articleText: missing).contains("\n  Wikipedia: Gate of the palace.\n"))
        }
    }
    @Test func appleMapsDropsTheSubjectAndListedNeighbours() {
        let dupes = [ApplePlace(name: "MICHAELERTOR", category: "landmark", coordinate: .at(north: 50)),
                     ApplePlace(name: "Péterskirche", category: "landmark", coordinate: .at(north: 80)),
                     Self.library]
        let s = Self.buzzInput(applePlaces: dupes)
        #expect(s.contains("\nAlso on Apple Maps:\n- Deichman (library), 120 m, to your right\nTold"))
        #expect(!s.contains("MICHAELERTOR") && !s.contains("Péterskirche"))
        // A place not listed (beyond the four neighbours) does not suppress its Apple Maps namesake.
        let many = (0..<5).map { Self.place("osm:node/1\($0)", "P\($0)", "k", north: Double(100 + $0 * 10), tier: .good) }
        let p4 = ApplePlace(name: "P4", category: "park", coordinate: .at(north: 140))
        #expect(Self.buzzInput(nearby: [Self.gate] + many, applePlaces: [p4]).contains("\n- P4 (park), 140 m, ahead\n"))
    }
    @Test func buzzAnswersInNorwegian() {
        let s = Self.buzzInput(language: .norwegian)
        #expect(s.contains("\nAnswer in: Norwegian Bokmål\nTask: ") && Self.count("Answer in:", in: s) == 1)
    }

    // MARK: - Stop

    @Test func stopWithPlacesWithin150mIsNormal() throws {
        let s = try Self.stopInput(Self.facts, articleText: nil, applePlaces: [Self.library], priors: [Self.prior])
        #expect(Self.fields(s) == ["Story", "Position", "Time", "Standing still", "Facts about Michaelertor (historic=city_gate), 50 m, ahead",
                                   "Nearby", "Also on Apple Maps", "Told in the last 3 hours", "Told here before",
                                   "Length", "Answer in", "Task"])
        #expect(Self.lines(s).first == "Story: stop, first level")
        // Walked in heading 0 → north; came-from is never on a stop story.
        #expect(s.contains("\nStanding still; walked in heading north along Kirkegata\n") && !s.contains("Came from"))
        // Best tier, nearest: gate .top 50 m (r = 0 → ahead) gets the facts; church .good 80 m and plaque .wikiOnly 30 m
        // (east, r = 90 → to your right) are Nearby; the castle (200 m) is out.
        #expect(s.contains("\nFacts about Michaelertor (historic=city_gate), 50 m, ahead:\n  OSM: start_date=1725\n"
                           + "  Wikipedia: Gate of the palace.\nNearby:\n"
                           + "- Peterskirche (amenity=place_of_worship), 80 m, ahead\n  OSM: architect=Hildebrandt\n"
                           + "- Mozart plaque (historic=memorial), 30 m, to your right\nAlso on Apple Maps:\n"))
        #expect(!s.contains("Hofburg") && !s.contains("Worth the detour"))
        #expect(s.contains("\nTold here before:\n- [osm:node/1] level 1: Told before.\n"))
        // Best listed tier .top: stop = min(75, 50) = 50 words; 50 · 60 / 150 = 20 s. (.wikiOnly: min(40, 50) = 40, 16 s.)
        #expect(s.contains("\nLength: about 50 words (20 seconds spoken), 2–3 points\n"))
        #expect(Self.lines(s).last == "Task: Tell the user about the spot where they are standing.")
        #expect(Self.count("Answer in:", in: s) == 1)
    }
    @Test func stopListsTheBestTierFirstAndUsesItsTierForLength() throws {
        // Only a .wikiOnly place within 150 m (149 m, inside the boundary): 40 words, 16 s; facts block says none found.
        let s = try Self.stopInput([Self.place("osm:node/7", "Well", "historic=well", north: -149, tier: .wikiOnly),
                                    Self.place("osm:node/8", "Far", "k", north: 151, tier: .top)])
        // Bearing 180 against heading 0: r = 180 → behind; 149 → 150 m.
        #expect(s.contains("\nFacts about Well (historic=well), 150 m, behind: none found\n"))
        #expect(s.contains("\nLength: about 40 words (16 seconds spoken), 2–3 points\n"))
        #expect(!s.contains("Far") && !s.contains("Nearby"))
        // .good best: min(60, 50) = 50 words, 20 s.
        let good = try Self.stopInput([Self.church])
        #expect(good.contains("\nLength: about 50 words (20 seconds spoken), 2–3 points\n"))
    }
    @Test func stopFactsAreCappedAtFive() throws {
        let many = (0..<8).map { Self.place("osm:node/2\($0)", "Q\($0)", "k", north: Double(10 + $0 * 10), tier: .good) }
        #expect(PromptBuilder.stopFacts(many, position: Self.origin).count == 5)
        let s = try Self.stopInput(many)
        // Q0 (10 m) gets the facts; Q1…Q4 (20–50 m) are Nearby; Q5 (60 m) is the sixth and left out.
        #expect(s.contains("Facts about Q0 (k), 10 m, ahead: none found"))
        #expect(s.contains("- Q4 (k), 50 m, ahead") && !s.contains("Q5"))
    }
    @Test func stopWithOnlyDistantPlacesPointsToDetour() throws {
        let good = Self.place("osm:node/30", "Good", "historic=church", north: 300, tier: .good)
        let top = Self.place("osm:node/31", "Top", "historic=castle", north: -450, tier: .top)
        let tooFar = Self.place("osm:node/32", "TooFar", "historic=castle", east: 600, tier: .top)
        let wiki = Self.place("osm:node/33", "Wiki", "wikipedia", east: 200, tier: .wikiOnly)
        let s = try Self.stopInput([good, tooFar, top, wiki], applePlaces: [Self.library])
        #expect(Self.fields(s) == ["Story", "Position", "Time", "Standing still", "Worth the detour", "Also on Apple Maps",
                                   "Told in the last 3 hours", "Told here before", "Length", "Answer in", "Task"])
        // Best two by tier then distance within 500 m: Top .top 450 m (bearing 180, r = 180 → behind), then Good .good
        // 300 m (r = 0 → ahead); Wiki (.wikiOnly) is third; TooFar (600 m) is beyond 500 m.
        #expect(s.contains("\nWorth the detour:\n- Top (historic=castle), 450 m, behind\n- Good (historic=church), 300 m, ahead\nAlso on Apple Maps:\n"))
        #expect(!s.contains("TooFar") && !s.contains("Wiki (") && !s.contains("Facts about") && !s.contains("Nearby"))
        // No tier: 40 words; 40 · 60 / 150 = 16 s.
        #expect(s.contains("\nLength: about 40 words (16 seconds spoken), 2–3 points\n"))
        #expect(Self.lines(s).last == "Task: There is little to tell right here: say so in one sentence, then point them to the place worth the detour.")
    }
    @Test func stopLadderBoundaries() throws {
        // 149 m → here; 151 m → detour; 499 m → detour; 501 m → nothing.
        let near = Self.place("osm:node/40", "Near", "k", north: 149, tier: .good)
        let mid = Self.place("osm:node/41", "Mid", "k", north: 151, tier: .good)
        let edge = Self.place("osm:node/42", "Edge", "k", north: 499, tier: .good)
        let out = Self.place("osm:node/43", "Out", "k", north: 501, tier: .top)
        #expect(PromptBuilder.walkStop([near, mid], position: Self.origin) == .here([near]))
        #expect(PromptBuilder.walkStop([mid, out], position: Self.origin) == .detour([mid]))
        #expect(PromptBuilder.walkStop([edge, out], position: Self.origin) == .detour([edge]))
        #expect(PromptBuilder.walkStop([out], position: Self.origin) == nil)
        #expect(PromptBuilder.walkStop([], position: Self.origin) == nil)
        // detourLimit caps the detour list at two.
        let three = (0..<3).map { Self.place("osm:node/5\($0)", "D\($0)", "k", north: Double(200 + $0 * 50), tier: .good) }
        #expect(PromptBuilder.walkStop(three, position: Self.origin) == .detour(Array(three.prefix(2))))
    }
    @Test func standingStillWithoutDirectionOrStreet() throws {
        let noDirection = try Self.stopInput([Self.gate], context: WalkContext(address: Self.address, bearing: nil, street: "Kirkegata", cameFrom: Self.cameFrom))
        #expect(noDirection.contains("\nStanding still\n") && !noDirection.contains("Came from"))
        // Without a direction the facts header uses a compass word: bearing 0 → north.
        #expect(noDirection.contains("Facts about Michaelertor (historic=city_gate), 50 m, north:"))
        let noStreet = try Self.stopInput([Self.gate], context: WalkContext(address: nil, bearing: 270, street: nil, cameFrom: nil))
        #expect(noStreet.contains("\nStanding still; walked in heading west\n"))
        #expect(noStreet.contains("\nPosition: address lookup failed\nCoordinates: 0.000000, 0.000000\n"))
    }

    // MARK: - Continuation

    static func story(_ kind: WalkStory.Kind, levels: [String] = ["First text."], course: Double? = 90,
                      address: Address? = Address(line: "Kirkegata 15", city: "Oslo"),
                      applePlaces: [ApplePlace]? = nil) -> WalkStory {
        WalkStory(id: UUID(), kind: kind, place: kind == .buzz ? gate.candidate : nil, position: origin, course: course,
                  language: .english, title: "T", levels: levels, createdAt: now - 60, address: address,
                  detail: kind == .buzz ? "50 m left" : nil, applePlaces: applePlaces)
    }
    static func continuation(_ story: WalkStory, level: StoryLevel = .more, nearby: [WalkingPlace] = WalkPromptTests.facts,
                             articleText: String? = nil, applePlaces: [ApplePlace]? = nil,
                             recent: [RecentStory] = [WalkPromptTests.recent], priors: [PriorStory] = [WalkPromptTests.prior]) -> String {
        PromptBuilder.walkContinuationInput(story: story, level: level, nearby: nearby, articleText: articleText,
                                            applePlaces: applePlaces, recent: recent, priors: priors, now: now, timeZone: utc)
    }

    @Test func buzzContinuationFieldOrderAndLines() {
        let s = Self.continuation(Self.story(.buzz), articleText: "FULL TEXT", applePlaces: [Self.library])
        #expect(Self.fields(s) == ["Story", "Position", "Time", "Walking", "Subject", "Facts about Michaelertor",
                                   "Also on Apple Maps", "Told so far", "Told in the last 3 hours", "Told here before",
                                   "Length", "Answer in", "Task"])
        let l = Self.lines(s)
        #expect(l.first == "Story: walking buzz, level 2")
        #expect(l.contains("Position: Kirkegata 15, Oslo") && l.contains("Time: 13:46 Monday"))
        // Stored course 90 → east; the street comes from the stored address line ("Kirkegata 15" → "Kirkegata").
        #expect(l.contains("Walking: east along Kirkegata") && !s.contains("Came from"))
        // Gate 50 m north of the stored position: r = 0 − 90 = −90 → to your left.
        #expect(l.contains("Subject: Michaelertor (historic=city_gate), 50 m, to your left"))
        #expect(s.contains("\nFacts about Michaelertor:\n  OSM: start_date=1725\n  Wikipedia: FULL TEXT\n"))
        // Library bearing 90 against course 90: r = 0 → ahead.
        #expect(s.contains("\nAlso on Apple Maps:\n- Deichman (library), 120 m, ahead\nTold so far:\nLevel 1: First text.\nTold in the last 3 hours:\n"))
        #expect(s.contains("\nTold here before:\n- [osm:node/1] level 1: Told before.\n"))
        // Level 2: 200 words; 200 · 60 / 150 = 80 s.
        #expect(s.contains("\nLength: about 200 words (80 seconds spoken), 3–4 points\nAnswer in: English\n"))
        #expect(l.last == "Task: Continue from where the story left off; new points, from another domain where the facts allow; do not repeat.")
        #expect(!s.contains("Already told") && !s.contains("Nearby") && Self.count("Answer in:", in: s) == 1)
        // Without article text the summary stands in.
        #expect(Self.continuation(Self.story(.buzz)).contains("\n  Wikipedia: Gate of the palace.\n"))
    }
    @Test func stopContinuationListsNearbyPlaces() {
        let s = Self.continuation(Self.story(.stop, levels: ["A", "B"], course: 0), level: .evenMore)
        #expect(Self.fields(s) == ["Story", "Position", "Time", "Standing still", "Nearby", "Told so far",
                                   "Told in the last 3 hours", "Told here before", "Length", "Answer in", "Task"])
        #expect(Self.lines(s).first == "Story: stop, level 3")
        #expect(s.contains("\nStanding still; walked in heading north along Kirkegata\n"))
        // Within 150 m of the stored position, tier then distance, each with distance and side (heading 0).
        #expect(s.contains("\nNearby:\n- Michaelertor (historic=city_gate), 50 m, ahead\n  OSM: start_date=1725\n"
                           + "- Peterskirche (amenity=place_of_worship), 80 m, ahead\n  OSM: architect=Hildebrandt\n"
                           + "- Mozart plaque (historic=memorial), 30 m, to your right\nTold so far:\nLevel 1: A\nLevel 2: B\n"))
        #expect(!s.contains("Hofburg") && !s.contains("Subject"))
        // Level 3: 300 words; 300 · 60 / 150 = 120 s = 2 minutes.
        #expect(s.contains("\nLength: about 300 words (2 minutes spoken), as many as the facts carry\n"))
    }
    @Test func detourStopContinuationKeepsTheDetour() {
        let far = Self.place("osm:node/60", "Far", "historic=castle", north: 300, tier: .top)
        let s = Self.continuation(Self.story(.stop, course: 0), nearby: [far])
        #expect(s.contains("\nWorth the detour:\n- Far (historic=castle), 300 m, ahead\nTold so far:\n") && !s.contains("Nearby"))
        // Nothing within 500 m: neither field.
        let none = Self.continuation(Self.story(.stop, course: 0), nearby: [])
        #expect(!none.contains("Worth the detour") && !none.contains("Nearby"))
    }
    @Test func continuationWithoutAddressOrCourse() {
        let s = Self.continuation(Self.story(.buzz, course: nil, address: nil))
        #expect(s.contains("\nPosition: address lookup failed\nCoordinates: 0.000000, 0.000000\n"))
        #expect(s.contains("\nWalking: direction unknown\n"))
        // Compass word for the gate (bearing 0).
        #expect(s.contains("\nSubject: Michaelertor (historic=city_gate), 50 m, north\n"))
        let stop = Self.continuation(Self.story(.stop, course: nil, address: nil))
        #expect(stop.contains("\nStanding still\n"))
    }

    @Test func schemaIsStrictWithTitleAndStory() throws {
        let data = try JSONEncoder().encode(PromptBuilder.walkStorySchema)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["additionalProperties"] as? Bool == false)
        #expect((json["required"] as? [String]) == ["title", "story"])
        #expect(Set((json["properties"] as? [String: Any])?.keys.map { $0 } ?? []) == ["title", "story"])
    }
}
