import Foundation
import Testing
@testable import MyGuideCore

/// The streamed photo story (spec 6, 7.1, 8, 10, 14.2–14.4, 14.8–14.10, 15.2).
@Suite struct PhotoStoryFlowStreamingTests {
    // MARK: - Doubles

    /// Answers Overpass and Wikipedia over `send`, and streams `lines` for the OpenAI request.
    /// `onStream` runs when the stream is requested (before any line); `hang` keeps the stream open after the lines.
    final class StreamingHTTP: HTTPClient, @unchecked Sendable {
        let lines: [String]
        let failure: (any Error & Sendable)?
        let hang: Bool
        let onStream: @Sendable () -> Void
        let onOverpass: @Sendable () -> Void
        let onWikipedia: @Sendable () -> Void
        /// Overpass answers after this long; a cancelled wait is recorded in `overpassCancelled`.
        let overpassDelay: Duration
        let overpassCancelled = LockedBox(false)
        private let recorded = LockedBox<[URLRequest]>([])

        init(lines: [String], failure: (any Error & Sendable)? = nil, hang: Bool = false,
             onStream: @escaping @Sendable () -> Void = {}, onOverpass: @escaping @Sendable () -> Void = {},
             onWikipedia: @escaping @Sendable () -> Void = {}, overpassDelay: Duration = .zero) {
            self.lines = lines
            self.failure = failure
            self.hang = hang
            self.onStream = onStream
            self.onOverpass = onOverpass
            self.onWikipedia = onWikipedia
            self.overpassDelay = overpassDelay
        }

        var requests: [URLRequest] { recorded.value }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            recorded.withValue { $0.append(request) }
            let host = request.url?.host ?? ""
            let body: String
            if host.contains("overpass") {
                onOverpass()
                if overpassDelay > .zero {
                    do { try await Task.sleep(for: overpassDelay) } catch {
                        overpassCancelled.set(true)
                        throw error
                    }
                }
                body = GroundingTests.osmJSON
            } else if host.contains("wikipedia") {
                onWikipedia()
                body = GroundingTests.wikiJSON
            } else {
                body = ""
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
            recorded.withValue { $0.append(request) }
            onStream()
            let lines = lines, failure = failure, hang = hang
            let stream = AsyncThrowingStream<String, Error> { continuation in
                for line in lines { continuation.yield(line) }
                if !hang { continuation.finish(throwing: failure) }
            }
            return (stream, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        var openAIRequest: URLRequest? { requests.first { $0.url?.host == "api.openai.com" } }
        var searchRequests: [URLRequest] { requests.filter { $0.url?.host != "api.openai.com" } }
    }

    /// Sleeps `delay` (recording in `cancelled` when the sleep is cancelled), then answers.
    static func sleep(_ delay: Duration, cancelled: LockedBox<Bool>?) async throws {
        guard delay > .zero else { return }
        do { try await Task.sleep(for: delay) } catch {
            cancelled?.set(true)
            throw error
        }
    }
    struct Geo: ReverseGeocoding {
        var delay: Duration = .zero
        var cancelled: LockedBox<Bool>?
        var onCall: @Sendable () -> Void = {}
        func address(for: Coordinate) async throws -> Address {
            onCall()
            try await PhotoStoryFlowStreamingTests.sleep(delay, cancelled: cancelled)
            return Address(line: "Platz", city: "Wien", country: nil)
        }
    }
    struct Places: PointsOfInterestSearching {
        var delay: Duration = .zero
        var cancelled: LockedBox<Bool>?
        func places(around: Coordinate, radius: Double) async throws -> [ApplePlace] {
            try await PhotoStoryFlowStreamingTests.sleep(delay, cancelled: cancelled)
            return [PhotoStoryFlowTests.museum]
        }
    }
    final class Articles: ArticleTextSource, @unchecked Sendable {
        let result: String?
        let onCall: @Sendable () -> Void
        let delay: Duration
        let titles = LockedBox<[String]>([])
        init(_ result: String?, delay: Duration = .zero, onCall: @escaping @Sendable () -> Void = {}) {
            self.result = result
            self.delay = delay
            self.onCall = onCall
        }
        /// Like `ArticleTextSource`, never throws; a slow answer ignores cancellation, like a shared cache fetch.
        func text(wikipediaTitle: String) async -> String? {
            titles.withValue { $0.append(wikipediaTitle) }
            onCall()
            if delay > .zero {
                let end = ContinuousClock.now + delay
                while ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(20)) }
            }
            return result
        }
    }

    // MARK: - Fixtures

    /// 1 000 000 s after 1970; every timing below is measured on this injected clock.
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    /// At (0, 0), facing north (0°) with a ±10° compass and a 55° field of view.
    static let capture = GroundingTests.capture(heading: 0, acc: 10)

    /// 120 m due north of the capture point: bearing 0°, inside the view cone; it has an article title.
    static let tower = Candidate(id: "osm:node/7", name: "Tower", coordinate: .at(north: 120), kind: "man_made=tower",
                                 summary: "Tall.", wikipediaTitle: "en:Tower")
    /// 50 m due south: bearing 180°, behind the camera.
    static let shed = Candidate(id: "osm:node/8", name: "Shed", coordinate: .at(north: -50), kind: "building=shed")

