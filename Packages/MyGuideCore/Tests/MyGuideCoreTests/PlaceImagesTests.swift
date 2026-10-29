import Testing
import Foundation
@testable import MyGuideCore

@Suite struct PlaceImagesTests {
    static let thumb = "https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/Pantheon_front.jpg/600px-Pantheon_front.jpg"
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0xFF, 0xD9])
    static let artistHTML = #"<a href=\"//commons.wikimedia.org/wiki/User:Jane\" title=\"User:Jane\">Jane Doe</a>"#

    static func pageImagesBody(source: String = thumb, name: String = "Pantheon_front.jpg") -> Data {
        Data((#"{"batchcomplete":true,"query":{"pages":[{"pageid":1,"ns":0,"title":"Pantheon","#
            + #""thumbnail":{"source":"\#(source)","width":600,"height":450},"pageimage":"\#(name)"}]}}"#).utf8)
    }
    static let noImageBody = Data(#"{"batchcomplete":true,"query":{"pages":[{"pageid":1,"ns":0,"title":"Pantheon"}]}}"#.utf8)
    static let missingPageBody = Data(#"{"batchcomplete":true,"query":{"pages":[{"ns":0,"title":"Nope","missing":true}]}}"#.utf8)

    static func imageInfoBody(repository: String = "shared", artist: String? = artistHTML,
                              licence: String? = "CC BY-SA 4.0") -> Data {
        var fields: [String] = []
        if let artist { fields.append(#""Artist":{"value":"\#(artist)","source":"commons-desc-page"}"#) }
        if let licence { fields.append(#""LicenseShortName":{"value":"\#(licence)","source":"commons-desc-page"}"#) }
        // A shared (Commons) file is "missing" but "known" on the article's wiki; that is not an error.
        return Data((#"{"batchcomplete":true,"query":{"pages":[{"ns":6,"title":"File:Pantheon front.jpg","missing":true,"#
            + #""known":true,"imagerepository":"\#(repository)","imageinfo":[{"extmetadata":{\#(fields.joined(separator: ","))}}]}]}}"#).utf8)
    }

    static func query(_ request: URLRequest) -> String { request.url?.query ?? "" }
    static func isPageImages(_ request: URLRequest) -> Bool { query(request).contains("prop=pageimages") }
    static func isImageInfo(_ request: URLRequest) -> Bool { query(request).contains("prop=imageinfo") }

    /// Answers the three requests of one successful fetch.
    static func route(_ request: URLRequest) -> (Int, Data) {
        if isPageImages(request) { return (200, pageImagesBody()) }
        if isImageInfo(request) { return (200, imageInfoBody()) }
        return (200, jpeg)
    }

    static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PlaceImagesTests-\(UUID().uuidString)", isDirectory: true)
    }

    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let day: TimeInterval = 86_400

    static let minute: TimeInterval = 60

    // MARK: WikipediaClient.pageImage

    @Test func requestURLsAreOnTheArticlesWiki() async throws {
        let http = StubHTTPClient { r in
            if Self.isPageImages(r) { return (200, Self.pageImagesBody(name: "Pantheon_(Rome)_-_Front.jpg")) }
            return (200, Self.imageInfoBody())
        }
        let client = WikipediaClient(http: http)
        _ = try await client.pageImage(wikipediaTitle: "it:Pantheon (Roma)")
        _ = try await client.imageData(URL(string: Self.thumb)!)
        #expect(http.requests.count == 3)
        #expect(http.requests[0].url!.absoluteString ==
            "https://it.wikipedia.org/w/api.php?action=query&format=json&formatversion=2&prop=pageimages"
          + "&piprop=thumbnail%7Cname&pithumbsize=600&redirects=1&titles=Pantheon%20%28Roma%29")
        // Only unreserved characters stay literal: ":" in "File:" and the parentheses are encoded.
        #expect(http.requests[1].url!.absoluteString ==
            "https://it.wikipedia.org/w/api.php?action=query&format=json&formatversion=2&prop=imageinfo"
          + "&iiprop=extmetadata&iiextmetadatafilter=Artist%7CLicenseShortName"
          + "&titles=File%3APantheon_%28Rome%29_-_Front.jpg")
        #expect(http.requests[2].url!.absoluteString == Self.thumb)
        for request in http.requests {
            #expect(request.value(forHTTPHeaderField: "User-Agent") == OverpassClient.userAgent)
            #expect(request.timeoutInterval == 10)
        }
    }

    @Test func titleWithAmpersandAndNonASCIICannotLeakIntoTheQuery() async throws {
        let http = StubHTTPClient { _ in (200, Self.noImageBody) }
        _ = try await WikipediaClient(http: http).pageImage(wikipediaTitle: "no:Ålesund & Co=1#x")
        #expect(http.requests[0].url!.absoluteString.hasSuffix("&titles=%C3%85lesund%20%26%20Co%3D1%23x"))
        #expect(http.requests[0].url!.host == "no.wikipedia.org")
    }

    @Test func parsesThumbnailAndCredit() async throws {
        let http = StubHTTPClient { Self.route($0) }
        let info = try await WikipediaClient(http: http).pageImage(wikipediaTitle: "en:Pantheon")
        #expect(info == PlaceImageInfo(
            thumbnailURL: URL(string: Self.thumb)!,
            author: "Jane Doe",
            licence: "CC BY-SA 4.0",
            filePage: URL(string: "https://commons.wikimedia.org/wiki/File:Pantheon_front.jpg")!))
    }

    @Test func localFileHasItsPageOnTheArticlesWiki() async throws {
        let http = StubHTTPClient { r in
            Self.isPageImages(r) ? (200, Self.pageImagesBody(name: "Ålesund kirke.jpg")) : (200, Self.imageInfoBody(repository: "local"))
        }
        let info = try await WikipediaClient(http: http).pageImage(wikipediaTitle: "no:Ålesund kirke")
        // Spaces become underscores; "Å" is percent-encoded in the path.
        #expect(info?.filePage == URL(string: "https://no.wikipedia.org/wiki/File:%C3%85lesund_kirke.jpg")!)
    }

    @Test func unknownRepositoryGivesNoFilePage() async throws {
        let http = StubHTTPClient { r in
            Self.isPageImages(r) ? (200, Self.pageImagesBody()) : (200, Self.imageInfoBody(repository: ""))
        }
        let info = try await WikipediaClient(http: http).pageImage(wikipediaTitle: "en:Pantheon")
        #expect(info?.filePage == nil)
        #expect(info?.author == "Jane Doe")
    }

    @Test func oneCreditFieldIsEnough() async throws {
        let licenceOnly = StubHTTPClient { r in
            Self.isPageImages(r) ? (200, Self.pageImagesBody()) : (200, Self.imageInfoBody(artist: nil))
        }
        let a = try await WikipediaClient(http: licenceOnly).pageImage(wikipediaTitle: "en:Pantheon")
        #expect(a?.thumbnailURL == URL(string: Self.thumb)!)
        #expect(a?.author == nil && a?.licence == "CC BY-SA 4.0")
        let authorOnly = StubHTTPClient { r in
            Self.isPageImages(r) ? (200, Self.pageImagesBody()) : (200, Self.imageInfoBody(licence: "  "))
        }
        let b = try await WikipediaClient(http: authorOnly).pageImage(wikipediaTitle: "en:Pantheon")
        #expect(b?.author == "Jane Doe" && b?.licence == nil)
    }

    /// A picture is never offered without credit: a reply naming neither author nor licence is malformed.
    @Test func noCreditAtAllIsMalformed() async {
        let bodies = [
            Self.imageInfoBody(artist: nil, licence: nil),
            Self.imageInfoBody(artist: "<span> </span>", licence: "  "),
            Data(#"{"batchcomplete":true}"#.utf8),
            Data(#"{"batchcomplete":true,"query":{"pages":[]}}"#.utf8),
            Data(#"{"query":{"pages":[{"ns":6,"title":"File:P.jpg","imagerepository":"shared"}]}}"#.utf8),
            Data(#"{"query":{"pages":[{"ns":6,"title":"File:P.jpg","imageinfo":[{}]}]}}"#.utf8),
            // Values that are not strings count as absent.
            Data(#"{"query":{"pages":[{"imageinfo":[{"extmetadata":{"Artist":{"value":7},"LicenseShortName":{"value":null}}}]}]}}"#.utf8),
        ]
        for body in bodies {
            let http = StubHTTPClient { r in Self.isPageImages(r) ? (200, Self.pageImagesBody()) : (200, body) }
            await #expect(throws: GroundingFetchError.malformed) {
                _ = try await WikipediaClient(http: http).pageImage(wikipediaTitle: "en:Pantheon")
            }
        }
    }

    @Test func artistHTMLIsReducedToPlainText() {
        #expect(WikipediaClient.plainText(fromHTML: #"<a href="//x">Jane Doe</a>"#) == "Jane Doe")
        #expect(WikipediaClient.plainText(fromHTML: #"<bdi><a href="//x"><span class="fn">Jane</span></a></bdi> &amp; Bob"#) == "Jane & Bob")
        // 233 = 0xE9 = é and 0xE8 = è; a signed number is no reference.
        #expect(WikipediaClient.plainText(fromHTML: "Jos&#233; &#xE9;l&#XE8;ve &#+65;") == "José élève &#+65;")
        #expect(WikipediaClient.plainText(fromHTML: "A&nbsp;B &lt;C&gt; &quot;D&quot; &#39;E&apos;") == "A B <C> \"D\" 'E'")
        // A line break separates words; runs of whitespace collapse.
        #expect(WikipediaClient.plainText(fromHTML: "Jane<br/>Doe\n\n  (photo)") == "Jane Doe (photo)")
        // Decoding comes after stripping: an escaped tag stays text. Unknown entities stay as written.
        #expect(WikipediaClient.plainText(fromHTML: "&lt;b&gt;x&lt;/b&gt; &bogus; &#xZZ; & y") == "<b>x</b> &bogus; &#xZZ; & y")
        #expect(WikipediaClient.plainText(fromHTML: "<p></p>") == nil)
        #expect(WikipediaClient.plainText(fromHTML: "") == nil)
    }

    @Test func noPageImageGivesNil() async throws {
        let http = StubHTTPClient { _ in (200, Self.noImageBody) }
        #expect(try await WikipediaClient(http: http).pageImage(wikipediaTitle: "en:Pantheon") == nil)
        // No image: no imageinfo request.
        #expect(http.requests.count == 1)
    }

    @Test func missingArticleOrNoPagesGivesNil() async throws {
        for body in [Self.missingPageBody, Data(#"{"batchcomplete":true}"#.utf8)] {
            let http = StubHTTPClient { _ in (200, body) }
            #expect(try await WikipediaClient(http: http).pageImage(wikipediaTitle: "en:Nope") == nil)
            #expect(http.requests.count == 1)
        }
    }

    @Test func thumbnailWithoutFileNameGivesNil() async throws {
        let body = Data(#"{"query":{"pages":[{"pageid":1,"title":"P","thumbnail":{"source":"\#(Self.thumb)"}}]}}"#.utf8)
        let http = StubHTTPClient { _ in (200, body) }
        #expect(try await WikipediaClient(http: http).pageImage(wikipediaTitle: "en:P") == nil)
    }

    @Test func nonHTTPSThumbnailIsMalformed() async {
        let http = StubHTTPClient { _ in (200, Self.pageImagesBody(source: "http://upload.wikimedia.org/x.jpg")) }
        await #expect(throws: GroundingFetchError.malformed) {
            _ = try await WikipediaClient(http: http).pageImage(wikipediaTitle: "en:Pantheon")
        }
    }

    @Test func pageImagesErrorsThrow() async {
        let cases: [(Int, Data, GroundingFetchError)] = [
            (500, Data(), .http(500)),
            (200, Data(#"{"error":{"code":"badtitle"}}"#.utf8), .apiError("badtitle")),
            (200, Data("not json".utf8), .malformed),
        ]
        for (status, body, expected) in cases {
            let http = StubHTTPClient { _ in (status, body) }
            await #expect(throws: expected) {
                _ = try await WikipediaClient(http: http).pageImage(wikipediaTitle: "en:Pantheon")
            }
        }
    }

    @Test func imageInfoErrorsThrow() async {
        let cases: [(Int, Data, GroundingFetchError)] = [
            (503, Data(), .http(503)),
            (200, Data(#"{"error":{"code":"maxlag"}}"#.utf8), .apiError("maxlag")),
            (200, Data("[]".utf8), .malformed),
        ]
        for (status, body, expected) in cases {
            let http = StubHTTPClient { r in Self.isPageImages(r) ? (200, Self.pageImagesBody()) : (status, body) }
            await #expect(throws: expected) {
                _ = try await WikipediaClient(http: http).pageImage(wikipediaTitle: "en:Pantheon")
            }
        }
    }

    @Test func malformedTitleThrowsWithoutRequest() async {
        let http = StubHTTPClient { Self.route($0) }
        for title in ["Pantheon", ":Pantheon", "en:", "e n:Pantheon", "evil.com/x:Pantheon", "en1:Pantheon"] {
            await #expect(throws: GroundingFetchError.malformed) {
                _ = try await WikipediaClient(http: http).pageImage(wikipediaTitle: title)
            }
        }
        #expect(http.requests.isEmpty)
    }

    @Test func imageDataChecksStatus() async throws {
        let ok = StubHTTPClient { _ in (200, Self.jpeg) }
        #expect(try await WikipediaClient(http: ok).imageData(URL(string: Self.thumb)!) == Self.jpeg)
        let missing = StubHTTPClient { _ in (404, Data()) }
        await #expect(throws: GroundingFetchError.http(404)) {
            _ = try await WikipediaClient(http: missing).imageData(URL(string: Self.thumb)!)
        }
        let empty = StubHTTPClient { _ in (200, Data()) }
        await #expect(throws: GroundingFetchError.malformed) {
            _ = try await WikipediaClient(http: empty).imageData(URL(string: Self.thumb)!)
        }
    }

    // MARK: PlaceImages

    @Test func storesUnderTheTitlesHashAndHitsAvoidNetwork() async throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient { Self.route($0) }
        let images = PlaceImages(directory: dir, client: WikipediaClient(http: http))

        #expect(await images.cached(wikipediaTitle: "en:Pantheon") == nil)
        let stored = try #require(await images.image(wikipediaTitle: "en:Pantheon"))
        // pageimages + imageinfo + the thumbnail = 3 requests.
        #expect(http.requests.count == 3)
        // `printf '%s' 'en:Pantheon' | shasum -a 256`
        #expect(stored.fileURL.lastPathComponent == "3abb0bccf2acc93ee644300656d8cb9703a1ffc6b4629acf88cd1b2511e2bf02.jpg")
        #expect(stored.fileURL.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(try Data(contentsOf: stored.fileURL) == Self.jpeg)
        let json = stored.fileURL.deletingPathExtension().appendingPathExtension("json")
        #expect(FileManager.default.fileExists(atPath: json.path))
        #expect(stored.info.author == "Jane Doe" && stored.info.licence == "CC BY-SA 4.0")
    }

    @Test func cacheHitAvoidsNetwork() async throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient { Self.route($0) }
        let images = PlaceImages(directory: dir, client: WikipediaClient(http: http))
        let first = await images.image(wikipediaTitle: "en:Pantheon")
        let second = await images.image(wikipediaTitle: "en:Pantheon")
        #expect(first != nil && second == first)
        #expect(await images.cached(wikipediaTitle: "en:Pantheon") == first)
        // Still the 3 requests of the first fetch.
        #expect(http.requests.count == 3)

        // The cache is on disk: a new instance on the same directory needs no network either.
        let offline = StubHTTPClient { _ in (500, Data()) }
        let restarted = PlaceImages(directory: dir, client: WikipediaClient(http: offline))
        #expect(await restarted.cached(wikipediaTitle: "en:Pantheon") == first)
        #expect(await restarted.image(wikipediaTitle: "en:Pantheon") == first)
        #expect(offline.requests.isEmpty)
    }

    @Test func negativeAnswerRememberedSevenDays() async throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = LockedBox(Self.t0)
        let http = StubHTTPClient { _ in (200, Self.noImageBody) }
        let images = PlaceImages(directory: dir, client: WikipediaClient(http: http), now: { clock.value })

        #expect(await images.image(wikipediaTitle: "en:Pantheon") == nil)
        #expect(http.requests.count == 1)
        // 6.9 days = 6.9 × 86 400 s = 596 160 s < 604 800 s (7 days): remembered, no request.
        clock.set(Self.t0.addingTimeInterval(6.9 * Self.day))
        #expect(await images.image(wikipediaTitle: "en:Pantheon") == nil)
        #expect(http.requests.count == 1)
        // Remembered on disk too: a new instance at 6.9 days makes no request.
        let restarted = PlaceImages(directory: dir, client: WikipediaClient(http: http), now: { clock.value })
        #expect(await restarted.image(wikipediaTitle: "en:Pantheon") == nil)
        #expect(http.requests.count == 1)
        // 7.1 days = 613 440 s ≥ 604 800 s: expired, one new request (1 + 1 = 2).
        clock.set(Self.t0.addingTimeInterval(7.1 * Self.day))
        #expect(await images.image(wikipediaTitle: "en:Pantheon") == nil)
        #expect(http.requests.count == 2)
        // That answer was stored at 7.1 days; at 7.1 + 6.9 = 14.0 days it is 6.9 days old: still remembered.
        clock.set(Self.t0.addingTimeInterval(14.0 * Self.day))
        #expect(await images.image(wikipediaTitle: "en:Pantheon") == nil)
        #expect(http.requests.count == 2)
    }

    @Test func negativeAnswerExpiresAtExactlySevenDays() async {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = LockedBox(Self.t0)
        let http = StubHTTPClient { _ in (200, Self.noImageBody) }
        let images = PlaceImages(directory: dir, client: WikipediaClient(http: http), now: { clock.value })
        _ = await images.image(wikipediaTitle: "en:Pantheon")
        // 7 × 86 400 = 604 800 s: the boundary itself is no longer within the 7 days, so a request (1 + 1 = 2).
        clock.set(Self.t0.addingTimeInterval(604_800))
        _ = await images.image(wikipediaTitle: "en:Pantheon")
        #expect(http.requests.count == 2)
    }

    @Test func negativeAnswerFromTheFutureIsNotTrusted() async {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = LockedBox(Self.t0)
        let http = StubHTTPClient { _ in (200, Self.noImageBody) }
        let images = PlaceImages(directory: dir, client: WikipediaClient(http: http), now: { clock.value })
        _ = await images.image(wikipediaTitle: "en:Pantheon")
        // The device clock moved back a day: the stored time is ahead of now, so the answer is fetched again.
        clock.set(Self.t0.addingTimeInterval(-Self.day))
        _ = await images.image(wikipediaTitle: "en:Pantheon")
        #expect(http.requests.count == 2)
    }

    @Test func failureIsNotRemembered() async {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = LockedBox(Self.t0)
        let failing = LockedBox<String?>("pageimages")
        let http = StubHTTPClient { r in
            switch failing.value {
            case "pageimages" where Self.isPageImages(r): return (500, Data())
            case "imageinfo" where Self.isImageInfo(r): return (503, Data())
            case "thumbnail" where r.url!.host == "upload.wikimedia.org": return (404, Data())
            default: return Self.route(r)
            }
        }
        let images = PlaceImages(directory: dir, client: WikipediaClient(http: http), now: { clock.value })
        for step in ["pageimages", "imageinfo", "thumbnail"] {
            failing.set(step)
            #expect(await images.image(wikipediaTitle: "en:Pantheon") == nil)
            #expect(await images.cached(wikipediaTitle: "en:Pantheon") == nil)
            // Past the 5-minute cooldown (5 × 60 = 300 s < 301 s) before the next attempt.
            clock.set(clock.value.addingTimeInterval(301))
        }
        // Requests so far: 1 (pageimages fails) + 2 (imageinfo fails) + 3 (thumbnail fails) = 6.
        #expect(http.requests.count == 6)
        failing.set(nil)
        #expect(await images.image(wikipediaTitle: "en:Pantheon") != nil)
        // 6 + 3 = 9: each failure was retried, none was remembered as "no image".
        #expect(http.requests.count == 9)
    }

    @Test func thrownTransportErrorGivesNil() async {
        struct Offline: Error {}
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient { _ in throw Offline() }
        let images = PlaceImages(directory: dir, client: WikipediaClient(http: http))
        #expect(await images.image(wikipediaTitle: "en:Pantheon") == nil)
    }

    @Test func failureCooldownIsFiveMinutes() async throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = LockedBox(Self.t0)
        let failing = LockedBox(true)
        let http = StubHTTPClient { r in failing.value ? (500, Data()) : Self.route(r) }
        let images = PlaceImages(directory: dir, client: WikipediaClient(http: http), now: { clock.value })

        #expect(await images.image(wikipediaTitle: "en:Pantheon") == nil)
        #expect(http.requests.count == 1)
        failing.set(false)
        // 4:59 = 4 × 60 + 59 = 299 s < 300 s: every entry point answers nil without a request.
        clock.set(Self.t0.addingTimeInterval(299))
        #expect(await images.image(wikipediaTitle: "en:Pantheon") == nil)
        #expect(await images.image(wikipediaTitle: "en:Pantheon", within: .seconds(30)) == nil)
        await images.prefetch(["en:Pantheon"])
        #expect(http.requests.count == 1)
        // The cooldown is per title: another title is fetched (1 + 3 = 4).
        #expect(await images.image(wikipediaTitle: "it:Pantheon") != nil)
        #expect(http.requests.count == 4)
        // 5:01 = 301 s ≥ 300 s: tried again, and succeeds (4 + 3 = 7).
        clock.set(Self.t0.addingTimeInterval(301))
        #expect(await images.image(wikipediaTitle: "en:Pantheon") != nil)
        #expect(http.requests.count == 7)
    }

    @Test func failureCooldownEndsAtExactlyFiveMinutes() async {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = LockedBox(Self.t0)
        let http = StubHTTPClient { _ in (500, Data()) }
        let images = PlaceImages(directory: dir, client: WikipediaClient(http: http), now: { clock.value })
        _ = await images.image(wikipediaTitle: "en:Pantheon")
        // 5 × 60 = 300 s: the boundary itself is past the cooldown, so a request (1 + 1 = 2).
        clock.set(Self.t0.addingTimeInterval(5 * Self.minute))
        _ = await images.image(wikipediaTitle: "en:Pantheon")
        #expect(http.requests.count == 2)
        // The clock moved back a minute behind that failure: the cooldown is not trusted, so a request (2 + 1 = 3).
        clock.set(Self.t0.addingTimeInterval(4 * Self.minute))
        _ = await images.image(wikipediaTitle: "en:Pantheon")
        #expect(http.requests.count == 3)
    }

    @Test func nonHTTPSThumbnailIsAFailureUnderTheCooldown() async {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = LockedBox(Self.t0)
        let http = StubHTTPClient { _ in (200, Self.pageImagesBody(source: "http://upload.wikimedia.org/x.jpg")) }
        let images = PlaceImages(directory: dir, client: WikipediaClient(http: http), now: { clock.value })
        #expect(await images.image(wikipediaTitle: "en:Pantheon") == nil)
        #expect(http.requests.count == 1)
        // Not remembered on disk as "no image": nothing was written.
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty)
        // 299 s < 300 s: no request.
        clock.set(Self.t0.addingTimeInterval(299))
        #expect(await images.image(wikipediaTitle: "en:Pantheon") == nil)
        #expect(http.requests.count == 1)
        // 301 s ≥ 300 s: one request (1 + 1 = 2).
        clock.set(Self.t0.addingTimeInterval(301))
        #expect(await images.image(wikipediaTitle: "en:Pantheon") == nil)
        #expect(http.requests.count == 2)
    }

    @Test func uncreditedPictureIsAFailedFetch() async throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = LockedBox(Self.t0)
        let credited = LockedBox(false)
        let http = StubHTTPClient { r in
            if Self.isImageInfo(r) && !credited.value { return (200, Data(#"{"batchcomplete":true}"#.utf8)) }
            return Self.route(r)
        }
        let images = PlaceImages(directory: dir, client: WikipediaClient(http: http), now: { clock.value })
        #expect(await images.image(wikipediaTitle: "en:Pantheon") == nil)
        #expect(await images.cached(wikipediaTitle: "en:Pantheon") == nil)
        // pageimages + imageinfo = 2; the thumbnail is never downloaded and nothing is written.
        #expect(http.requests.count == 2)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty)
        // Not remembered as "no image" for 7 days: after the 5-minute cooldown (301 s) it is fetched again (2 + 3 = 5).
        credited.set(true)
        clock.set(Self.t0.addingTimeInterval(301))
        #expect(await images.image(wikipediaTitle: "en:Pantheon")?.info.author == "Jane Doe")
        #expect(http.requests.count == 5)
    }

    @Test func corruptRecordIsAMiss() async throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient { Self.route($0) }
        let images = PlaceImages(directory: dir, client: WikipediaClient(http: http))
        let stored = try #require(await images.image(wikipediaTitle: "en:Pantheon"))
        try Data("{".utf8).write(to: stored.fileURL.deletingPathExtension().appendingPathExtension("json"))
        #expect(await images.cached(wikipediaTitle: "en:Pantheon") == nil)
        #expect(await images.image(wikipediaTitle: "en:Pantheon") == stored)
        // 3 + 3: the corrupt record was fetched again.
        #expect(http.requests.count == 6)
    }

    @Test func missingPictureFileIsAMiss() async throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient { Self.route($0) }
        let images = PlaceImages(directory: dir, client: WikipediaClient(http: http))
        let stored = try #require(await images.image(wikipediaTitle: "en:Pantheon"))
        try FileManager.default.removeItem(at: stored.fileURL)
        #expect(await images.cached(wikipediaTitle: "en:Pantheon") == nil)
        #expect(await images.image(wikipediaTitle: "en:Pantheon") == stored)
        #expect(http.requests.count == 6)
    }

    @Test(.timeLimit(.minutes(1))) func inFlightMerged() async throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = GatedHTTP { Self.route($0) }
        let images = PlaceImages(directory: dir, client: WikipediaClient(http: http))

        let first = Task { await images.image(wikipediaTitle: "en:Pantheon") }
        await http.waitForArrivals(1)
        let second = Task { await images.image(wikipediaTitle: "en:Pantheon") }
        // The second caller has joined the fetch that is still held at the gate.
        await images.waitForJoinedFetches(1)
        await http.gate.open()
        let a = await first.value
        let b = await second.value
        #expect(a != nil && a == b)
        // One fetch: pageimages + imageinfo + thumbnail = 3 requests, not 6.
        #expect(http.arrived == 3)
    }

    @Test func differentTitlesAreNotMerged() async {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient { Self.route($0) }
        let images = PlaceImages(directory: dir, client: WikipediaClient(http: http))
        async let a = images.image(wikipediaTitle: "en:Pantheon")
        async let b = images.image(wikipediaTitle: "it:Pantheon")
        let (x, y) = await (a, b)
        #expect(x != nil && y != nil && x?.fileURL != y?.fileURL)
        // 2 titles × 3 requests = 6.
        #expect(http.requests.count == 6)
    }

    @Test(.timeLimit(.minutes(1))) func fetchWithinCapGivesUpAfterCap() async throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Held at the gate: a request that answers long after any cap (the brief's 3 s delay, without real waiting).
        let http = GatedHTTP { Self.route($0) }
        let images = PlaceImages(directory: dir, client: WikipediaClient(http: http))

        let capped = await images.image(wikipediaTitle: "en:Pantheon", within: .milliseconds(20))
        #expect(capped == nil)
        #expect(await images.cached(wikipediaTitle: "en:Pantheon") == nil)
        await http.waitForArrivals(1)
        #expect(http.arrived == 1)

        // The fetch continues after the cap and fills the cache.
        await http.gate.open()
        let joined = await images.image(wikipediaTitle: "en:Pantheon")
        #expect(joined != nil)
        #expect(await images.cached(wikipediaTitle: "en:Pantheon") == joined)
        // The capped call's fetch was joined, not repeated: still 3 requests.
        #expect(http.arrived == 3)
    }

    @Test(.timeLimit(.minutes(1))) func cancelledCallerStopsWaitingAndTheFetchFillsTheCache() async throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = GatedHTTP { Self.route($0) }
        let images = PlaceImages(directory: dir, client: WikipediaClient(http: http))

        let caller = Task { await images.image(wikipediaTitle: "en:Pantheon") }
        await http.waitForArrivals(1)
        caller.cancel()
        // Returns while the gate is still closed: the caller abandoned the wait.
        #expect(await caller.value == nil)
        #expect(await images.cached(wikipediaTitle: "en:Pantheon") == nil)

        await http.gate.open()
        let joined = await images.image(wikipediaTitle: "en:Pantheon")
        #expect(joined != nil)
        #expect(await images.cached(wikipediaTitle: "en:Pantheon") == joined)
        // The abandoned fetch was joined, not repeated: 3 requests.
        #expect(http.arrived == 3)
    }

    @Test(.timeLimit(.minutes(1))) func cancelledPrefetchStopsWaitingAndTheFetchesFillTheCache() async throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = GatedHTTP { Self.route($0) }
        let images = PlaceImages(directory: dir, client: WikipediaClient(http: http))

        let prefetch = Task { await images.prefetch(["en:Pantheon", "it:Pantheon"]) }
        // Both fetches have sent their first request and are held at the gate.
        await http.waitForArrivals(2)
        prefetch.cancel()
        await prefetch.value
        #expect(await images.cached(wikipediaTitle: "en:Pantheon") == nil)

        await http.gate.open()
        #expect(await images.image(wikipediaTitle: "en:Pantheon") != nil)
        #expect(await images.image(wikipediaTitle: "it:Pantheon") != nil)
        // 2 titles × 3 requests = 6: both fetches ran to the end and were joined.
        #expect(http.arrived == 6)
    }

    @Test func fetchWithinCapReturnsAFastImage() async throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient { Self.route($0) }
        let images = PlaceImages(directory: dir, client: WikipediaClient(http: http))
        let image = await images.image(wikipediaTitle: "en:Pantheon", within: .seconds(30))
        #expect(image?.info.author == "Jane Doe")
        // A cached image is returned before the race, so even a zero cap gives it; still the first call's 3 requests.
        #expect(await images.image(wikipediaTitle: "en:Pantheon", within: .zero) == image)
        #expect(http.requests.count == 3)
    }

    @Test func notificationCapIsOnePointFiveSeconds() {
        #expect(PlaceImages.notificationCap == .milliseconds(1500))
    }

    @Test func malformedTitleGivesNil() async {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient { Self.route($0) }
        let images = PlaceImages(directory: dir, client: WikipediaClient(http: http))
        for title in ["Pantheon", ":Pantheon", "en:", "../../x:y", ""] {
            #expect(await images.image(wikipediaTitle: title) == nil)
            #expect(await images.cached(wikipediaTitle: title) == nil)
        }
        #expect(http.requests.isEmpty)
        // A malformed title is not remembered as "no image" either: nothing was written.
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty)
    }

    @Test func prefetchFetchesEachTitleOnce() async {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient { Self.route($0) }
        let images = PlaceImages(directory: dir, client: WikipediaClient(http: http))
        await images.prefetch(["en:Pantheon", "it:Pantheon", "en:Pantheon"])
        #expect(await images.cached(wikipediaTitle: "en:Pantheon") != nil)
        #expect(await images.cached(wikipediaTitle: "it:Pantheon") != nil)
        // 2 distinct titles × 3 requests = 6.
        #expect(http.requests.count == 6)
        await images.prefetch(["en:Pantheon"])
        #expect(http.requests.count == 6)
        await images.prefetch([])
        #expect(http.requests.count == 6)
    }

    @Test func titleForCandidate() {
        let at = Coordinate(latitude: 41.8986, longitude: 12.4769)
        #expect(PlaceImages.title(for: Candidate(id: "osm:way/1", name: "Pantheon", coordinate: at, kind: "historic=building",
                                                 wikipediaTitle: "it:Pantheon (Roma)")) == "it:Pantheon (Roma)")
        // The article title wins over the id.
        #expect(PlaceImages.title(for: Candidate(id: "wiki:en/123", name: "Pantheon, Rome", coordinate: at, kind: "wikipedia",
                                                 wikipediaTitle: "de:Pantheon (Rom)")) == "de:Pantheon (Rom)")
        #expect(PlaceImages.title(for: Candidate(id: "wiki:de/123", name: "Pantheon (Rom)", coordinate: at, kind: "wikipedia"))
                == "de:Pantheon (Rom)")
        #expect(PlaceImages.title(for: Candidate(id: "wiki:zh-min-nan/5", name: "X", coordinate: at, kind: "wikipedia")) == "zh-min-nan:X")
        #expect(PlaceImages.title(for: Candidate(id: "wiki:de/123", name: "P", coordinate: at, kind: "wikipedia", wikipediaTitle: ""))
                == "de:P")
        #expect(PlaceImages.title(for: Candidate(id: "osm:node/1", name: "Fontana", coordinate: at, kind: "amenity=fountain")) == nil)
        #expect(PlaceImages.title(for: Candidate(id: "wiki:/123", name: "P", coordinate: at, kind: "wikipedia")) == nil)
        #expect(PlaceImages.title(for: Candidate(id: "wiki:de", name: "P", coordinate: at, kind: "wikipedia")) == nil)
        #expect(PlaceImages.title(for: Candidate(id: "wiki:de/1", name: "", coordinate: at, kind: "wikipedia")) == nil)
    }
}

/// Holds every request at `gate` until it is opened; counts requests as they arrive and signals waiters.
final class GatedHTTP: HTTPClient, @unchecked Sendable {
    let gate = Gate()
    private let inner: StubHTTPClient
    private struct Arrivals {
        var count = 0
        var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }
    private let arrivals = LockedBox(Arrivals())

    init(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) {
        inner = StubHTTPClient(handler)
    }

    var arrived: Int { arrivals.value.count }

    /// Returns once at least `count` requests have arrived (held at the gate or not).
    func waitForArrivals(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let reached = arrivals.withValue { state in
                if state.count >= count { return true }
                state.waiters.append((count, continuation))
                return false
            }
            if reached { continuation.resume() }
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let ready = arrivals.withValue { state in
            state.count += 1
            let count = state.count
            let ready = state.waiters.filter { $0.count <= count }.map(\.continuation)
            state.waiters.removeAll { $0.count <= count }
            return ready
        }
        ready.forEach { $0.resume() }
        await gate.wait()
        return try await inner.send(request)
    }
}

/// Closed until `open()`; afterwards `wait()` returns at once.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
