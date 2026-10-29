import MyGuideCore
import SwiftUI

/// API key (Keychain only, never shown in full), story language, photo story and walking settings, usage, and the
/// developer screens and checks. In the design package (spec 15), every word in the story language.
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
                    Text(SettingsTexts.keySaved(suffix: savedKeySuffix, storyLanguage))
                } else if usesBundledKey {
                    Text(SettingsTexts.bundledKey(storyLanguage)).opacity(0.75)
                } else {
                    Text(SettingsTexts.noKey(storyLanguage)).opacity(0.75)
                }
                SecureField("sk-…", text: $draftKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: Theme.minimumTouchHeight)
                Button(SettingsTexts.save(storyLanguage)) { save() }
                    .buttonStyle(.themePrimary(.coral))
                    .disabled(trimmedDraft.isEmpty)
                if hasSavedKey {
                    Button(SettingsTexts.removeKey(storyLanguage), role: .destructive) { remove() }
                }
                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                ListSectionHeader(SettingsTexts.keySection(storyLanguage))
            } footer: {
                ListSectionFooter(SettingsTexts.keyFooter(storyLanguage))
            }
            .themedRows()
            Section {
                Picker(SettingsTexts.storyLanguage(storyLanguage), selection: $storyLanguage) {
                    Text("English").tag(StoryLanguage.english)
                    Text("Norsk").tag(StoryLanguage.norwegian)
                }
            } header: {
                ListSectionHeader(SettingsTexts.languageSection(storyLanguage))
            } footer: {
                ListSectionFooter(SettingsTexts.languageFooter(storyLanguage))
            }
            .themedRows()
            Section {
                Toggle(ScreenText.readAloud(storyLanguage), isOn: $readAloudAutomatically)
                    .tint(ScreenChrome.toggleTint)
                NavigationLink(SettingsTexts.storyTimings(storyLanguage)) { StoryTimingsView() }
            } header: {
                ListSectionHeader(SettingsTexts.photoStoriesSection(storyLanguage))
            } footer: {
                ListSectionFooter(SettingsTexts.readAloudFooter(storyLanguage))
            }
            .themedRows()
            Section {
                Toggle(SettingsTexts.prepareBackgroundPlaces(storyLanguage),
                       isOn: backgroundPlacesToggle(
                           alwaysGranted: BackgroundPlaces.shared.authorization == .authorizedAlways))
                .tint(ScreenChrome.toggleTint)
            } footer: {
                ListSectionFooter(SettingsTexts.prepareBackgroundPlacesFooter(storyLanguage))
            }
            .themedRows()
            Section {
                Stepper(value: $buzzesPerHour, in: 5...60, step: 5) {
                    Text(SettingsTexts.buzzesPerHour(buzzesPerHour, storyLanguage))
                }
                NavigationLink(SettingsTexts.buzzLog(storyLanguage)) { BuzzLogView(services: services) }
                NavigationLink(SettingsTexts.walkLog(storyLanguage)) { WalkLogListView(services: services) }
                Button(ResetText.button(storyLanguage), role: .destructive) { confirmingReset = true }
                    .confirmationDialog(ResetText.button(storyLanguage), isPresented: $confirmingReset,
                                        titleVisibility: .visible) {
                        Button(ResetText.confirm(storyLanguage), role: .destructive) { resetPlaceNotifications() }
                        Button(ResetText.cancel(storyLanguage), role: .cancel) {}
                    } message: {
                        Text(ResetText.message(storyLanguage))
                    }
                if resetFailed {
                    Label(ResetText.failed(storyLanguage), systemImage: "exclamationmark.triangle")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                ListSectionHeader(SettingsTexts.walkingSection(storyLanguage))
            } footer: {
                ListSectionFooter(SettingsTexts.walkingFooter(storyLanguage))
            }
            .themedRows()
            Section {
                if let totals {
                    Text(SettingsTexts.thisMonth(UsageFormat.dollars(totals.monthUSD), requests: totals.monthRequests,
                                                 storyLanguage))
                    Text(SettingsTexts.allTime(UsageFormat.dollars(totals.allTimeUSD), storyLanguage))
                    if totals.unpricedRequests > 0 {
                        Text(SettingsTexts.unpriced(storyLanguage)).opacity(0.75)
                    }
                } else if totalsFailed {
                    Text(SettingsTexts.usageUnavailable(storyLanguage)).opacity(0.75)
                }
            } header: {
                ListSectionHeader(SettingsTexts.usageSection(storyLanguage))
            } footer: {
                ListSectionFooter(SettingsTexts.usageFooter(asOf: PriceTable.current.asOf, storyLanguage))
            }
            .themedRows()
            Section {
                NavigationLink(SettingsTexts.deviceCheck(storyLanguage)) { SelfCheckView() }
                NavigationLink(SettingsTexts.walkingCheck(storyLanguage)) {
                    WalkingCheckView(model: services.walkingCheck, watch: services.watchLink)
                }
            }
            .themedRows()
        }
        .themedList()
        .themedTitle(SettingsTexts.title(storyLanguage))
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
            errorText = SettingsTexts.saveKeyFailed(error, storyLanguage)
        }
        refresh()
    }

    private func remove() {
        do {
            try services.keychain.delete(AppServices.apiKeyAccount)
            errorText = nil
        } catch {
            errorText = SettingsTexts.removeKeyFailed(error, storyLanguage)
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
            errorText = SettingsTexts.readKeychainFailed(error, storyLanguage)
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
