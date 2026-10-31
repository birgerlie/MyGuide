# MyGuide: design

Date: 2026-10-26
Status: draft for owner approval

## 1. Intent and the why

MyGuide is a native iPhone and Apple Watch app that acts as a personal city guide in any city. It tells short, people-first stories about where you are and what you are looking at.

The need comes from real trips (Vienna, Rome). The owner kept photographing buildings and sending the photos to ChatGPT to ask what they were. That worked, but the answers ignored where the owner was standing. A photo of "a baroque dome" is ambiguous. A photo taken on Michaelerplatz facing north-west is not.

So the core idea is: **photo + exact position + compass heading + real map data about the spot → a short, true, human story**, spoken and shown as text.

The best human guides tell stories about people, not dates and buildings, and they paint how a place was back then. That is the voice the app aims for.

## 2. Who it is for

- **Now:** the owner only, on their own iPhone and Apple Watch Ultra 1, using their own OpenAI API key.
- **Later, maybe:** the App Store. Nothing in v1 should block that, but v1 does not build for it. There is no server, no accounts and no billing in v1.
- The owner has never built an iOS app. Claude writes all the code. The owner installs Xcode, connects the phone and presses Run.
- The code is open source: https://github.com/birgerlie/MyGuide (MIT).

## 3. Goals

1. **Photo story (first build, top priority).** Take a photo and get a story about what is in it, grounded in where you are and which way you face.
2. **Walking mode.** While walking, the watch taps when you pass a historic site or a place with a hidden story. Each place buzzes once.
3. **Stop detection.** When you stop for about a minute, the app prepares a text story about the spot and nearby places. It is waiting when you pick up the phone.
4. **Scenic routing.** Walk from A to B through small old streets, pedestrian lanes and piazzas, past historic sites, within a maximum detour (e.g. 25% longer than the fastest route).
5. **Themed walks.** A theme (Roman, medieval, Renaissance and baroque, food history, best-of) shapes which places count, which streets the route prefers and which angle stories take. A themed walk is either a journey to a destination or a loop from your position with a time budget (30 min, 1 h, 2 h ...).
6. **Memory.** The app remembers every place and story it has told, across trips, and never repeats itself. "Tell me more" about a known place gives a new angle.
7. **Restaurant search on request.** "Good restaurants near me" as a separate search. Never pushed during walks.
8. **"Then" images.** On request, an AI-generated image of the current spot in a past era.

## 4. Non-goals (for now)

- App Store release, a backend server, user accounts, payments.
- Android or any non-Apple platform.
- Offline use. The app needs mobile data.
- Social features, sharing, reviews.
- Restaurant, shop or café recommendations as points of interest during walks.

## 5. Anti-goals: failure even if it technically works

- **Made-up history presented as fact.** The worst outcome. Legend and uncertainty must be labelled ("legend has it ..."). Prefer a less colourful true story over an invented one.
- **Nagging.** Repeating the same place or story, or buzzing every 30 metres in a dense old town.
- **Invented details.** Names, dates, numbers or quotes the facts do not carry; a detail stated with confidence that belongs to a similar building elsewhere.
- **Scene painting as the content.** "Imagine the smell of …" instead of points the listener can see and check.
- **Tour-guide filler.** Greetings, "welcome to", restating the address back to the listener.
- **Text written for the eye.** Lists, headings or emojis in a story that is read aloud.
- **Padding a dull spot.** Filling it instead of pointing to something nearby worth the detour, or staying silent.
- **Repeating a point** the listener heard earlier the same day.
- **Commercial noise.** Shops and restaurants interrupting a walk.
- **AI images passing as real photos.** Every generated image is clearly labelled as an AI reconstruction.

## 6. Decisions the owner made

