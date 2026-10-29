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
    @State private var confirmingReset = false
    @State private var resetFailed = false
    @AppStorage(AppServices.storyLanguageKey) private var storyLanguage: StoryLanguage = .english
    @AppStorage(WalkingController.buzzesPerHourKey) private var buzzesPerHour = BuzzBudget.defaultPerHour
    @AppStorage(BackgroundPlaces.settingKey) private var prepareBackgroundPlaces = true
    @AppStorage(StoryViewModel.readAloudKey) private var readAloudAutomatically = true

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
                Toggle(ScreenText.readAloud(storyLanguage), isOn: $readAloudAutomatically)
                NavigationLink("Story timings") { StoryTimingsView() }
            } header: {
                Text("Photo stories")
            } footer: {
                Text(storyLanguage == .norwegian
                     ? "Av: ingen tale hentes; trykk Lytt for å høre fortellingen. Gjelder alle nivåer. Gåmodus har egne innstillinger."
                     : "Off: no speech is fetched; tap Listen to hear the story. Applies to every level. Walking mode has its own settings.")
            }
            Section {
                Toggle(storyLanguage == .norwegian ? "Forbered steder i bakgrunnen" : "Prepare places in the background",
                       isOn: backgroundPlacesToggle(
                           alwaysGranted: BackgroundPlaces.shared.authorization == .authorizedAlways))
            } footer: {
                Text(storyLanguage == .norwegian
                     ? "Henter stedene rundt deg når du har flyttet deg, også med appen lukket, så kameraet svarer raskere. Krever posisjon «Alltid»."
                     : "Fetches the places around you when you have moved, also with the app closed, so the camera answers faster. Needs location access Always.")
            }
            Section {
                Stepper(value: $buzzesPerHour, in: 5...60, step: 5) {
                    Text("Buzzes per hour: \(buzzesPerHour)")
                }
                NavigationLink("Buzz log") { BuzzLogView(services: services) }
                NavigationLink("Walk log") { WalkLogListView(services: services) }
                Button(ResetText.button(storyLanguage), role: .destructive) { confirmingReset = true }
                    .confirmationDialog(ResetText.button(storyLanguage), isPresented: $confirmingReset,
                                        titleVisibility: .visible) {
                        Button(ResetText.confirm(storyLanguage), role: .destructive) { resetPlaceNotifications() }
                        Button(ResetText.cancel(storyLanguage), role: .cancel) {}
                    } message: {
                        Text(ResetText.message(storyLanguage))
                    }
                if resetFailed {
                    Text(ResetText.failed(storyLanguage)).font(.footnote).foregroundStyle(.red)
                }
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

    /// On only when the setting is on and access is Always (spec 7: on by default when Always is granted), so without
    /// Always it reads off and turning it on asks for Always. `alwaysGranted` is read in `body`, so the observed
    /// authorization redraws the toggle when it changes, also after the prompt or a trip to the Settings app.
    private func backgroundPlacesToggle(alwaysGranted: Bool) -> Binding<Bool> {
        Binding(
            get: { prepareBackgroundPlaces && alwaysGranted },
            set: { on in
                prepareBackgroundPlaces = on
                if on { BackgroundPlaces.shared.settingTurnedOn() } else { BackgroundPlaces.shared.stop() }
            })
    }

    /// Spec 13.5: every place may notify again, in memory and in a walk already running; stories, diary and the
    /// buzz log stay. A memory failure is logged and shown, and the running walk is then left as it was.
    private func resetPlaceNotifications() {
        do {
            try services.memory.resetPlaceNotifications()
            services.walking.resetExclusions()
            resetFailed = false
        } catch {
            AppServices.logMemoryFailure("place notification reset failed", error)
            resetFailed = true
        }
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

/// The reset button's texts in the story language (spec 13.5).
enum ResetText {
    static func button(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Nullstill stedsvarsler" : "Reset place notifications"
    }

    static func message(_ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Alle steder kan gi varsel igjen. Fortellinger og dagbok beholdes."
            : "Every place can notify you again. Stories and diary are kept."
    }

    static func confirm(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Nullstill" : "Reset"
    }

    static func cancel(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Avbryt" : "Cancel"
    }

    static func failed(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Kunne ikke nullstille stedsvarslene." : "Couldn't reset the place notifications."
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
