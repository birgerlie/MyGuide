import MyGuideCore
import SwiftUI

/// API key (Keychain only, never shown in full) and the device check.
struct SettingsView: View {
    let services: AppServices

    @State private var draftKey = ""
    @State private var savedKeySuffix: String?
    @State private var hasSavedKey = false
    @State private var usesBundledKey = false
    @State private var errorText: String?
    @State private var totals: UsageTotals?
    @State private var totalsFailed = false
    @AppStorage(AppServices.storyLanguageKey) private var storyLanguage: StoryLanguage = .english
    @AppStorage(WalkingController.buzzesPerHourKey) private var buzzesPerHour = BuzzBudget.defaultPerHour

    var body: some View {
        Form {
            Section {
                if hasSavedKey {
                    Text(savedKeySuffix.map { "Key saved ••••\($0)" } ?? "Key saved")
                } else if usesBundledKey {
                    Text("Using the test key built into this version").foregroundStyle(.secondary)
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
                Picker("Story language", selection: $storyLanguage) {
                    Text("English").tag(StoryLanguage.english)
                    Text("Norsk").tag(StoryLanguage.norwegian)
                }
            } header: {
                Text("Language")
            } footer: {
                Text("Applies to new photos. Stories already told keep their language.")
            }
            Section {
                Stepper(value: $buzzesPerHour, in: 5...60, step: 5) {
                    Text("Buzzes per hour: \(buzzesPerHour)")
                }
                NavigationLink("Buzz log") { BuzzLogView(services: services) }
                NavigationLink("Walk log") { WalkLogListView(services: services) }
            } header: {
                Text("Walking")
            } footer: {
                Text("At most this many buzzes an hour in walking mode. A change also applies during a walk.")
            }
            Section {
                if let totals {
                    Text("This month: \(UsageFormat.dollars(totals.monthUSD)) (\(totals.monthRequests) \(totals.monthRequests == 1 ? "request" : "requests"))")
                    Text("All time: \(UsageFormat.dollars(totals.allTimeUSD))")
                    if totals.unpricedRequests > 0 {
                        Text("some usage not priced").foregroundStyle(.secondary)
                    }
                } else if totalsFailed {
                    Text("Usage unavailable").foregroundStyle(.secondary)
                }
            } header: {
                Text("Usage")
            } footer: {
                Text("Failed requests are not counted. Prices as of \(PriceTable.current.asOf).")
            }
            Section {
                NavigationLink("Device check") { SelfCheckView() }
                NavigationLink("Walking check") { WalkingCheckView(model: services.walkingCheck, watch: services.watchLink) }
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
            totals = try services.memory.usageTotals(now: .now, calendar: .current)
            totalsFailed = false
        } catch {
            AppServices.logMemoryFailure("usage totals failed", error)
            totals = nil
            totalsFailed = true
        }
        do {
            let key = try services.keychain.read(AppServices.apiKeyAccount)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            hasSavedKey = !key.isEmpty
            savedKeySuffix = APIKeyDisplay.visibleSuffix(of: key)
            usesBundledKey = !hasSavedKey && APIKeySource.resolve(stored: nil, bundled: AppServices.bundledAPIKey) != nil
        } catch {
            hasSavedKey = false
            usesBundledKey = false
            savedKeySuffix = nil
            errorText = "Couldn't read the Keychain: \(error)"
        }
    }
}

/// Dollar amounts as "$0.42", always in the POSIX locale so a Norwegian device never shows "$0,42".
enum UsageFormat {
    static func dollars(_ value: Double) -> String {
        // Below one cent show "<$0.01" so small usage is not shown as $0.00.
        if value > 0 && value < 0.01 { return "<$0.01" }
        return "$" + value.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "en_US_POSIX")))
    }
}