| Topic | Decision |
|---|---|
| Platform | Native Swift app for iPhone with an Apple Watch companion |
| AI provider | **OpenAI for everything** (vision, text, speech, images): one provider, predictable cost |
| Distribution | Personal use first; free Apple developer account until the app works, then possibly the paid $99/year account |
| Source | Public open-source GitHub repo under the owner's personal account, MIT license |
| Story output | Spoken audio **and** text on screen |
| Story lengths | By story kind, level and place tier (guide-voice design, section 5): app-triggered first level (walking buzz, stop story) **75 / 60 / 40 words** for tier 1 / 2 / 3 or none, **2–3 points**; stop stories at most **50**, and **40** when they only point to a place worth the detour; a buzz about a place with no facts gets **40**; owner-triggered (photo first level, any "tell me more") **200 words**, **3–4 points**; "even more" **300 words**, as many points as the facts carry. Word counts assume ≈150 spoken words per minute. |
| Story style | Private guide: most striking thing first, specific checkable points across history, architecture, food and science, one nudge at the end; see the guide-voice design (`2026-10-28-guide-voice-design.md`) |
| Language | English by default; Norwegian as a setting |
| Walking buzzes | Famous historic sites and hidden stories only; never shops or restaurants |
| Restaurants | Separate on-request search in the vicinity |
| Phone pickup | When the phone is picked up after a stop, a text story about the spot should be there |
| Detour | A max-detour-percent setting for routes (e.g. 25%) |
| Themes | Food, Roman, medieval, baroque, etc. Usable both for routes to a destination and for timed loops |
| Loops | Owner gives a duration (e.g. 30 min or 2 h); app plans a round trip |
| Memory | Track where the owner has been and what was told, so the app does not repeat itself |
| First build | The photo story with GPS |

## 7. Constraints and known platform facts

- **Watch is an Apple Watch Ultra 1.** It does not support the finger double-tap gesture (that needs the S9 chip: Series 9, Ultra 2 and newer). "Tell me more" from the watch uses the **Action button** instead, through a Shortcut that runs an App Intent exposed by the app. A tap on the watch screen is the fallback. *To verify early:* that a third-party App Intent can be bound to the Ultra 1 Action button via Shortcuts, and that it can trigger audio playback (on the watch, or on the phone via WatchConnectivity into AirPods).
- **iOS cannot react to the phone being unlocked.** "Story ready when I pick up the phone" is implemented as a background-prepared story shown on the lock screen. One tap opens the full story.
- **A Live Activity cannot be started from the background without a push server**, and v1 has no server. So the Live Activity is started when the owner switches walking mode on (app in the foreground) and is *updated* from the background when a stop is detected; updates are allowed while background location runs. If that turns out not to work, the fallback is a time-sensitive local notification. That fallback is the realistic baseline; the Live Activity is the upgrade.
- **Apple Maps cannot do custom-weighted walking routes.** It only returns its own routes. Scenic routing therefore uses OpenStreetMap data and a routing engine that supports custom preferences (GraphHopper custom models or Valhalla pedestrian costing). The route is drawn on an Apple MapKit map.
- **Free Apple developer account:** apps installed from Xcode expire after 7 days and must be re-run from Xcode. Some capabilities may be unavailable on a free "Personal Team". *To verify per phase:* Live Activities / widget extension, App Groups, background location, watch companion app. Anything blocked waits for the paid account; the rest ships first.
- **Verify before any feature work in phase 1:** a minimal app signed with the free Personal Team installs and runs on the owner's iPhone with camera, location ("when in use") and Keychain access, and can save to a local SwiftData store. This is step 0 of phase 1.
- **API key handling.** The OpenAI key is entered once in the app's settings and stored in the iOS Keychain. It is never in source code. The repo is public, and `.gitignore` already excludes `Secrets.xcconfig`, `.env` and `*.secrets`.
- **Privacy.** Photos and precise location are sent to OpenAI (and location to OSM/Wikipedia services). Acceptable for personal use. Must be revisited before any App Store release.
- **Battery.** Walking mode uses continuous location. It is something you switch on, not always running.

