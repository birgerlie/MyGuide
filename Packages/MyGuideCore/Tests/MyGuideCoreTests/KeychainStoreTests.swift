import Testing
import Foundation
import Security
@testable import MyGuideCore

@Suite struct KeychainStoreTests {
    let store = KeychainStore(service: "io.github.birgerlie.MyGuide.tests.\(UUID().uuidString)")

    @Test func readMissingReturnsNil() throws {
        #expect(try store.read("absent") == nil)
    }
    @Test func writeThenReadRoundTrips() throws {
        try store.write("sk-test-123", account: "k")
        #expect(try store.read("k") == "sk-test-123")
        try store.delete("k")
    }
    @Test func writeOverwritesExisting() throws {
        try store.write("one", account: "k")
        try store.write("two", account: "k")
        #expect(try store.read("k") == "two")
        try store.delete("k")
    }
    @Test func deleteMissingDoesNotThrow() throws {
        try store.delete("never-written")
    }
    @Test func emptyStringIsStoredAsEmpty() throws {
        try store.write("", account: "k")
        #expect(try store.read("k") == "")
        try store.delete("k")
    }
}

@Suite struct KeychainErrorDiagnosticTests {
    private struct Other: Error, CustomStringConvertible { var description: String { "other failure" } }

    @Test func unexpectedStatusKeepsTheOSStatus() {
        // errSecInteractionNotAllowed = −25308; bridged to NSError this case has code 0, so the status must be in the text.
        #expect(KeychainError.diagnostic(KeychainError.unexpectedStatus(-25308)) == "KeychainError.unexpectedStatus(-25308)")
        #expect(KeychainError.diagnostic(KeychainError.unexpectedStatus(errSecDecode)).contains("-26275"))
    }

    @Test func otherErrorsGiveTheirDescription() {
        #expect(KeychainError.diagnostic(Other()) == "other failure")
    }
}
