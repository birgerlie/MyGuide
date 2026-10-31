import Testing
@testable import MyGuideCore

@Suite struct APIKeySourceTests {
    @Test func keyIsTrimmed() {
        #expect(APIKeySource.usable(" sk-own \n") == "sk-own")
        #expect(APIKeySource.usable("sk-own") == "sk-own")
    }

    @Test func blankIsNoKey() {
        #expect(APIKeySource.usable("  \n") == nil)
        #expect(APIKeySource.usable("") == nil)
    }

    @Test func nilIsNoKey() {
        #expect(APIKeySource.usable(nil) == nil)
    }

    /// Inner whitespace is part of what the owner typed; only the ends are trimmed.
    @Test func innerTextIsKept() {
        #expect(APIKeySource.usable("\tsk-a b\t") == "sk-a b")
    }
}