## 8. How it works

### 8.1 Photo story (phase 1)

1. Owner opens the app and takes a photo with the in-app camera (or picks a recent photo; location/heading then come from the photo's metadata if present).
   - Library photos often carry GPS but no direction, and sometimes neither. Without a heading, the app grounds on position alone (all candidates within the search radius, nearest first) and tells the model the heading is unknown, so it identifies the subject more cautiously. Without a position, the app says it cannot ground the photo and offers to use the current position instead; it does not silently tell an ungrounded story.
   - The in-app camera has pinch-to-zoom (1× to 5×, main lens) so the owner can frame just the detail that matters; tapping the zoom label returns to 1×. Zoom narrows the camera's field of view, and the field-of-view cone below uses the zoomed value, computed from the zoom the photo was actually taken at *(Claude's call)*.
2. At capture, the app records GPS coordinates, horizontal accuracy, compass heading, **heading accuracy** and time.
3. The app gathers grounding context for the spot:
   - nearby named historic places and buildings from OpenStreetMap, with emphasis on those within the camera's field of view given the heading. Compass readings in old towns are often disturbed by stone, steel and tram lines, so the field-of-view cone widens with the reported heading accuracy (the cone is the camera's horizontal field of view plus twice the heading accuracy on each side). If heading accuracy is unavailable or worse than 45°, the heading is treated as unknown. Exception: EXIF headings in library photos never carry an accuracy, so they are given an assumed accuracy of 20° *(Claude's call)*;
   - nearby Wikipedia articles (geosearch) with their short summaries, in the story language where available;
   - the reverse-geocoded street, square and city.
4. One OpenAI vision request receives the photo, the position, the heading, the candidate places and their summaries, the story language, the active theme (if any) and the list of stories already told about these places. It must:
   - identify what is in the photo, preferring candidates that match position and heading;
   - say plainly when it is unsure what the subject is;
   - write the first story (about **75 words**, what it is and why it matters first; guide-voice design, amendment 2026-10-31) in the style rules of section 6, labelling legend and uncertainty.
5. The story appears as text immediately and is spoken with OpenAI text-to-speech. Audio plays through the phone speaker or connected AirPods.
6. "Tell me more" generates the second level (about **200 words**); "even more" generates the third (about **300 words**). Each level continues the previous one rather than restarting, and avoids what has been said before.
7. "Show me how it looked" generates a labelled AI reconstruction image of the scene in the relevant era.
8. The story, photo thumbnail, place, position and time are saved to memory.

### 8.2 Memory

- A local, on-device store of: places visited, stories told (all levels, full text), photos taken, walked tracks.
- Every AI story request includes a compact summary of what was already told about that place, so new requests take a new angle.
- Memory records per place: buzzed (with time), heard, and the deepest story level heard.
- A place buzzes at most once per trip. It is retired for good only once a story about it has been heard. An ignored buzz does not retire it. *(Claude's call.)*
- **Trip definition:** a new trip starts when the owner uses the app in a different city than the current trip (city from reverse geocoding), or after 3 or more days without any app use in the same city. *(Claude's call.)*
- Side effect: a trip diary. A map of where the owner walked and what they heard. *(Claude's addition; low cost because the data exists anyway.)*

### 8.3 Walking mode (phase 2)

- Switched on manually. Uses background location.
- Points of interest come from OSM historic/tourism tags plus Wikipedia geosearch, filtered to exclude shops, restaurants and cafés, and filtered by the active theme.
- On approaching a not-yet-told point of interest, the watch plays a distinct haptic and shows a short title with direction and distance ("Where Caesar was stabbed, 50 m left").
- Action button (via Shortcut) or a tap starts the short first-level story (40–75 words by place tier, section 6 "Story lengths") in the owner's AirPods; pressing again continues to the next level.
- Rate limit so dense areas do not cause constant buzzing.
- **Stop detection:** when the owner has been stationary for about a minute, the app prepares a text story about the spot and noteworthy places nearby (with a suggestion to divert past them if they are close) and posts it to the lock screen: by updating the Live Activity started with walking mode, or by a time-sensitive notification (see section 7).

### 8.4 Scenic routing (phase 3)

- Input: destination, optional theme, max detour percent (default 25%).
- The routing engine prefers pedestrian streets, living streets, footways, alleys and squares, and penalises primary/secondary/trunk roads.
- Within the detour budget, the route passes as many relevant historic places as fit.
- Shown on an Apple map with the places marked. Walking mode runs along the route automatically.

### 8.5 Themes and loops (phase 4)

- Themes at launch: Roman, medieval, Renaissance and baroque, food history, best-of (no theme).
- A theme filters which places count, adds routing preference for matching places, and steers story angle (under "food history", the Pantheon story is about Roman festival food, not the dome).
- **Journey:** destination + theme → themed scenic route.
- **Loop:** duration + theme → round trip from the current position. The duration includes short listening stops at each place, not only walking time.
- If a theme does not fit the city (no Roman sites in Vienna's old town worth a loop), the app says so rather than padding the route.

### 8.6 Restaurant search (phase 5)

- On request only. Apple Maps (MapKit) local search finds restaurants near the current position. MapKit's public API has no ratings, so "good" is judged by an OpenAI request with web search over the nearby candidates. This keeps one provider. *(Claude's call.)*

## 9. Build phases

Each phase ends with something usable on the owner's phone.

1. **Photo story** on iPhone: camera, position and heading, OSM + Wikipedia grounding, three story levels, text + speech, English/Norwegian, memory, "then" image, settings with Keychain-stored API key, a simple running count of API usage and estimated cost. Built in steps, each running on the owner's phone before the next starts:
   0. Signing check (section 7): minimal app with camera, location, Keychain and SwiftData on the free Personal Team.
   1. Photo + position + heading + grounding + first-level story as text.
   2. Speech, and the "tell me more" / "even more" levels.
   3. Memory (stories told, places, photos) feeding back into requests.
   4. Norwegian setting, "then" image, usage and cost counter.
2. **Walking mode** with Apple Watch: background location, POI detection, haptics, Action button "tell me more", stop detection with lock-screen story.
3. **Scenic routing** to a destination with max detour.
4. **Themes and loops.**
5. **Restaurant search.**

Later and out of scope here: App Store release, server proxy for API keys, billing, offline packs.

## 10. Calls Claude made (owner may overrule)

- **Compass heading** is sent with the photo; it is what distinguishes the building in front from the one behind.
- **Grounding with OSM and Wikipedia** to reduce invented history, rather than relying on the AI's memory alone.
- **Each place buzzes at most once per trip and is retired once heard**, with a rate limit in dense areas; walking mode is switched on manually.
- **Trip diary** from memory data.
- **Loop duration includes listening stops.**
- **Restaurant quality via OpenAI web search** instead of a second provider with ratings.
- **Usage and cost counter** in settings, because predictable cost was the owner's reason for one provider.
- **Starter theme list** as in 8.5.
- **Warm, conversational voice**, "a friend who knows the city", not a museum audio guide.

## 11. Left to the builder

- Exact OpenAI model choices for vision/text, speech and images (pick current models at build time; keep the provider behind a small interface so models can be swapped).
- TTS voice choice; caching of generated audio.
- Which routing engine (GraphHopper vs Valhalla) and whether hosted or self-hosted, subject to: custom street-type preferences, a usable free tier or cheap hosting for one user, no API key in the repo.
- OSM access method (Overpass API or other) and caching strategy, respecting service usage policies.
- Local storage technology (e.g. SwiftData).
- Minimum iOS/watchOS version: the newest versions the owner's devices run, unless that blocks something.
- App icon and visual design, kept simple in phase 1.