    static func list(_ candidates: [Candidate] = [tower, shed], age: TimeInterval = 60, centre: Coordinate = .at(),
                     texts: [String: String] = [:], language: StoryLanguage = .english) -> NearbyList {
        NearbyList(centre: centre, fetchedAt: t0 - age, language: language, candidates: candidates, articleTexts: texts)
    }

    static let storyJSON = #"{"subject":"Tower","confidence":"likely","matchedCandidateID":"osm:node/7","title":"T","era":"1900","story":"A tall tale."}"#
    /// Three deltas: the identification, then the story in two pieces.
    static let storyChunks = [#"{"subject":"Tower","confidence":"likely","#,
                              #""matchedCandidateID":"osm:node/7","title":"T","era":"1900","story":"A tall"#,
                              #" tale."}"#]

    /// The model's JSON as a JSON string body, for embedding in the `response.completed` event.
    static func escaped(_ json: String) -> String {
        String(String(decoding: try! JSONEncoder().encode(json), as: UTF8.self).dropFirst().dropLast())
    }
    /// SSE lines: one delta per chunk, then `response.completed` carrying the whole JSON (usage 120 in / 40 out).
    static func sse(_ chunks: [String], final json: String? = nil) -> [String] {
        chunks.flatMap(OpenAIClientTests.delta) + OpenAIClientTests.completed(text: escaped(json ?? chunks.joined()))
    }
    static func sse(json: String, chunks: [String]) -> [String] { sse(chunks, final: json) }

    static func flow(_ http: StreamingHTTP, clock: LockedBox<Date> = LockedBox(t0), geocoder: ReverseGeocoding = Geo(),
                     pointsOfInterest: PointsOfInterestSearching? = nil, articles: ArticleTextSource? = nil,
                     storyDeadline: Duration = PhotoStoryFlow.defaultStoryDeadline,
                     priors: @escaping PriorStoryLookup = { _, _, _ in [] }) -> PhotoStoryFlow {
        PhotoStoryFlow(grounding: GroundingService(overpass: .init(http: http), wikipedia: .init(http: http), geocoder: geocoder),
                       openAI: OpenAIClient(apiKey: "k", http: http), priors: priors,
                       pointsOfInterest: pointsOfInterest, articles: articles,
                       timeZone: TimeZone(identifier: "UTC")!, storyDeadline: storyDeadline, now: { clock.value })
    }

    static let photo = TestImages.jpeg(width: 10, height: 10)

    /// Runs the list path, collecting every progress report.
    static func run(_ flow: PhotoStoryFlow, nearby: NearbyList?, capture: CaptureContext = capture,
                    progress: LockedBox<[PhotoStoryProgress]> = LockedBox([])) async throws -> PhotoStoryOutcome {
        try await flow.tellFirstStoryStreaming(photoJPEG: photo, capture: capture, language: .english, nearby: nearby) { p in
            progress.withValue { $0.append(p) }
        }
    }

    static func inputText(_ http: StreamingHTTP) throws -> String {
        let request = try #require(http.openAIRequest)
        return try PhotoStoryFlowTests.inputText(request)
    }

    static func partials(_ events: [PhotoStoryProgress]) -> [PartialFirstStory] {
        events.compactMap { if case .partial(let p) = $0 { p } else { nil } }
    }

    // MARK: - Constants

    @Test func specNumbers() {
        #expect(PhotoStoryFlow.freshPathWait == .milliseconds(1500))
        #expect(PhotoStoryFlow.articleLimit == 1500)
        #expect(PhotoStoryFlow.guessDistance == 250)
        #expect(PhotoStoryFlow.defaultStoryDeadline == .seconds(90))
    }

    // MARK: - Fresh list

    @Test func freshListGivesGuessBeforeWriting() async throws {
        let http = StreamingHTTP(lines: Self.sse(Self.storyChunks))
        let progress = LockedBox<[PhotoStoryProgress]>([])
        let outcome = try await Self.run(Self.flow(http), nearby: Self.list(), progress: progress)

        let events = progress.value
        try #require(events.count >= 4)
        #expect(events[0] == .finding)
        guard case .guess(let guess) = events[1] else { Issue.record("no guess: \(events)"); return }
        // .at(north: 120) is 120 m by haversine from (0, 0), due north: bearing 0°, inside a cone around heading 0°.
        #expect(guess.candidate.id == "osm:node/7" && guess.inView == true)
        #expect(abs(guess.distance - 120) < 0.01 && abs(guess.bearing) < 0.01)
        #expect(events[2] == .writing)
        #expect(events.dropFirst(3).allSatisfy { if case .partial = $0 { true } else { false } })
        let partials = Self.partials(events)
        #expect(partials.first == PartialFirstStory(subject: "Tower", confidence: "likely"))
        #expect(partials.last?.story == "A tall tale." && partials.last?.matchedCandidateID == "osm:node/7")

        // The request is the list's ranked candidates, not the fresh search's (Gate osm:node/1, Palace wiki:en/5).
        let text = try Self.inputText(http)
        #expect(text.contains("[osm:node/7] Tower") && text.contains("[osm:node/8] Shed"))
        #expect(!text.contains("osm:node/1") && !text.contains("wiki:en/5"))
        // The fast geocoder made the 1.5 s budget.
        #expect(text.contains("Position: Platz, Wien"))
        #expect(outcome.session.grounding.candidates.map(\.candidate.id) == ["osm:node/7", "osm:node/8"])
        #expect(outcome.session.levels == ["A tall tale."])
        #expect(outcome.session.identified.matchedCandidateID == "osm:node/7")
        #expect(outcome.timings.listFresh)
        // fetchedAt = t0 − 60 s, measured at t0 → 60 s.
        #expect(outcome.timings.listAgeS == 60)
        #expect(await outcome.freshCandidates() == nil)
        // Usage from the completed event: 120 input, 40 output tokens.
        #expect(outcome.usage.map(\.inputTokens) == [120] && outcome.usage.map(\.outputTokens) == [40])
        #expect(outcome.usage.first?.kind == .story)
    }

    /// The guess is the first ranked candidate in view and at most 250 m away.
    @Test(arguments: [
        // 249 m north: in view and ≤ 250 m → guess.
        (249.0, true),
        // 251 m north: in view but 251 > 250 → no guess.
        (251.0, false),
        // 50 m south: bearing 180°, out of view → no guess.
        (-50.0, false),
    ])
    func guessNeedsInViewWithin250m(north: Double, expectGuess: Bool) async throws {
        let place = Candidate(id: "osm:node/9", name: "Spot", coordinate: .at(north: north), kind: "historic=yes")
        let json = #"{"subject":"Spot","confidence":"likely","matchedCandidateID":null,"title":"T","era":"e","story":"S."}"#
        let progress = LockedBox<[PhotoStoryProgress]>([])
        let outcome = try await Self.run(Self.flow(StreamingHTTP(lines: Self.sse([json]))), nearby: Self.list([place]),
                                         progress: progress)
        let guesses = progress.value.filter { if case .guess = $0 { true } else { false } }
        #expect(guesses.count == (expectGuess ? 1 : 0))
        #expect((outcome.timings.guessMs != nil) == expectGuess)
    }

    @Test func noHeadingMeansNoGuess() async throws {
        // A library photo has no heading: inView is nil for every candidate, so nothing is "in view".
        let json = #"{"subject":"Tower","confidence":"likely","matchedCandidateID":null,"title":"T","era":"e","story":"S."}"#
        let progress = LockedBox<[PhotoStoryProgress]>([])
        _ = try await Self.run(Self.flow(StreamingHTTP(lines: Self.sse([json]))), nearby: Self.list(),
                               capture: GroundingTests.capture(heading: nil, acc: nil), progress: progress)
        #expect(!progress.value.contains { if case .guess = $0 { true } else { false } })
    }

    // MARK: - Stale or missing list

    @Test(arguments: [
        // 601 s old (> 600 s), centred on the photo → stale; age reported 601.
        (601.0, 0.0, 601),
        // 60 s old but centred 251 m away (> 250 m) → stale; age reported 60.
        (60.0, 251.0, 60),
    ])
    func staleListWaitsForFreshSearch(age: TimeInterval, centreNorth: Double, expectedAge: Int) async throws {
        let json = #"{"subject":"Gate","confidence":"likely","matchedCandidateID":"osm:node/1","title":"T","era":"e","story":"S."}"#
        let http = StreamingHTTP(lines: Self.sse([json]))
        let progress = LockedBox<[PhotoStoryProgress]>([])
        let outcome = try await Self.run(Self.flow(http), nearby: Self.list(age: age, centre: .at(north: centreNorth)),
                                         progress: progress)
        #expect(!progress.value.contains { if case .guess = $0 { true } else { false } })
        #expect(Array(progress.value.prefix(2)) == [.finding, .writing])
        let text = try Self.inputText(http)
        #expect(text.contains("[osm:node/1] Gate") && text.contains("[wiki:en/5] Palace"))
        #expect(!text.contains("osm:node/7"))
        #expect(text.contains("Position: Platz, Wien"))
        #expect(outcome.session.identified.matchedCandidateID == "osm:node/1")
        #expect(!outcome.timings.listFresh && outcome.timings.listAgeS == expectedAge)
        #expect(outcome.timings.guessMs == nil)
        #expect(await outcome.freshCandidates() == nil)
    }

    @Test func listInAnotherLanguageIsNotUsed() async throws {
        let json = #"{"subject":"Gate","confidence":"likely","matchedCandidateID":null,"title":"T","era":"e","story":"S."}"#
        let http = StreamingHTTP(lines: Self.sse([json]))
        let outcome = try await Self.run(Self.flow(http), nearby: Self.list(language: .norwegian))
        #expect(!outcome.timings.listFresh && outcome.timings.listAgeS == nil)
        #expect(try Self.inputText(http).contains("[osm:node/1] Gate"))
    }

    @Test func timingsComeFromTheInjectedClock() async throws {
        // The clock only moves inside the doubles, at points the flow reaches one after another:
        //   Overpass +1 s, Wikipedia +0.5 s, geocoder +0.25 s  → the fresh search ends at t0 + 1.75 s → placeSearchMs 1750;
        //   the article source +0.125 s                         → articleMs 125;
        //   the stream opens +2 s before its first line         → firstTextMs 2000 and modelMs 2000;
        //   nothing moves between the start and "finding"       → feedbackMs 0.
        // Every step is a sum of powers of two, so the doubles are exact.
        let clock = LockedBox(Self.t0)
        func advance(_ s: TimeInterval) -> @Sendable () -> Void { { clock.withValue { $0 += s } } }
        let http = StreamingHTTP(lines: Self.sse(Self.storyChunks), onStream: advance(2), onOverpass: advance(1),
                                 onWikipedia: advance(0.5))
        let articles = Articles("Palace text.", onCall: advance(0.125))
        let outcome = try await Self.run(Self.flow(http, clock: clock, geocoder: Geo(onCall: advance(0.25)), articles: articles),
                                         nearby: nil)
        #expect(outcome.timings == PhotoStoryTimings(feedbackMs: 0, guessMs: nil, placeSearchMs: 1750, articleMs: 125,
                                                     firstTextMs: 2000, modelMs: 2000, listFresh: false, listAgeS: nil,
                                                     // "Palace text." = 6 + 1 + 5 = 12 characters.
                                                     articleChars: 12))
        // The fresh search ranks Palace (Wikipedia-backed) before Gate, so the article is Palace's.
        #expect(articles.titles.value == ["en:Palace"])
    }

    @Test func timingsRoundTripAsJSON() throws {
        let timings = PhotoStoryTimings(feedbackMs: 1, guessMs: nil, placeSearchMs: 3, articleMs: nil, firstTextMs: 5,
                                        modelMs: 6, listFresh: true, listAgeS: 7, articleChars: 0)
        #expect(try JSONDecoder().decode(PhotoStoryTimings.self, from: JSONEncoder().encode(timings)) == timings)
    }

    // MARK: - Honest partial identification

    @Test func partialIdentificationDropsUnknownID() async throws {
        let json = #"{"subject":"Tower","confidence":"certain","matchedCandidateID":"osm:999","title":"T","era":"e","story":"Hi."}"#
        let chunks = [#"{"subject":"Tower","confidence":"certain","#, #""matchedCandidateID":"osm:999","#,
                      #""title":"T","era":"e","story":"H"#, #"i."}"#]
        let progress = LockedBox<[PhotoStoryProgress]>([])
        let outcome = try await Self.run(Self.flow(StreamingHTTP(lines: Self.sse(json: json, chunks: chunks))),
                                         nearby: Self.list(), progress: progress)
        let partials = Self.partials(progress.value)
        try #require(partials.count == 4)
        #expect(partials.allSatisfy { $0.confidence != "certain" && $0.matchedCandidateID == nil })
        #expect(partials.map(\.confidence) == ["likely", "likely", "likely", "likely"])
        #expect(outcome.session.identified.matchedCandidateID == nil)
        #expect(outcome.session.identified.confidence == .likely)
    }

    @Test func partialCertainShowsOnlyOnceAKnownIDHasArrived() async throws {
        let json = #"{"subject":"Tower","confidence":"certain","matchedCandidateID":"osm:node/7","title":"T","era":"e","story":"Hi."}"#
        let chunks = [#"{"subject":"Tower","confidence":"certain","#, #""matchedCandidateID":"osm:node/7","#,
                      #""title":"T","era":"e","story":"Hi."}"#]
        let progress = LockedBox<[PhotoStoryProgress]>([])
        let outcome = try await Self.run(Self.flow(StreamingHTTP(lines: Self.sse(json: json, chunks: chunks))),
                                         nearby: Self.list(), progress: progress)
        let partials = Self.partials(progress.value)
        // Before the id arrives, "certain" could still rest on an invented id, so it shows as "likely".
        #expect(partials.map(\.confidence) == ["likely", "certain", "certain"])
        #expect(partials.map(\.matchedCandidateID) == [nil, "osm:node/7", "osm:node/7"])
        #expect(outcome.session.identified.confidence == .certain)
    }

    @Test func deltaThatChangesNothingIsNotReported() async throws {
        // `{"subj` and `ect":"Tow` complete no field, so the parsed state is unchanged (empty) and nothing is reported;
        // `er",` completes the subject and the last chunk the rest: 2 partials from 4 deltas.
        let chunks = [#"{"subj"#, #"ect":"Tow"#, #"er","#,
                      #""confidence":"likely","matchedCandidateID":null,"title":"T","era":"e","story":"S."}"#]
        let progress = LockedBox<[PhotoStoryProgress]>([])
        _ = try await Self.run(Self.flow(StreamingHTTP(lines: Self.sse(chunks))), nearby: Self.list(), progress: progress)
        let partials = Self.partials(progress.value)
        #expect(partials.count == 2)
        #expect(partials.first == PartialFirstStory(subject: "Tower"))
    }

    // MARK: - Article text

    @Test func articleCutTo1500() async throws {
        let long = String(repeating: "a", count: 4000)
        let http = StreamingHTTP(lines: Self.sse(Self.storyChunks))
        let articles = Articles("never used")
        let outcome = try await Self.run(Self.flow(http, articles: articles),
                                         nearby: Self.list(texts: ["en:Tower": long]))
        let text = try Self.inputText(http)
        // 4 000 characters cut to the first 1 500.
        let kept = String(repeating: "a", count: 1500)
        #expect(text.contains("Article about [osm:node/7] Tower:\n  " + kept + "\n"))
        #expect(!text.contains(kept + "a"))
        #expect(outcome.timings.articleChars == 1500)
        #expect(outcome.timings.articleMs != nil)
        // The list had the text: the source is not asked.
        #expect(articles.titles.value.isEmpty)
    }

    @Test func articleFromSourceWhenListLacksIt() async throws {
        let http = StreamingHTTP(lines: Self.sse(Self.storyChunks))
        let articles = Articles("Source\n\n  text.")
        let outcome = try await Self.run(Self.flow(http, articles: articles), nearby: Self.list())
        // Whitespace collapsed to one line: "Source text." = 6 + 1 + 5 = 12 characters.
        #expect(try Self.inputText(http).contains("Article about [osm:node/7] Tower:\n  Source text.\n"))
        #expect(outcome.timings.articleChars == 12)
        #expect(articles.titles.value == ["en:Tower"])
    }

    @Test func noArticleWithoutATitle() async throws {
        var untitled = Self.tower
        untitled.wikipediaTitle = nil
        let http = StreamingHTTP(lines: Self.sse(Self.storyChunks))
        let articles = Articles("unused")
        let outcome = try await Self.run(Self.flow(http, articles: articles), nearby: Self.list([untitled]))
        #expect(try !Self.inputText(http).contains("Article about"))
        #expect(outcome.timings.articleChars == 0 && outcome.timings.articleMs == nil)
        #expect(articles.titles.value.isEmpty)
    }

    @Test func articleBlockFollowsTheCandidatesAndIsOmittedWhenNil() throws {
        func prompt(_ article: (candidate: Candidate, text: String)?) -> String {
            PromptBuilder.photoFirstInput(capture: PromptBuilderTests.capture(heading: 135, acc: 10),
                                          grounding: PromptBuilderTests.grounding, recent: [], priors: [], language: .english,
                                          now: PromptBuilderTests.now, timeZone: PromptBuilderTests.utc, article: article)
        }
        let lines = prompt((candidate: PromptBuilderTests.gate.candidate, text: "A gate.")).components(separatedBy: "\n")
        // The one candidate takes three lines: its own, then "  Summary: …" and "  OSM: …"; the article comes next,
        // before the Apple Maps block.
        let candidate = try #require(lines.firstIndex { $0.hasPrefix("- [osm:way/1] Michaelertor") })
        try #require(lines.count > candidate + 5)
        #expect(lines[candidate + 1].hasPrefix("  Summary: ") && lines[candidate + 2].hasPrefix("  OSM: "))
        #expect(lines[candidate + 3] == "Article about [osm:way/1] Michaelertor:")
        #expect(lines[candidate + 4] == "  A gate.")
        #expect(lines[candidate + 5] == "Also on Apple Maps:")

        let without = prompt(nil)
        #expect(!without.contains("Article about"))
        // The default (no argument) is the same as nil.
        #expect(without == PromptBuilder.photoFirstInput(capture: PromptBuilderTests.capture(heading: 135, acc: 10),
                                                         grounding: PromptBuilderTests.grounding, recent: [], priors: [],
                                                         language: .english, now: PromptBuilderTests.now,
                                                         timeZone: PromptBuilderTests.utc))
    }

    // MARK: - Failure

    @Test func brokenStreamFailsWithoutSession() async throws {
        let http = StreamingHTTP(lines: Self.storyChunks.flatMap(OpenAIClientTests.delta),
                                 failure: OpenAIError.network("The network connection was lost."))
        let progress = LockedBox<[PhotoStoryProgress]>([])
        await #expect(throws: OpenAIError.network("The network connection was lost.")) {
            try await Self.run(Self.flow(http), nearby: Self.list(), progress: progress)
        }
        // The partial text was shown while it streamed, but nothing is returned: no session, no usage.
        #expect(!Self.partials(progress.value).isEmpty)
    }

    @Test func streamEndingWithoutCompletedFails() async throws {
        let http = StreamingHTTP(lines: Self.storyChunks.flatMap(OpenAIClientTests.delta))
        await #expect(throws: OpenAIError.malformedResponse) {
            try await Self.run(Self.flow(http), nearby: Self.list())
        }
    }

    @Test func emptyFinalStoryIsMalformedEvenAfterPartials() async throws {
        // The partials carried text; the final JSON is authoritative and its story is blank.
        let final = #"{"subject":"Tower","confidence":"likely","matchedCandidateID":null,"title":"T","era":"e","story":"  "}"#
        let http = StreamingHTTP(lines: Self.sse(Self.storyChunks, final: final))
        await #expect(throws: OpenAIError.malformedResponse) {
            try await Self.run(Self.flow(http), nearby: Self.list())
        }
    }

    @Test func finalJSONWinsOverThePartials() async throws {
        let final = #"{"subject":"Tower","confidence":"likely","matchedCandidateID":"osm:node/7","title":"T","era":"e","story":"The final text."}"#
        let http = StreamingHTTP(lines: Self.sse(Self.storyChunks, final: final))
        let outcome = try await Self.run(Self.flow(http), nearby: Self.list())
        #expect(outcome.session.levels == ["The final text."])
    }

    @Test func storyNotCompletedWithinTheDeadlineFails() async throws {
        // The stream sends its deltas and then stays open. Deadline 100 ms, so the flow must fail at ≈ 0.1 s;
        // the bound of 5 s only proves it did not wait for anything else.
        let http = StreamingHTTP(lines: Self.storyChunks.flatMap(OpenAIClientTests.delta), hang: true)
        let started = ContinuousClock.now
        do {
            _ = try await Self.run(Self.flow(http, storyDeadline: .milliseconds(100)), nearby: Self.list())
            Issue.record("expected a failure")
        } catch let error as OpenAIError {
            guard case .network = error else { Issue.record("wrong error \(error)"); return }
            #expect(UserFacingMessage.message(for: error) == "No connection. Check mobile data and try again.")
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func noPositionThrowsBeforeAnyReportOrRequest() async {
        var capture = Self.capture
        capture.coordinate = nil
        let http = StreamingHTTP(lines: Self.sse(Self.storyChunks))
        let progress = LockedBox<[PhotoStoryProgress]>([])
        await #expect(throws: PhotoStoryError.noPosition) {
            try await Self.run(Self.flow(http), nearby: Self.list(), capture: capture, progress: progress)
        }
        #expect(progress.value.isEmpty && http.requests.isEmpty)
    }

    // MARK: - "Try again with more places"

    @Test(arguments: [
        // Unsure, and the fresh search found Gate and Palace in view, which the list lacked → offered.
        ("unsure", [tower], true),
        // Unsure, but the list already had both of the fresh search's candidates → not offered.
        ("unsure", [Candidate(id: "osm:node/1", name: "Gate", coordinate: .at(north: 100), kind: "historic=yes"),
                    Candidate(id: "wiki:en/5", name: "Palace", coordinate: .at(north: 55), kind: "wikipedia")], false),
        // Likely: the fresh search is not waited for → not offered.
        ("likely", [tower], false),
    ])
    func unsureWithNewInViewCandidateOffersFresh(confidence: String, listed: [Candidate], offered: Bool) async throws {
        let json = #"{"subject":"Something","confidence":"\#(confidence)","matchedCandidateID":null,"title":"T","era":"e","story":"S."}"#
        let outcome = try await Self.run(Self.flow(StreamingHTTP(lines: Self.sse([json])), pointsOfInterest: Places()),
                                         nearby: Self.list(listed))
        let offer = await outcome.freshCandidates()
        #expect((offer != nil) == offered)
        if offered {
            let fresh = try #require(offer)
            #expect(Set(fresh.candidates.map(\.candidate.id)) == ["osm:node/1", "wiki:en/5"])
            #expect(fresh.address == Address(line: "Platz", city: "Wien", country: nil))
            #expect(fresh.applePlaces == [PhotoStoryFlowTests.museum])
        }
    }

    @Test func unsureFromAStaleListOffersNothing() async throws {
        // The fresh search was already used; there is nothing new to retry with.
        let json = #"{"subject":"Something","confidence":"unsure","matchedCandidateID":null,"title":"T","era":"e","story":"S."}"#
        let outcome = try await Self.run(Self.flow(StreamingHTTP(lines: Self.sse([json]))), nearby: Self.list(age: 601))
        #expect(await outcome.freshCandidates() == nil)
    }

    @Test func tryAgainUsesTheGivenGroundingWithoutSearching() async throws {
        let gate = RankedCandidate(candidate: Candidate(id: "osm:node/1", name: "Gate", coordinate: .at(north: 100),
                                                        kind: "historic=yes"),
                                   distance: 100, bearing: 0, inView: true)
        let given = Grounding(candidates: [gate], address: Address(line: "Gasse"), failedSources: [])
        let json = #"{"subject":"Gate","confidence":"certain","matchedCandidateID":"osm:node/1","title":"T","era":"e","story":"S."}"#
        let http = StreamingHTTP(lines: Self.sse([json]))
        let progress = LockedBox<[PhotoStoryProgress]>([])
        let outcome = try await Self.flow(http).tellFirstStoryStreaming(
            photoJPEG: Self.photo, capture: Self.capture, language: .english, grounding: given) { p in
                progress.withValue { $0.append(p) }
            }
        #expect(http.searchRequests.isEmpty)
        #expect(Array(progress.value.prefix(2)) == [.finding, .writing])
        let text = try Self.inputText(http)
        #expect(text.contains("[osm:node/1] Gate") && text.contains("Position: Gasse"))
        #expect(outcome.session.grounding == given)
        #expect(outcome.session.identified.confidence == .certain)
        #expect(!outcome.timings.listFresh && outcome.timings.listAgeS == nil && outcome.timings.placeSearchMs == nil)
        #expect(await outcome.freshCandidates() == nil)
    }

    // MARK: - Head start budget

    @Test func addressBudget1500ms() async throws {
        // Fresh path. The geocoder and Apple Maps each take 3 s; the request waits for them at most 1.5 s from the
        // start of the searches, then goes without them. So the call ends at ≈ 1.5 s (the stub stream is instant):
        // at least 1.4 s (allowing for clock granularity) and well under 3 s, the moment the geocoder would answer.
        let http = StreamingHTTP(lines: Self.sse(Self.storyChunks))
        let flow = Self.flow(http, geocoder: Geo(delay: .seconds(3)), pointsOfInterest: Places(delay: .seconds(3)))
        let started = ContinuousClock.now
        let outcome = try await Self.run(flow, nearby: Self.list())
        let took = ContinuousClock.now - started
        #expect(took >= .milliseconds(1400) && took < .milliseconds(2900))
        let text = try Self.inputText(http)
        #expect(text.contains("Position: address lookup failed"))
        #expect(!text.contains("Also on Apple Maps"))
        #expect(outcome.session.grounding.address == nil && outcome.session.grounding.applePlaces == nil)
        #expect(outcome.session.grounding.failedSources == [.geocoder])
    }

    @Test func applePlacesWithinTheBudgetAreSent() async throws {
        let http = StreamingHTTP(lines: Self.sse(Self.storyChunks))
        let outcome = try await Self.run(Self.flow(http, pointsOfInterest: Places()), nearby: Self.list())
        #expect(try Self.inputText(http).contains("Also on Apple Maps:\n- Museum"))
        #expect(outcome.session.grounding.applePlaces == [PhotoStoryFlowTests.museum])
        #expect(outcome.session.grounding.failedSources.isEmpty)
    }

    // MARK: - Continuation

    @Test func continuationStreamsText() async throws {
        let first = try await Self.run(Self.flow(StreamingHTTP(lines: Self.sse(Self.storyChunks))), nearby: Self.list())
        let http = StreamingHTTP(lines: Self.sse([#"{"story":"Level"#, #" two."}"#]))
        let texts = LockedBox<[String]>([])
        let (next, usage) = try await Self.flow(http).continueStoryStreaming(first.session) { text in
            texts.withValue { $0.append(text) }
        }
        #expect(texts.value == ["Level", "Level two."])
        #expect(next.levels == ["A tall tale.", "Level two."] && next.nextLevel == .evenMore)
        // Usage from the completed event: 120 input, 40 output tokens.
        #expect(usage.map(\.inputTokens) == [120] && usage.map(\.outputTokens) == [40] && usage.first?.kind == .story)
        let request = try #require(http.openAIRequest)
        let body = request.jsonBody
        #expect(body["stream"] as? Bool == true && body["store"] as? Bool == false)
        let content = try #require(((body["input"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        #expect(content.count == 1)   // text only, no image
        #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains(#""name":"continuation""#))
    }

    @Test func brokenContinuationFailsAndKeepsTheSession() async throws {
        let first = try await Self.run(Self.flow(StreamingHTTP(lines: Self.sse(Self.storyChunks))), nearby: Self.list())
        let http = StreamingHTTP(lines: OpenAIClientTests.delta(#"{"story":"Half"#), failure: OpenAIError.network("lost"))
        await #expect(throws: OpenAIError.network("lost")) {
            try await Self.flow(http).continueStoryStreaming(first.session) { _ in }
        }
        #expect(first.session.levels == ["A tall tale."])
    }

    @Test func continuationPastTheLastLevelThrowsBeforeAnyRequest() async throws {
        var session = try await Self.run(Self.flow(StreamingHTTP(lines: Self.sse(Self.storyChunks))), nearby: Self.list()).session
        session.levels = ["a", "b", "c"]
        let http = StreamingHTTP(lines: Self.sse([#"{"story":"x"}"#]))
        await #expect(throws: PhotoStoryError.noFurtherLevel) {
            try await Self.flow(http).continueStoryStreaming(session) { _ in }
        }
        #expect(http.requests.isEmpty)
    }

    // MARK: - Request shape

    @Test func firstStoryRequestStreamsWithStoreFalseAndTheSameSchema() async throws {
        let http = StreamingHTTP(lines: Self.sse(Self.storyChunks))
        _ = try await Self.run(Self.flow(http), nearby: Self.list())
        let request = try #require(http.openAIRequest)
        let body = request.jsonBody
        #expect(body["stream"] as? Bool == true && body["store"] as? Bool == false)
        #expect(body["prompt_cache_key"] as? String == PromptBuilder.promptCacheKey)
        #expect(body["instructions"] as? String == PromptBuilder.systemInstructions)
        let raw = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(raw.contains(#""name":"first_story""#))
        let content = try #require(((body["input"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        #expect(content.count == 2)   // text and photo
    }

    // MARK: - Fix round 1

    /// Polls `condition` every 10 ms until it holds or `timeout` passes; returns whether it held.
    @discardableResult
    static func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    static let unsureJSON = #"{"subject":"Something","confidence":"unsure","matchedCandidateID":null,"title":"T","era":"e","story":"S."}"#

    @Test func listCandidatesBeyond400mAreNotSent() async throws {
        // 399 m ≤ 400 m is sent; 401 m > 400 m is not. Far is Wikipedia-backed and in view, so without the cap it
        // would rank first (backed before unbacked) and bring its article.
        let near = Candidate(id: "osm:node/20", name: "Near", coordinate: .at(north: 399), kind: "historic=yes")
        let far = Candidate(id: "osm:node/21", name: "Far", coordinate: .at(north: 401), kind: "historic=yes",
                            summary: "Far away.", wikipediaTitle: "en:Far")
        let http = StreamingHTTP(lines: Self.sse([Self.unsureJSON]))
        let outcome = try await Self.run(Self.flow(http), nearby: Self.list([near, far], texts: ["en:Far": "Far text."]))
        let text = try Self.inputText(http)
        #expect(text.contains("[osm:node/20] Near"))
        #expect(!text.contains("osm:node/21") && !text.contains("Far"))
        #expect(outcome.session.grounding.candidates.map(\.candidate.id) == ["osm:node/20"])
        #expect(PhotoStoryFlow.listCandidateRadius == 400)
    }

    @Test func slowArticleSharesTheHeadStartBudget() async throws {
        // Fresh path, the list lacks the text, the source takes 3 s and ignores cancellation. The article step ends
        // with the 1.5 s budget, so the call ends at ≈ 1.5 s: at least 1.4 s and well under the source's 3 s.
        let http = StreamingHTTP(lines: Self.sse(Self.storyChunks))
        let articles = Articles("Late.", delay: .seconds(3))
        let started = ContinuousClock.now
        let outcome = try await Self.run(Self.flow(http, articles: articles), nearby: Self.list())
        let took = ContinuousClock.now - started
        #expect(took >= .milliseconds(1400) && took < .milliseconds(2900))
        #expect(try !Self.inputText(http).contains("Article about"))
        #expect(outcome.timings.articleChars == 0)
        #expect(articles.titles.value == ["en:Tower"])
    }

    @Test(arguments: [
        // Facing north, the only candidate is 50 m south: out of view → no article, the source is not asked.
        (0.0 as Double?, false),
        // No usable heading: nothing has a view flag, the top candidate counts → article sent.
        (nil as Double?, true),
    ])
    func articleOnlyForATopCandidateInViewOrWithoutHeading(heading: Double?, expectArticle: Bool) async throws {
        var shed = Self.shed
        shed.wikipediaTitle = "en:Shed"
        let json = #"{"subject":"Shed","confidence":"likely","matchedCandidateID":null,"title":"T","era":"e","story":"S."}"#
        let http = StreamingHTTP(lines: Self.sse([json]))
        let articles = Articles("Shed text.")
        let capture = GroundingTests.capture(heading: heading, acc: heading == nil ? nil : 10)
        let outcome = try await Self.run(Self.flow(http, articles: articles), nearby: Self.list([shed]), capture: capture)
        #expect(try Self.inputText(http).contains("Article about [osm:node/8] Shed:\n  Shed text.") == expectArticle)
        // "Shed text." = 4 + 1 + 5 = 10 characters.
        #expect(outcome.timings.articleChars == (expectArticle ? 10 : 0))
        #expect(articles.titles.value == (expectArticle ? ["en:Shed"] : []))
    }

    @Test func futureDatedListHasNoAge() async throws {
        // fetchedAt = t0 + 10 s, after the clock's now: never fresh, and its age is unknown.
        let outcome = try await Self.run(Self.flow(StreamingHTTP(lines: Self.sse(Self.storyChunks))), nearby: Self.list(age: -10))
        #expect(!outcome.timings.listFresh && outcome.timings.listAgeS == nil)
    }

    @Test func unsureReturnsBeforeTheFreshSearchEnds() async throws {
        // Overpass answers after 2 s. The fresh-list story does not wait for it: everything else answers at once, so
        // the outcome comes well under 1 s. Asking for the fresh candidates waits for the search: about 2 s from the
        // start (at least 1.9 s), and then Gate (Overpass) and Palace (Wikipedia) are there.
        let http = StreamingHTTP(lines: Self.sse([Self.unsureJSON]), overpassDelay: .seconds(2))
        let started = ContinuousClock.now
        let outcome = try await Self.run(Self.flow(http, pointsOfInterest: Places()), nearby: Self.list([Self.tower]))
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(outcome.timings.placeSearchMs == nil)
        let fresh = await outcome.freshCandidates()
        #expect(ContinuousClock.now - started >= .milliseconds(1900))
        #expect(Set(fresh?.candidates.map(\.candidate.id) ?? []) == ["osm:node/1", "wiki:en/5"])
        #expect(fresh?.applePlaces == [PhotoStoryFlowTests.museum])
    }

    @Test func cancellingTheFreshCandidatesCallerCancelsTheSearch() async throws {
        let http = StreamingHTTP(lines: Self.sse([Self.unsureJSON]), overpassDelay: .seconds(30))
        let outcome = try await Self.run(Self.flow(http), nearby: Self.list([Self.tower]))
        let started = ContinuousClock.now
        let asking = Task { await outcome.freshCandidates() }
        try await Task.sleep(for: .milliseconds(100))
        asking.cancel()
        #expect(await asking.value == nil)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(await Self.waitUntil { http.overpassCancelled.value })
    }

    @Test func cancellingTheFlowCancelsTheSearchesAndStopsProgress() async throws {
        // Fresh path: after the 1.5 s budget the story streams and the stream stays open. The geocoder, Apple Maps and
        // Overpass would take 60 s. Cancel once the stream is open.
        let geoCancelled = LockedBox(false), placesCancelled = LockedBox(false)
        let http = StreamingHTTP(lines: OpenAIClientTests.delta(#"{"subject":"Tow"#), hang: true, overpassDelay: .seconds(60))
        let flow = Self.flow(http, geocoder: Geo(delay: .seconds(60), cancelled: geoCancelled),
                             pointsOfInterest: Places(delay: .seconds(60), cancelled: placesCancelled))
        let progress = LockedBox<[PhotoStoryProgress]>([])
        let running = Task { try await Self.run(flow, nearby: Self.list(), progress: progress) }
        #expect(await Self.waitUntil { http.openAIRequest != nil })
        running.cancel()
        let reportedAtCancel = progress.value.count
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(await Self.waitUntil { geoCancelled.value && placesCancelled.value && http.overpassCancelled.value })
        try await Task.sleep(for: .milliseconds(200))
        #expect(progress.value.count == reportedAtCancel)
    }

    @Test func noWritingAfterCancellationDuringTheMemoryLookups() async throws {
        let inPriors = LockedBox(false)
        let http = StreamingHTTP(lines: Self.sse(Self.storyChunks))
        let flow = Self.flow(http) { _, _, _ in
            inPriors.set(true)
            try? await Task.sleep(for: .seconds(10))   // ends early when the flow is cancelled
            return []
        }
        let progress = LockedBox<[PhotoStoryProgress]>([])
        let running = Task { try await Self.run(flow, nearby: nil, progress: progress) }
        #expect(await Self.waitUntil { inPriors.value })
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(!progress.value.contains(.writing))
        #expect(http.openAIRequest == nil)
    }
}
