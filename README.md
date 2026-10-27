# MyGuide

An iOS and Apple Watch city guide that tells short, people-first stories about where you are and what you're looking at.

- Take a photo; the app uses the photo plus your GPS position and heading to tell the story behind it.
- Walk with it on; your watch taps when you pass a historic site or a hidden story.
- Plan scenic walks through small streets and piazzas instead of the fastest route, or themed loops by time.

Status: phase 1 (photo story) is implemented and in device testing. See `docs/`.

## Run it on your iPhone

1. Install Xcode.
2. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set the team ID.
3. Open `MyGuide.xcodeproj` and plug in the iPhone.
4. On the phone, turn on Developer Mode (Settings → Privacy & Security → Developer Mode, then restart). iOS requires this the first time Xcode runs an app.
5. Press Run in Xcode.
6. On the phone, trust the developer in Settings → General → VPN & Device Management.
7. Re-run from Xcode every 7 days (free account).
8. Check that the phone runs iOS 26 or newer (Settings → General → About).

## Walking mode

Walking mode follows you with the phone locked and buzzes when you pass something worth a story. It is built so far as buzzes with Tell me, More and Skip, a buzz log, a buzzes-per-hour setting and auto-off. The stop story (a story when you stand still) and the watch app follow in later steps.

- **Start it:** on the camera screen, tap the walking-figure button (it turns yellow while walking mode runs). Tap it again to stop. An OpenAI API key must be saved in Settings first.
- **Location "Always":** iOS first asks for "While Using"; allow "Always" when it offers the upgrade, or walking mode stops following you when the phone is locked.
- **Time Sensitive notifications:** turn them on for MyGuide (Settings → Notifications → MyGuide), or buzzes can be held back by a Focus.
- **A buzz:** a notification with the place name. Tell me plays the short story in your headphones, More continues to the next level, Skip drops the place for good. Tapping the notification opens the story in the app.
- **Buzzes per hour:** Settings → Walking, 5 to 60 in steps of 5 (default 20). A change also applies during a walk.
- **Buzz log:** Settings → Walking → Buzz log shows counts per kind of place and the newest 200 buzzes with how each ended (heard, skipped, ignored). The share button exports all of them as `MyGuide-buzz-log.csv` (`time,place,kind,tier,distance_m,outcome,level`; times in UTC).
- **Auto-off:** walking mode turns itself off after 4 hours or when the battery drops below 15%, and sends a notification saying why.
- **Watch:** the watch is reached through notifications mirrored from the phone; the watch app itself comes later.

## License

MIT
