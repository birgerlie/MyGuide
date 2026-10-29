import MyGuideCore

/// Every word on the device check, in the story language (spec 15). Error descriptions from the system stay as they
/// come.
enum SelfCheckTexts {
    static func title(_ language: StoryLanguage) -> String { SettingsTexts.deviceCheck(language) }

    static func runChecks(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Kjør sjekkene" : "Run checks"
    }

    static func camera(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Kamera" : "Camera"
    }

    static func location(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Posisjon" : "Location"
    }

    static func keychain(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Nøkkelring" : "Keychain"
    }

    /// The framework's name, the same in both languages.
    static func swiftData(_ language: StoryLanguage) -> String { "SwiftData" }

    // MARK: Status words (the check mark's VoiceOver label)

    static func waiting(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Venter" : "Waiting"
    }

    static func passed(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Bestått" : "Passed"
    }

    static func failed(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Feilet" : "Failed"
    }

    // MARK: Location

    static func noPermissionAnswer(_ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Ikke noe svar på spørsmålet om posisjon innen 60 s"
            : "No answer to the location permission prompt within 60 s"
    }

    static func locationNotGranted(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ikke tilgang til posisjon" : "Location permission not granted"
    }

    static func noHeading(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Kompassretning er ikke tilgjengelig" : "Heading (compass) not available"
    }

    static func fix(accuracyM: Int, _ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Posisjon ±\(accuracyM) m, kompassretning tilgjengelig"
            : "Fix ±\(accuracyM) m, heading available"
    }

    static func noFix(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ingen posisjon innen 15 s" : "No location fix within 15 s"
    }

    static func locationDenied(_ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Ingen tilgang til posisjon (kCLErrorDenied)"
            : "Location access denied (kCLErrorDenied)"
    }

    static func locationError(domain: String, code: Int, description: String, _ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Posisjonsfeil: \(domain) kode \(code): \(description)"
            : "Location error: \(domain) code \(code): \(description)"
    }

    // MARK: Camera

    static func cameraGranted(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Tilgang til kamera gitt" : "Camera access granted"
    }

    static func cameraNotGranted(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ikke tilgang til kamera" : "Camera permission not granted"
    }

    // MARK: Keychain

    static func keychainMismatch(_ value: String, _ language: StoryLanguage) -> String {
        language == .norwegian ? "Leste tilbake \(value), ventet probe" : "Read back \(value), expected probe"
    }

    static func keychainPassed(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Skriving, lesing og sletting virket" : "Write, read and delete succeeded"
    }

    static func keychainError(_ error: Error, _ language: StoryLanguage) -> String {
        "\(language == .norwegian ? "Feil i nøkkelringen" : "Keychain error"): \(error)"
    }

    // MARK: SwiftData

    static func probeNotFound(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Den lagrede prøven ble ikke funnet ved henting" : "Saved probe not found on fetch"
    }

    static func swiftDataPassed(count: Int, _ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Lagret og hentet \(count) prøve(r), og slettet dem"
            : "Saved and fetched \(count) probe(s), then deleted"
    }

    static func swiftDataError(_ error: Error, _ language: StoryLanguage) -> String {
        "\(language == .norwegian ? "SwiftData-feil" : "SwiftData error"): \(error)"
    }
}
