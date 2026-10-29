import CoreLocation
import MyGuideCore

/// Every word on the walking check, its test notification and its test Live Activity (spec 15), in the iPhone's
/// language (`UILanguage.current`, spec 17). Error descriptions from the system and the watch's last message type stay
/// as they come.
enum WalkingCheckTexts {
    static func title(_ language: StoryLanguage) -> String { SettingsTexts.walkingCheck(language) }

    // MARK: Rows and buttons

    static func backgroundLocation(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Posisjon i bakgrunnen" : "Background location"
    }

    static func buzzFromWatch(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Varsel fra klokken" : "Buzz from the watch"
    }

    static func liveActivity(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Direkteaktivitet" : "Live Activity"
    }

    static func watch(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Klokke" : "Watch"
    }

    static func start(_ language: StoryLanguage) -> String { "Start" }

    static func stop(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Stopp" : "Stop"
    }

    static func end(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Avslutt" : "End"
    }

    static func cancel(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Avbryt" : "Cancel"
    }

    static func sendTestNotification(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Send testvarsel" : "Send test notification"
    }

    /// "Paret: ja · app installert: ja · tilgjengelig: nei · siste melding: ingen". The message is its type (data).
    static func watchLink(paired: Bool, installed: Bool, reachable: Bool, lastMessage: String?,
                          _ language: StoryLanguage) -> String {
        let no = language == .norwegian
        func yesNo(_ value: Bool) -> String { value ? (no ? "ja" : "yes") : (no ? "nei" : "no") }
        let last = lastMessage ?? (no ? "ingen" : "none")
        return no
            ? "Paret: \(yesNo(paired)) · app installert: \(yesNo(installed)) · tilgjengelig: \(yesNo(reachable)) · siste melding: \(last)"
            : "Paired: \(yesNo(paired)) · app installed: \(yesNo(installed)) · reachable: \(yesNo(reachable)) · last message: \(last)"
    }

    static func notStarted(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ikke startet" : "Not started"
    }

    // MARK: Background location

    /// "Tillatelse: Alltid · 12 posisjonsmålinger, 10 i bakgrunnen, lengste opphold 4 s"; the counts only once a run began.
    static func locationStatus(authorization: CLAuthorizationStatus, counts: (total: Int, background: Int, gap: Int)?,
                               _ language: StoryLanguage) -> String {
        let no = language == .norwegian
        let fixes = counts.map { c in
            no ? " · \(c.total) posisjonsmålinger, \(c.background) i bakgrunnen, lengste opphold \(c.gap) s"
                : " · \(c.total) fixes, \(c.background) in background, longest gap \(c.gap) s"
        } ?? ""
        return "\(no ? "Tillatelse" : "Authorization"): \(describe(authorization, language))\(fixes)"
    }

    static func describe(_ status: CLAuthorizationStatus, _ language: StoryLanguage) -> String {
        let no = language == .norwegian
        switch status {
        case .notDetermined: return no ? "ikke spurt" : "not asked"
        case .restricted: return no ? "begrenset" : "restricted"
        case .denied: return no ? "avslått" : "denied"
        case .authorizedWhenInUse: return no ? "Ved bruk" : "When In Use"
        case .authorizedAlways: return no ? "Alltid" : "Always"
        @unknown default: return no ? "ukjent" : "unknown"
        }
    }

    static func backgroundPassed(fixes: Int, gap: Int, _ language: StoryLanguage) -> String {
        language == .norwegian
            ? "\(fixes) posisjonsmålinger i bakgrunnen, lengste opphold \(gap) s"
            : "\(fixes) fixes while in background, longest gap \(gap) s"
    }

    static func locationNotGranted(_ language: StoryLanguage) -> String { SelfCheckTexts.locationNotGranted(language) }

    static func noBackgroundFixes(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ingen posisjonsmålinger kom i bakgrunnen" : "No fixes arrived while in background"
    }

    static func tooFewBackgroundFixes(_ fixes: Int, needed: Int, _ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Bare \(fixes) posisjonsmålinger i bakgrunnen (trenger \(needed))"
            : "Only \(fixes) fixes while in background (need \(needed))"
    }

    // MARK: Buzz from the watch

    static func notificationsNotGranted(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ikke tilgang til varsler" : "Notification permission not granted"
    }

    static func tellMe(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Lytt" : "Listen"
    }

    static func skip(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Hopp over" : "Skip"
    }

    static func testTitle(_ language: StoryLanguage) -> String {
        language == .norwegian ? "MyGuide-test" : "MyGuide test"
    }

    static func testBody(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Trykk Lytt på klokken" : "Tap Listen on your watch"
    }

