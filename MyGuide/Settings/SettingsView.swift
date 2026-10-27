import MyGuideCore
import SwiftUI

/// API key (Keychain only, never shown in full) and the device check.
struct SettingsView: View {
    let services: AppServices

    @State private var draftKey = ""
    @State private var savedKeySuffix: String?
    @State private var hasSavedKey = false
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                if hasSavedKey {
                    Text(savedKeySuffix.map { "Key saved ••••\($0)" } ?? "Key saved")
                } else {
                    Text("No key saved").foregroundStyle(.secondary)
                }
                SecureField("sk-…", text: $draftKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save") { save() }
                    .disabled(trimmedDraft.isEmpty)
                if hasSavedKey {
                    Button("Remove key", role: .destructive) { remove() }
                }
                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("OpenAI API key")
            } footer: {
                Text("Stored only in this iPhone's Keychain.")
            }
            Section {
                NavigationLink("Device check") { SelfCheckView() }
            }
        }
        .navigationTitle("Settings")
        .onAppear { refresh() }
    }

    private var trimmedDraft: String {
        draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        let key = trimmedDraft
        guard !key.isEmpty else { return }
        do {
            try services.keychain.write(key, account: AppServices.apiKeyAccount)
            draftKey = ""
            errorText = nil
        } catch {
            errorText = "Couldn't save the key: \(error)"
        }
        refresh()
    }

    private func remove() {
        do {
            try services.keychain.delete(AppServices.apiKeyAccount)
            errorText = nil
        } catch {
            errorText = "Couldn't remove the key: \(error)"
        }
        refresh()
    }

    private func refresh() {
        do {
            let key = try services.keychain.read(AppServices.apiKeyAccount)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            hasSavedKey = !key.isEmpty
            savedKeySuffix = APIKeyDisplay.visibleSuffix(of: key)
        } catch {
            hasSavedKey = false
            savedKeySuffix = nil
            errorText = "Couldn't read the Keychain: \(error)"
        }
    }
}
