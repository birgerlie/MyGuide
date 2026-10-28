# MyGuide: «Hva ser du på?» — design foundation, quick feedback and speed

**Status:** agreed in chat 2026-10-28/29. Items marked *(Claude's call)* are open for the owner to change.
**Part 1 of 3** of the redesign that follows the owner's design package (`docs/design/`). Part 2 is the diary, part 3 the map with tours (separate designs). The order is the owner's.

## 1. Why

Owner, 2026-10-28:
- The photo flow "funket ganske fint, det eneste er at det tar litt tid".
- "kanskje teksten burde komme asynkront i forhold til tale og at vi kanskje kan skru av tale".
- "vi burde ha noe form for tilbakemelding kjapt", and "hastighet er viktig".
- "vi kunne kanskje ha en prosess som hentet inn hva som er i nærheten hele tiden så dette var på telefonen med en gang", including "når appen er lukket også".
- On that last point: "det er jo ikke sikkert at vi tar bilde av det som er i cache".

Today the text already appears before the speech. The wait comes before the text, from three steps run one after another:
1. the place search (Overpass, Wikipedia and the geocoder, run together; Apple Maps alongside);
2. the article text;
3. the model writing the whole story.

Nothing is shown until all three are done, apart from a spinner.

## 2. Goals, non-goals, anti-goals

**Goals**
1. Feedback within about a second of the shutter, then visible progress: what the app is doing, and the likely place as soon as it is known.
2. A shorter time to the first words of the story.
3. Speech can be switched off. Text is never held back for speech.
4. The camera and story screens, and the app's colours and type, follow the design package.
5. Measured timings, so the gains can be seen.

**Non-goals (this part)**
- The diary and the map (parts 2 and 3).
- The AR mode on the concept board.
- Changing which model is used.
- A tab bar. The home screen stays as it is, apart from colours and type.

**Anti-goals**
- Showing a cached guess as if it were the answer. A guess is always marked as a guess until the story confirms it.
- Getting faster by being wrong more often. An "unsure" identification stays honest, as today.
- A background process that drains the battery or hammers OpenStreetMap or Wikipedia.

## 3. Constraints

- Swift 6 strict concurrency, iOS 26. Pure logic goes in `MyGuideCore` with Swift Testing. No new package dependencies.
- The guide-voice prompt and honesty rules stay. The prompt's system instructions stay one constant (prompt caching).
- OpenStreetMap and Wikipedia usage policies: identifying User-Agent, no polling, caching.
- Background location requires Always. Without Always everything still works, only without the background refresh.
- App Store: background location must be clearly justified in the purpose string.
- Design package (`docs/design/designretningslinjer.txt`):
  - colours: forest green #123D38, ivory #FFF8E9, coral #EC795D, stone #DDD8CD;
  - type: Playfair Display Semibold for headings, Inter for UI, the system font on the watch;
  - sizes: body 17 pt, secondary text at least 13 pt, headings 28–34 pt;
  - Dynamic Type supported;
  - touch targets at least 44 × 44 pt;
  - no white text on coral at small sizes.

## 4. Design foundation

- One `Theme` in the app target holds:
  - the four colours as named colours with dark-mode variants (*Claude's call*: in dark mode the background is forest green and the text ivory);
  - fonts registered at launch;
  - text styles `display` (Playfair Display Semibold, scales from 34 pt), `title` (28 pt), `body` (Inter 17 pt), `caption` (Inter 13 pt). All of them scale with Dynamic Type via `relativeTo:`.
- **Fonts:** Playfair Display and Inter are both under the SIL Open Font License, so they may be bundled. *(Claude's call:)* the font files are fetched from the official Google Fonts GitHub repository after the owner approves the download. The licence text goes in the app and in the repo.
- **Buttons:**
  - primary: forest green with ivory text, or coral with forest-green text;
  - secondary: stone.
  - All at least 44 pt high, with 16–20 pt corners.
- **Spacing:** an 8-point rhythm and 16–24 pt side margins.
- The whole app picks up the colours and type through the theme. Only the camera and story screens get new layouts in this part.

## 5. Camera screen «Hva ser du på?»

- The camera preview fills the screen, as today, with the design package's overlay:
  - the heading "Hva ser du på?" (Norwegian story language) or "What are you looking at?" (English), in `display`;
  - focus corners;
  - the shutter;
  - the library picker;
  - a primary button "Finn stedet" / "Find the place", which takes the photo, same as the shutter.
- The position/heading HUD stays as a small, quiet line *(Claude's call: it builds trust in what is sent)*.
- UI language follows the story language setting for these new texts. *(Claude's call: the app has no localisation yet, so only the new screen texts get both languages.)*
- Pinch to zoom stays.

## 6. Quick feedback after the shutter

The story screen opens at once and shows steps in order. Each step replaces the previous one, with no spinner without words:
1. "Finner stedet …" / "Finding the place …": at once.
2. **The likely place:** a place card (name, direction, distance, "Lytt" disabled until the story exists), marked as a guess:
   - "Kanskje: Pantheon · 120 m mot nordøst" (Norwegian);
   - "Maybe: Pantheon · 120 m north-east" (English).
   It comes from the nearby list (section 7) as soon as a candidate in the field of view is found. With no candidate the step is skipped.
3. "Skriver fortellingen …" / "Writing the story …": when the model request starts.
4. **The story streams in** (section 8). When the model's identification arrives, the card drops "Kanskje"/"Maybe" for "certain" and "likely". For "unsure" it shows "Jeg er ikke sikker på hvilket sted dette er." / "I'm not sure which place this is.", as the design guidelines say.

## 7. The nearby list

**One shared list of places near the owner**, used by the camera and by walking mode (`PlaceFeed` today).

**Contents:**
- candidates from OpenStreetMap and Wikipedia (the walking source, 500 m radius), with tiers;
- article texts for the nearest important places: the 5 nearest of tier top or good *(Claude's call)*, through the existing `ArticleTextCache`.

**Stored on disk** (Application Support, JSON), with the centre and the time:
- usable as a starting point after a restart;
- as a fallback when a fetch fails.

**Refreshed when:**
1. The app is in the foreground with a fix at least 150 m from the list's centre *(Claude's call)*, and no more often than once a minute.
2. Walking mode is on: as today, at 250 m.
3. **The app is closed** (the owner's wish):
   - through the significant-location-change service, which wakes the app roughly every 500 m;
   - only when location is Always and the setting is on;
   - the fetch has a 20 s limit *(Claude's call)*;
   - a failure is logged and dropped.

**Setting:** "Forbered steder i bakgrunnen" / "Prepare places in the background". It is on by default when Always is granted *(Claude's call)*.

**Usage policy:** at most one Overpass and one Wikipedia geosearch per refresh, plus at most 5 article texts. They are cached, and refreshes never come more often than the rules above.

### 7.1 Using the list when a photo is taken (owner: "det er jo ikke sikkert at vi tar bilde av det som er i cache")

- At the shutter, two things start at once:
  - **(a) from the list:** rank its candidates against the photo's position and heading with the existing `CandidateRanker`. The best one in view gives the step-2 card;
  - **(b) a fresh place search**, as today.
- **Which candidates go to the model:**
  - the list is "fresh" when it is at most 10 minutes old and its centre is within 100 m of the photo's position *(Claude's call)*;
  - when fresh, the model request starts with the list's candidates without waiting for (b). The article text for the top candidate comes from the cache when it is there;
  - otherwise the model request waits for (b), as today.
  - Either way (b) refreshes the list.
- **When the model answers "unsure" from a fresh list:** if (b) found candidates in view that the list lacked, the story screen offers "Prøv igjen med flere steder" / "Try again with more places".
  - It is a button, not an automatic retry *(Claude's call: a second model call costs money)*.
  - It reruns the story with (b)'s candidates.

## 8. Streaming the story

- The model request uses the Responses API's streaming mode (`stream: true`, server-sent events), with the same strict JSON schema and `store: false`.
- **Schema order:** `story` becomes the *last* property of the first-story schema, so the identification fields arrive before the story text.
- **Partial parsing:** a tolerant parser in core:
  - reads the identification fields as soon as their values are complete;
  - reads the growing `story` string, unescaping JSON as it goes.
- **Display:**
  - the story text is shown as it grows, at most every 100 ms *(Claude's call)*;
  - the final text is the complete decoded response, checked exactly as today: an empty story is malformed, and an invented candidate id is dropped.
- **Continuation levels ("Mer")** stream the same way.
- **Usage:** recorded from the final usage event.
- **Failure:** a stream that breaks before completion counts as a failed request, as today. A partial text is not kept.

## 9. Speech

- Setting "Les opp automatisk" / "Read aloud automatically" is on by default *(Claude's call: today's behaviour)*.
- **On:** speech is requested when the story text is complete, never earlier, and plays as today.
- **Off:** no speech is requested. The story screen shows a "Lytt" / "Listen" button, which fetches and plays the speech.
- Walking mode follows its own settings and is not changed by this.

## 10. Timings

- Each photo story records, in milliseconds:
  - shutter to the first feedback step;
  - shutter to the likely-place card (or none);
  - place search;
  - article text;
  - model request start to the first story characters;
  - model request start to completion;
  - speech request;
  - whether the list was fresh, and its age.
- **Stored:** a JSON Lines file, `PhotoTimings.jsonl` in Application Support, using the walk log's writer. It keeps the newest 500 entries *(Claude's call)*.
- **Shown:** a small "Story timings" screen in Settings, listing the median and the last 20 *(Claude's call)*.
- **No story text and no photo** in the timings.

## 11. Failure behaviour

- No list, or a stale one: everything works as today, only without step 2 and the head start.
- Background refresh refused (no Always), or the setting off: the list refreshes only in the foreground and in walking mode.
- A stream error: the existing failure screen.
- Fonts that fail to register: the system fonts are used, and the failure is logged.

## 12. Left to the builder

- Exact layouts, animations and symbols within the design package.
- The partial-JSON parser's internals, within section 8.
- The file layout of the nearby list.

## 13. Device checks after install

1. Open the camera and take a photo of a known sight. The card "Kanskje: …" appears within about a second, and the story starts streaming within a few seconds.
2. With "Les opp automatisk" off, no speech plays; "Lytt" fetches and plays it.
3. Close the app, walk about 1 km, and reopen the camera. The list is fresh, as the timings screen shows (fresh, age).
4. Turn off the network and take a photo. The failure is honest, and the card from the list still says "Kanskje".
5. Compare the median timings before and after.

## 14. Settled during the builder check *(Claude's calls unless marked)*

1. **Schema key order.**
   - `JSONValue.object` is a Swift dictionary, so key order is lost today and varies per launch.
   - Add an ordered object form (or a raw JSON literal) for the response schemas, so `story` is reliably last.
   - The schema must be byte-identical across launches, so it can't break the prompt cache.
2. **The nearby list keeps every candidate**, without the tier filter.
   - It is the merged OpenStreetMap and Wikipedia candidates, with the tags.
   - Walking mode computes tiers from it, as `WalkingPlaceSource` does today.
   - The photo flow ranks it directly with `CandidateRanker` (coordinate, heading, field of view).
   - Radius: 500 m for both sources. A list is "fresh" for photo use when it is at most 10 minutes old and its centre is within **250 m** of the photo, because the OSM photo radius is 250 m and the list's 500 m covers it.
3. **Address and Apple Maps places on the fresh path.**
   - The geocoder and the Apple Maps search start at the shutter, alongside.
   - On the fresh path the model request waits for them at most **1.5 s**, then goes without whatever has not arrived.
   - The address is never cached.
4. **The fresh search (b) does not write into the list.**
   - It stays the photo's own 250/400 m search.
   - When the list is stale, the shutter also starts a normal list refresh.
5. **Background wakes.**
   - On each significant-change wake the app asks for one accurate fix (`requestLocation`) before fetching.
   - Device check 3 becomes: "the list exists, with its age and its distance from you shown in the timings screen".
6. **Background time.**
   - The fetch runs under `beginBackgroundTask`, with a 25 s cap.
   - A fetch that is not done in time is dropped.
   - On a launch with the location key, the app delegate starts monitoring again with its own location manager. The fetch path does not depend on any screen.
   - Monitoring also continues after the owner swipes the app away, as far as iOS relaunches for significant changes. Not guaranteed; device check.
7. **Driving guard.**
   - A background refresh is skipped when the fix speed is above 8 m/s, or within 10 minutes of the last one.
   - The Overpass request keeps its existing timeout.
8. **Article text in the first story** (decision in 15).
   - The article text is stored in the list file with the candidates, not only in `ArticleTextCache`'s memory.
   - At most 5 texts are stored.
9. **Streaming plumbing.**
   - `HTTPClient` gets a byte-stream method, with a test double.
   - Events are handled per the Responses API:
     - `response.output_text.delta`: JSON fragments go to the partial parser;
     - `response.completed`: final text and `usage`;
     - `response.failed`, `response.incomplete`, `error` and refusals: failure.
   - A non-2xx status reads the error body from the stream for the existing error mapping.
   - Reasoning effort stays "low". The timings show how much reasoning delays the first words before any change.
10. **Story screen states.**
    - The states are finding, guess, writing (a partial identification plus partial text), showing and failed.
    - The partial identification checks `matchedCandidateID` against the candidates the request used, so "certain" never shows and then drops.
    - If the match differs from the guess, the card shows the matched candidate, or the model's `subject` when there is no match.
    - "Prøv igjen med flere steder" appears only after the fresh search has finished. It reuses that search's candidates.
11. **Speech off** applies to every level, including "Mer". The background task ends when the text is complete.
12. **Timings file.**
    - A generic JSON Lines appender, shared with the walk log's writer code.
    - Trimmed to the newest 500 lines at launch.
13. **Fonts** (decision in 15). Static font files, registered with `UIAppFonts`. The watch and widget keep the system fonts.
14. **One list owner.**
    - A `NearbyPlaces` actor owns the list, merges simultaneous refresh requests and is keyed by story language.
    - Walking mode, the camera and background wakes all ask it.
    - Foreground fixes come from the camera's `LocationProvider` while the camera is open, from walking mode while it runs, and from the background service. There is no extra always-on GPS.
15. **Smaller points.**
    - The Always purpose string is rewritten to cover the background list.
    - Turning the "Prepare places in the background" setting on asks for Always when it is missing.
    - Library photos have no heading, so they never get a guess card.
    - The old "Looking around…" text is replaced by the bilingual steps.
