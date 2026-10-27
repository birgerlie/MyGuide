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

## License

MIT
