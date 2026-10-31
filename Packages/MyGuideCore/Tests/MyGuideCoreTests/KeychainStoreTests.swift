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
    @Test func writeWithThisDeviceOnlyRoundTripsAndOverwrites() throws {
        try store.write("one", account: "k", accessibility: .afterFirstUnlockThisDeviceOnly)
        #expect(try store.read("k") == "one")
        try store.write("two", account: "k", accessibility: .afterFirstUnlockThisDeviceOnly)
        #expect(try store.read("k") == "two")
        try store.delete("k")
    }

    // The macOS file-based keychain that `swift test` uses does not keep `kSecAttrAccessible`, and the data
    // protection keychain needs an entitlement the unsigned test runner lacks. So these check what `write` sends.

    private func accessible(_ attributes: [String: Any]) -> String? {
        attributes[kSecAttrAccessible as String] as? String
    }

    @Test func addUsesTheGivenAccessibility() {
        let data = Data("t".utf8)
        let byDefault = store.addQuery("k", data: data, accessibility: .afterFirstUnlock)
        #expect(accessible(byDefault) == kSecAttrAccessibleAfterFirstUnlock as String)
        let deviceOnly = store.addQuery("k", data: data, accessibility: .afterFirstUnlockThisDeviceOnly)
        #expect(accessible(deviceOnly) == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(deviceOnly[kSecValueData as String] as? Data == data)
        #expect(deviceOnly[kSecAttrAccount as String] as? String == "k")
    }

    /// SecItemUpdate leaves an attribute it is not given as it was, so the update must carry the accessibility:
    /// otherwise an item written earlier with `afterFirstUnlock` would keep travelling in backups.
    @Test func updateCarriesTheAccessibility() {
        let data = Data("t".utf8)
        let update = KeychainStore.updateAttributes(data: data, accessibility: .afterFirstUnlockThisDeviceOnly)
        #expect(accessible(update) == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(update[kSecValueData as String] as? Data == data)
        #expect(accessible(KeychainStore.updateAttributes(data: data, accessibility: .afterFirstUnlock))
                == kSecAttrAccessibleAfterFirstUnlock as String)
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
