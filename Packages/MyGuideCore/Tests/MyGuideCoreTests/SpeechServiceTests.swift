import Foundation
import Testing
@testable import MyGuideCore

@Suite struct SpeechServiceTests {
    let mp3 = Data([0x49, 0x44, 0x33, 1])
    func dir() -> URL { FileManager.default.temporaryDirectory.appending(path: "speech-\(UUID().uuidString)") }

    @Test func requestShapeAndUsage() async throws {
        let http = StubHTTPClient { _ in (200, Data([0x49, 0x44, 0x33])) }
        let svc = SpeechService(openAI: OpenAIClient(apiKey: "k", http: http), cacheDirectory: dir(), now: { Date(timeIntervalSince1970: 1) })
        let (url, usage) = try await svc.audioFile(text: "One two three four", language: .english, cacheKey: "s-1")
        let r = http.requests[0]
        #expect(r.url!.absoluteString == "https://api.openai.com/v1/audio/speech")
        let b = r.jsonBody
        #expect(b["model"] as? String == "gpt-4o-mini-tts" && b["voice"] as? String == "coral")
        #expect(b["input"] as? String == "One two three four" && b["response_format"] as? String == "mp3")
        #expect((b["instructions"] as? String)?.contains("friend") == true)
        #expect(try Data(contentsOf: url) == Data([0x49, 0x44, 0x33]))
        #expect(usage == UsageEntry(date: Date(timeIntervalSince1970: 1), kind: .speech, model: "gpt-4o-mini-tts",
                                    inputTokens: 0, outputTokens: 0, words: 4, images: 0))
    }
    @Test func secondCallHitsCache() async throws {
        let http = StubHTTPClient { _ in (200, mp3) }
        let svc = SpeechService(openAI: OpenAIClient(apiKey: "k", http: http), cacheDirectory: dir())
        _ = try await svc.audioFile(text: "Hi", language: .english, cacheKey: "s-1")
        let (_, usage) = try await svc.audioFile(text: "Hi", language: .english, cacheKey: "s-1")
        #expect(http.requests.count == 1 && usage == nil)
    }
    @Test func longTextIsChunkedAtSentences() async throws {
        // 50 sentences of 99 chars joined by single spaces = 50·99 + 49 = 4999 chars. Greedy ≤ 4000:
        // 40 sentences = 40·99 + 39 = 3999; a 41st would make 3999 + 1 + 99 = 4099 > 4000.
        // Remaining 10 sentences = 10·99 + 9 = 999 → 2 chunks
        let sentence = String(repeating: "a", count: 98) + "."
        let text = Array(repeating: sentence, count: 50).joined(separator: " ")
        let chunks = SpeechService.chunks(text, maxCharacters: 4000)
        #expect(chunks.count == 2 && chunks[0].count == 3999 && chunks[1].count == 999)
        let http = StubHTTPClient { _ in (200, Data([0x49, 0x44, 0x33, 7])) }
        let (url, _) = try await SpeechService(openAI: OpenAIClient(apiKey: "k", http: http), cacheDirectory: dir())
            .audioFile(text: text, language: .english, cacheKey: "long")
        let written = try Data(contentsOf: url)
        #expect(http.requests.count == 2 && written == Data([0x49, 0x44, 0x33, 7, 0x49, 0x44, 0x33, 7]))
    }
    @Test func norwegianInstructions() {
        #expect(SpeechService.instructions(language: .norwegian).contains("Norwegian Bokmål"))
        #expect(!SpeechService.instructions(language: .english).contains("Norwegian"))
    }

    // Hand computation: "Hi there. Bye now." has two sentences of 9 and 8 chars; 9 + 1 + 8 = 18 fits a limit
    // of 18 (one chunk) but not 17 (two chunks).
    @Test func chunkBoundaryAtExactLimit() {
        let text = "Hi there. Bye now."
        #expect(SpeechService.chunks(text, maxCharacters: 18) == [text])
        #expect(SpeechService.chunks(text, maxCharacters: 17) == ["Hi there.", "Bye now."])
    }
    @Test func shortAndEmptyText() {
        #expect(SpeechService.chunks("Hello", maxCharacters: 4000) == ["Hello"])
        #expect(SpeechService.chunks("  \n ", maxCharacters: 4000).isEmpty)
        #expect(SpeechService.chunks("", maxCharacters: 4000).isEmpty)
    }
    // Hand computation: "aaaa bbbb cccc dddd" (19 chars), limit 10: last space before index 10 is at 9,
    // so "aaaa bbbb" (9), then "cccc dddd" (9).
    @Test func overlongSentenceSplitsAtLastSpace() {
        #expect(SpeechService.chunks("aaaa bbbb cccc dddd", maxCharacters: 10) == ["aaaa bbbb", "cccc dddd"])
    }
    // No space at all: hard split at the limit. 25 chars, limit 10 -> 10, 10, 5.
    @Test func unbrokenRunIsHardSplit() {
        let chunks = SpeechService.chunks(String(repeating: "x", count: 25), maxCharacters: 10)
        #expect(chunks.map(\.count) == [10, 10, 5])
    }
    // A short sentence after an overlong one must still be packed.
    @Test func overlongSentenceFollowedByShortOne() {
        let chunks = SpeechService.chunks("aaaa bbbb cccc dddd. Ok.", maxCharacters: 10)
        // Pieces: "aaaa bbbb" (9), "cccc dddd." (10), "Ok." (3). 9+1+10 > 10 and 10+1+3 > 10, so three chunks.
        #expect(chunks == ["aaaa bbbb", "cccc dddd.", "Ok."])
    }
    @Test func emptyTextIsRejectedWithoutRequest() async {
        let http = StubHTTPClient { _ in (200, mp3) }
        let svc = SpeechService(openAI: OpenAIClient(apiKey: "k", http: http), cacheDirectory: dir())
        await #expect(throws: OpenAIError.self) {
            _ = try await svc.audioFile(text: "  ", language: .english, cacheKey: "e")
        }
        #expect(http.requests.isEmpty)
    }
    @Test func failureLeavesNoCacheFile() async throws {
        let d = dir()
        let http = StubHTTPClient { _ in (500, Data()) }
        let svc = SpeechService(openAI: OpenAIClient(apiKey: "k", http: http), cacheDirectory: d)
        await #expect(throws: OpenAIError.self) {
            _ = try await svc.audioFile(text: "Hi", language: .english, cacheKey: "f")
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
        #expect(files.isEmpty)
    }
    @Test func partialFailureInSecondChunkWritesNothing() async throws {
        let sentence = String(repeating: "a", count: 98) + "."
        let text = Array(repeating: sentence, count: 50).joined(separator: " ")
        let calls = LockedBox(0)
        let http = StubHTTPClient { _ in
            let n = calls.withValue { $0 += 1; return $0 }
            return n == 1 ? (200, mp3) : (500, Data())
        }
        let d = dir()
        let svc = SpeechService(openAI: OpenAIClient(apiKey: "k", http: http), cacheDirectory: d)
        await #expect(throws: OpenAIError.self) {
            _ = try await svc.audioFile(text: text, language: .english, cacheKey: "p")
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
        #expect(files.isEmpty)
    }
    @Test func languageIsPartOfCacheFile() async throws {
        let http = StubHTTPClient { _ in (200, mp3) }
        let svc = SpeechService(openAI: OpenAIClient(apiKey: "k", http: http), cacheDirectory: dir())
        let (en, _) = try await svc.audioFile(text: "Hi", language: .english, cacheKey: "k")
        let (nb, _) = try await svc.audioFile(text: "Hei", language: .norwegian, cacheKey: "k")
        #expect(en.lastPathComponent == "k-en.mp3" && nb.lastPathComponent == "k-nb.mp3")
        #expect(http.requests.count == 2)
    }
    @Test func cancelledRequestThrowsCancellation() async {
        let http = StubHTTPClient { _ in throw URLError(.cancelled) }
        let svc = SpeechService(openAI: OpenAIClient(apiKey: "k", http: http), cacheDirectory: dir())
        await #expect(throws: CancellationError.self) {
            _ = try await svc.audioFile(text: "Hi", language: .english, cacheKey: "c")
        }
    }

    @Test func nonMP3BodyIsRejectedAndNotCached() async throws {
        let d = dir()
        let http = StubHTTPClient { _ in (200, Data("<html>proxy</html>".utf8)) }
        let svc = SpeechService(openAI: OpenAIClient(apiKey: "k", http: http), cacheDirectory: d)
        await #expect(throws: OpenAIError.malformedResponse) {
            _ = try await svc.audioFile(text: "Hi", language: .english, cacheKey: "x")
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
        #expect(files.isEmpty)
    }
    // ID3 -> ok; 0xFF 0xFB (0xFB & 0xE0 = 0xE0) -> ok; 0xFF 0x1F (top bits 000) -> no; 2 bytes "ID" -> no; empty -> no.
    @Test func mp3SniffingBoundaries() {
        #expect(SpeechService.looksLikeMP3(Data([0x49, 0x44, 0x33])))
        #expect(SpeechService.looksLikeMP3(Data([0xFF, 0xFB])))
        #expect(!SpeechService.looksLikeMP3(Data([0xFF, 0x1F])))
        #expect(!SpeechService.looksLikeMP3(Data([0x49, 0x44])))
        #expect(!SpeechService.looksLikeMP3(Data()))
    }
}
