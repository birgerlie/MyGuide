import Foundation
import Testing
@testable import MyGuideCore

@Suite struct PriceTableTests {
    let t = PriceTable(asOf: "test", prices: ["text": .tokens(inputPerMillion: 0.25, outputPerMillion: 2.00),
                                             "tts": .speechPerMinute(0.015), "img": .perImage(0.063),
                                             "imgtok": .tokens(inputPerMillion: 5.00, outputPerMillion: 30.00)])
    func e(_ kind: UsageKind, _ model: String, i: Int = 0, o: Int = 0, w: Int = 0, n: Int = 0) -> UsageEntry {
        UsageEntry(date: .now, kind: kind, model: model, inputTokens: i, outputTokens: o, words: w, images: n)
    }
    @Test func tokenCost() {
        // 1_200·0.25/1e6 = 0.0003; 400·2.00/1e6 = 0.0008 → 0.0011
        #expect(abs(t.estimatedUSD(e(.story, "text", i: 1_200, o: 400))! - 0.0011) < 1e-12)
        // 10_000·0.25/1e6 = 0.0025; 0 output → 0.0025
        #expect(abs(t.estimatedUSD(e(.story, "text", i: 10_000))! - 0.0025) < 1e-12)
    }
    @Test func speechCostFromWordsAt150wpm() {
        // 300 words / 150 = 2 min · 0.015 = 0.03;  50 words / 150 = 0.3333 min · 0.015 = 0.005
        #expect(abs(t.estimatedUSD(e(.speech, "tts", w: 300))! - 0.03) < 1e-12)
        #expect(abs(t.estimatedUSD(e(.speech, "tts", w: 50))! - 0.005) < 1e-12)
    }
    @Test func imageCost() {
        // 1·0.063 = 0.063; 2·0.063 = 0.126
        #expect(t.estimatedUSD(e(.image, "img", n: 1)) == 0.063)
        #expect(abs(t.estimatedUSD(e(.image, "img", n: 2))! - 0.126) < 1e-12)
    }
    @Test func tokenPricedImageCost() {
        // 1000·5/1e6 = 0.005; 1575·30/1e6 = 0.04725; total 0.05225
        #expect(abs(t.estimatedUSD(e(.image, "imgtok", i: 1_000, o: 1_575, n: 1))! - 0.05225) < 1e-12)
        // 0 input; 2000·30/1e6 = 0.06
        #expect(abs(t.estimatedUSD(e(.image, "imgtok", o: 2_000, n: 1))! - 0.06) < 1e-12)
    }
    @Test func tokenPricedImageWithNoTokensIsUnpriced() {
        #expect(t.estimatedUSD(e(.image, "imgtok", n: 1)) == nil)
    }
    @Test func unknownModelIsNil() { #expect(t.estimatedUSD(e(.story, "nope", i: 5)) == nil) }
    @Test func currentTableCoversDefaultModels() {
        let m = OpenAIModels.current
        #expect([m.story, m.speech, m.image].allSatisfy { PriceTable.current.prices[$0] != nil })
    }
}
