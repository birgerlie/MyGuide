import Foundation

/// The owner's guide server: the app's only way to OpenAI when no key of the user's own is stored (spec 4, 8).
public enum GuideServer {
    public static let baseURL = URL(string: "https://myguide.itsalie.xyz/v1")!
    /// `OpenAIClient`'s API key when it talks to the guide server. `GuideServerHTTPClient` replaces it with the
    /// device token before anything is sent, so it never leaves the device.
    public static let placeholderKey = "guide-server"
}

/// Apple App Attest (`DCAppAttestService`) behind a protocol, so the core is testable without a device.
public protocol AppAttestProvider: Sendable {
    var isSupported: Bool { get }
    /// A new App Attest key; returns its key id as `DCAppAttestService.generateKey` does (base64).
    func generateKey() async throws -> String
    /// The attestation object for `keyId` over `clientDataHash`.
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
}

/// Where the guide server's device token is kept (the Keychain in the app). `nil` deletes it.
public protocol GuideTokenStore: Sendable {
    func read() throws -> String?
    func write(_ token: String?) throws
}
