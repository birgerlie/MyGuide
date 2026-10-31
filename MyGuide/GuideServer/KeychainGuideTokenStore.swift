import Foundation
import MyGuideCore

/// The guide server's device token in the Keychain (account `guideServerToken`, the app's Keychain service). Writing
/// nil deletes it. The token is never logged.
struct KeychainGuideTokenStore: GuideTokenStore {
    static let account = "guideServerToken"

    private let keychain: KeychainStore

    init(_ keychain: KeychainStore) {
        self.keychain = keychain
    }

    func read() throws -> String? {
        try keychain.read(Self.account)
    }

    func write(_ token: String?) throws {
        if let token {
            try keychain.write(token, account: Self.account)
        } else {
            try keychain.delete(Self.account)
        }
    }
}
