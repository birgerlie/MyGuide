import DeviceCheck
import Foundation
import MyGuideCore

/// `AppAttestProvider` over Apple's App Attest (`DCAppAttestService.shared`). Not supported in the simulator and on
/// devices without the Secure Enclave support App Attest needs; there the app tells stories only with a key of the
/// user's own (spec 8).
struct DeviceAppAttest: AppAttestProvider {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)
    }
}
