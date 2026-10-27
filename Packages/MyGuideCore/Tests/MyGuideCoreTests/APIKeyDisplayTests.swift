import Testing
@testable import MyGuideCore

@Suite struct APIKeyDisplayTests {
    @Test func suffixOnlyForLongKeys() {
        #expect(APIKeyDisplay.visibleSuffix(of: "sk-proj-abcdefghijklmnopabcd") == "abcd")
        #expect(APIKeyDisplay.visibleSuffix(of: "123456789012") == "9012") // boundary: 12 characters
        #expect(APIKeyDisplay.visibleSuffix(of: "12345678901") == nil)     // 11 characters
        #expect(APIKeyDisplay.visibleSuffix(of: "") == nil)
    }

    @Test func countsCharactersNotBytes() {
        // 12 characters (é is one Character, two UTF-8 bytes)
        #expect(APIKeyDisplay.visibleSuffix(of: "ééééééééwxyz") == "wxyz")
    }
}