    static func scheduleFailed(_ description: String, _ language: StoryLanguage) -> String {
        "\(language == .norwegian ? "Kunne ikke planlegge" : "Could not schedule"): \(description)"
    }

    static func notificationError(_ description: String, _ language: StoryLanguage) -> String {
        "\(language == .norwegian ? "Varselfeil" : "Notification error"): \(description)"
    }

    static func notificationScheduled(inS seconds: Int, _ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Varsel om \(seconds) s. Lås telefonen og trykk Lytt på klokken."
            : "Notification in \(seconds) s. Lock the phone and tap Listen on the watch."
    }

    static func cancelled(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Avbrutt" : "Cancelled"
    }

    static func noAction(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ingen handling mottatt" : "No action received"
    }

    static func noActionWithin(_ seconds: Int, _ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Ingen Lytt eller Hopp over innen \(seconds) s"
            : "No Listen or Skip within \(seconds) s"
    }

    static func skipped(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Hoppet over" : "Skipped"
    }

    static func skippedDetail(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Hoppet over – trykk Lytt for å teste lyden" : "Skipped — tap Listen to test audio"
    }

    static func openedWithoutAction(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Varselet ble åpnet uten handling" : "Notification opened without an action"
    }

    // MARK: Tone

    static func playbackFailed(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Avspillingen feilet" : "Playback failed"
    }

    static func playbackError(_ description: String, _ language: StoryLanguage) -> String {
        "\(language == .norwegian ? "Avspillingsfeil" : "Playback error"): \(description)"
    }

    static func playedInBackground(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Spilt av fra bakgrunnen ✓" : "Played from background ✓"
    }

    static func playedInForeground(_ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Spilt av, men appen var i forgrunnen – lås telefonen og prøv igjen"
            : "Played, but the app was in the foreground — lock the phone and try again"
    }

    static func playingTone(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Spiller tonen" : "Playing the tone"
    }

    static func noWatchTell(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ingen Lytt fra klokken ennå" : "No Listen received from the watch yet"
    }

    /// "Lytt fra klokken: spiller tonen" / "Listen from the watch: playing the tone".
    static func watchTell(_ status: String, _ language: StoryLanguage) -> String {
        "\(language == .norwegian ? "Lytt fra klokken" : "Listen from the watch"): \(status.lowercased())"
    }

    // MARK: Live Activity

    static func activitiesOff(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Direkteaktiviteter er slått av" : "Live Activities are turned off"
    }

    static func activitiesOffDetail(_ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Direkteaktiviteter er slått av i Innstillinger"
            : "Live Activities are turned off in Settings"
    }

    static func activityHeadline(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Gåmodus" : "Walking"
    }

    static func activityBody(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Sjekk av direkteaktivitet" : "Live Activity check"
    }

    static func activityStartFailed(_ description: String, _ language: StoryLanguage) -> String {
        "\(language == .norwegian ? "Kunne ikke starte" : "Could not start"): \(description)"
    }

    static func activityError(_ description: String, _ language: StoryLanguage) -> String {
        "\(language == .norwegian ? "Feil i direkteaktivitet" : "Live Activity error"): \(description)"
    }

    /// "Startet. Lås telefonen; den oppdateres om 60 s." and, without the location run, the hint to start it first.
    static func activityStarted(updateInS seconds: Int, locationRunning: Bool, _ language: StoryLanguage) -> String {
        if language == .norwegian {
            let hint = locationRunning ? "" : " Start posisjon i bakgrunnen først, ellers kan appen bli satt på pause."
            return "Startet. Lås telefonen; den oppdateres om \(seconds) s.\(hint)"
        }
        let hint = locationRunning ? "" : " Start Background location first, or the app may be suspended."
        return "Started. Lock the phone; it updates in \(seconds) s.\(hint)"
    }

    static func ended(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Avsluttet" : "Ended"
    }

    static func updatedFromBackgroundHeadline(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Oppdatert fra bakgrunnen" : "Updated from background"
    }

    static func updateSentFromBackground(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Oppdatering sendt fra bakgrunnen" : "Update sent from background"
    }

    static func updatedInForeground(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Oppdatert, i forgrunnen" : "Updated, in the foreground"
    }

    static func updatedInForegroundDetail(_ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Oppdatert, men appen var i forgrunnen – lås telefonen og prøv igjen"
            : "Updated, but the app was in the foreground — lock the phone and try again"
    }

    static func updateFailed(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Oppdateringen feilet" : "Update failed"
    }

    static func activityGone(_ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Aktiviteten var ikke lenger aktiv ved oppdateringen"
            : "The activity was no longer active at the update"
    }
}
