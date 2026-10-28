import Testing
@testable import MyGuideCore

@Suite struct APIKeySourceTests {
    @Test func storedKeyWins() {
        #expect(APIKeySource.resolve(stored: "sk-own", bundled: "sk-test") == .stored("sk-own"))
    }

    @Test func bundledKeyWhenNoneStored() {
        #expect(APIKeySource.resolve(stored: nil, bundled: "sk-test") == .bundled("sk-test"))
        #expect(APIKeySource.resolve(stored: "  \n", bundled: " sk-test ") == .bundled("sk-test"))
    }

    @Test func noKeyAtAll() {
        #expect(APIKeySource.resolve(stored: nil, bundled: nil) == nil)
        #expect(APIKeySource.resolve(stored: "", bundled: "") == nil)
    }

    /// A build without OPENAI_BUNDLED_KEY leaves the Info.plist value empty, or the unexpanded variable when the
    /// build setting is missing altogether; neither is a key.
    @Test func unexpandedBuildVariableIsNotAKey() {
        #expect(APIKeySource.resolve(stored: nil, bundled: "$(OPENAI_BUNDLED_KEY)") == nil)
    }

    @Test func keyValue() {
        #expect(APIKeySource.stored("a").key == "a")
        #expect(APIKeySource.bundled("b").key == "b")
    }
}
