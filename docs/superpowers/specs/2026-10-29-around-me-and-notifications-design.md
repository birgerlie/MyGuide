# MyGuide: «Rundt deg» — what is around me, the selected place, and notifications that look like MyGuide

Status: draft for the owner's review (2026-10-29). Builds on the camera redesign (branch `camera-redesign`): `Theme`,
the bundled fonts, `NearbyPlaces`, `StoryText`, `StorySources` and the new photo story screen.

## 1. Why

The owner, in their words: when I open the app, the notification must be «pen og saklig», and I must see what is
around me. All notifications and everything else must follow the design package (`docs/design`).

Today:
- the home screen has no map, just a "latest story" card and buttons;
- walking notifications are plain English text ("50 m ahead", "Tell me", "Skip") with no image;
- tapping one opens `WalkStoryView`, which uses system fonts and none of the design;
- the Live Activity uses system fonts and shows only stop stories.

The owner also pasted a specification for direction-based selection of the nearest interesting place. It was
discussed and adjusted (section 6); the owner agreed: «jeg tror dette funker».

## 2. Goals, non-goals, anti-goals

**Goals**
1. Opening the app shows a calm, muted map of what is around the owner, with the place MyGuide would tell about
   marked, and a compact place card: picture, name, distance, direction, «Lytt».
2. Pointing the phone at something selects the nearest notify-worthy place in that direction, without jumping.
3. Walking notifications are well-written and factual: place name, distance and direction in the story language, one
   factual sentence, a picture when one exists, Norwegian actions «Lytt» / «Hopp over».
4. Every surface MyGuide draws follows the design package: the expanded notification, the Live Activity and Dynamic
   Island, the map screen, the place card and the walk story screen.

**Non-goals (this part)**
- Tour modes (loop with a duration; A→B with at most 25 % detour). They come later, on top of this map.
- Building outlines / nearest point on a large building's geometry (section 6.6: later step).
- Watch redesign beyond what it already has (the design package says system font on the watch).
- Instagram, sharing, payment.

**Anti-goals: it fails even if it works when**
- the card claims a direction the measurements cannot support (false precision);
- the selection flickers between places when the hand shakes;
- a story starts without the owner pressing «Lytt»;
- a notification says something the data does not say (no invented facts, no "beautiful 14th-century church" unless
  the source says so);
- the map is busy: full POI clutter, labels everywhere.

## 3. Constraints

- Swift 6 strict concurrency, iOS 26, SwiftUI, XcodeGen; pure logic in `MyGuideCore` with Swift Testing tests.
- Design package: ivory #FFF8E9 background, forest #123D38 text and ordinary markers, coral #EC795D for the selected
  place and the main button with **dark text on coral**, stone #DDD8CD for dividers; Playfair Display SemiBold for
  place headings, Inter for interface and body; 8 pt rhythm; 16–24 pt margins; 44 pt touch targets; colour never
  alone for status.
- **The system notification banner is drawn by iOS.** MyGuide decides only its text, its image attachment, its
  actions and its sound. Design applies fully where MyGuide draws: the expanded (long-press) notification through a
  Notification Content Extension, the Live Activity, and the app.
- Fonts are bundled in each target that draws text with them (app, widget extension, notification extension).
- No secrets in new targets: the notification extension and the widget never hold the API key.
- All new screen and notification texts come in both story languages (nb, en), like `ScreenText`.
- Battery: the compass/motion updates and the map run only while the map is on screen.
- `store: false` and the existing privacy rules are unchanged; no new third-party services. Wikipedia images come
  from Wikimedia (already a source).

## 4. The design rule for every surface

| Surface | Who draws it | What follows the design |
|---|---|---|
| Notification banner / lock screen | iOS | Text tone, image attachment, Norwegian/English actions |
| Expanded notification (long press) | MyGuide content extension | Everything: ivory card, Playfair name, Inter text, coral accent |
| Live Activity + Dynamic Island | MyGuide widget extension | Colours, fonts, layout |
| Map screen, place card, walk story, photo story | App | Everything |
| Watch | Watch app | Design colours; system font (design package) |

## 5. «Rundt deg» — the home screen becomes the map

**Layout (top to bottom)**
- No large page title. A slim top bar: diary, history, settings (as today's toolbar).
- **Map, the main surface.** MapKit, muted: Apple's own points of interest and most labels hidden, muted emphasis,
  no 3D. Shows:
  - the owner's position, with a **view cone** in the phone's direction when the heading is reliable (6.4);
    without a reliable heading, just the dot;
  - a small **compass** showing north;
  - **notify-worthy places only** (6.1) as small, discreet symbols by kind: building, church, monument/statue,
    fountain, park, museum, castle/fort, generic; forest green;
  - the **selected place in coral**, slightly larger.
- **Walking panel**, when walking mode is on (today's panel restyled): status, pause/stop.
- **Compact place card** at the bottom (6.5).
- **Bottom bar** as today: «Hva ser du på?» camera button (primary), photo picker, walking on/off.

The "latest story" card leaves the home screen; the diary and history hold the stories.
*(Claude's call: the owner wants to see what is around them on opening; one card competing with the map would undo
that. Cost if wrong: the card comes back under the map in one task.)*

**Data**: the shared `NearbyPlaces` list. The map screen asks it to refresh on its foreground rules (150 m / 60 s)
from the camera's `LocationProvider` fixes while the screen is visible. With no list yet: the map with the owner's
position and "Finner steder rundt deg …"; with no network: the last stored list, marked with its age when older than
10 minutes.

**Tapping** a marker selects that place explicitly (6.3). Tapping the card opens the place's story screen (section
8). «Lytt» tells and plays the place's first story without opening anything.

## 6. Selecting the place

### 6.1 Which places

The places walking mode may notify about: every candidate with a tier (`PlaceTiers.tier(for:)` — top, good,
wikiOnly). Distances from the owner's latitude/longitude. Nothing else is shown or selected.
*(Owner: «nærmeste sted i forhold til det vi vet basert på lat/long som vi vil gi varsel på».)*

### 6.2 The rule

Inputs: places, the owner's position and its accuracy, the phone's heading and its accuracy, the time, whether a
story is playing and for which place.

1. Distance and bearing to every place (`GeoMath`).
2. Angular offset between heading and bearing, wrapped to −180…180° (359° and 1° are 2° apart).
3. **Select** among places within **±30°**; **keep** the selected place while it is within **±40°**.
4. The nearest place inside the angle wins. A place outside the angle never wins by being nearer.
5. A new candidate must be the winner for **1.5 s** without a break before it replaces the selection. This holds
   for every change of the selected place, including between the in-angle and the fallback mode (rule 8). The very
   first selection, and an explicit tap, take effect at once.
6. "About equal distance" keeps the current selection: a challenger must be nearer by more than **15 % or 10 m**,
   whichever is larger.
7. When the selected place leaves ±40°, it loses its claim to stay; any challenger (in the angle, or the fallback
   of rule 8) replaces it after its 1.5 s. Meanwhile the card keeps it but its direction is recomputed on every
   update, so it never claims "foran deg" for a place no longer in front. *(Builder check: replaces "dropped at once",
   which left the card empty for 1.5 s against rule 8.)*
8. **No place within the angle:** the **nearest place regardless of direction** is selected, and the card says
   honestly where it is ("80 m bak deg til venstre"). *(Owner agreed to this change from the pasted text, which
   showed nothing.)* The map's coral marker and the card always change together.
9. **While a story plays** the selection is frozen on the playing place. Its card keeps updating distance and the
   relative direction live, so it may say "bak deg". An explicit tap on another marker still selects it (the story
   keeps playing until «Stopp» or a new «Lytt»).
10. Automatic selection never starts audio.

All numbers (±30°, ±40°, 1.5 s, 15 %, 10 m, the reliability limits in 6.4) live in one configuration value with these
defaults, adjustable later from testing.

### 6.3 Explicit selection

Tapping a marker selects it at once and pauses automatic selection for **20 s** or until the owner turns more than
**60°** from the heading at the tap, whichever comes first. *(Claude's call: otherwise the next heading update would
take the tapped place away immediately.)*

### 6.4 Heading and reliability

- **Phone heading**: from Core Motion device motion with the true-north reference frame: the azimuth of the
  horizontal projection of (top-edge vector + back vector). Held flat this is the top edge's direction (the back
  points at the ground); held upright it is the back camera's direction (the top points at the sky); in between both
  share the azimuth, so there is no switch and no jump. When that projection is shorter than 0.25 (phone rolled on
  its side), the heading counts as unreliable. Smoothed
  (circular exponential smoothing, time constant about 0.5 s, wrap-safe). Fallback when device motion is unavailable:
  `CLHeading` true heading.
- **Reliable** means: heading accuracy ≤ **25°** and position accuracy ≤ **50 m**.
- A **direction is stated** for a place only when it is also more than **twice the position accuracy** away (at
  20 m accuracy, places nearer than 40 m get no direction word).
- **Unreliable heading**: no view cone; rule 8 applies directly (nearest place), and the card shows distance without
  direction ("i nærheten · 40 m").
- **Unreliable position** (> 50 m): no selection; the map shows the places, the card says
  "Usikker posisjon" and offers «Ta et bilde».
- **Several places close together** (the two nearest within 15 m of each other and both within 40 m of the owner):
  the card adds «Ta et bilde» as a secondary action, since only a photo can tell them apart.

Phone in the pocket is walking mode's case and is unchanged: it already uses the GPS course, never the compass.

### 6.5 The place card

```
[picture]  Pantheon
           ↑ 50 m · foran deg
           ▶ Lytt
```

- Picture: the place's Wikipedia image (7.3) when there is one; otherwise none (no placeholder art).
- Name in Playfair; the arrow rotated to the relative direction (shown only when a direction is stated); distance
  rounded as walking mode rounds it (10 m steps).
- Relative direction words, from the offset (same bands as `GuideText.side`): foran deg (≤30°), foran til
  venstre/høyre (≤60°), til venstre/høyre for deg (≤120°), bak deg til venstre/høyre (≤150°), bak deg.
  English: ahead, ahead to the left/right, to your left/right, behind you to the left/right, behind you.
- «Lytt» in coral with dark text. While loading: spinner; while playing: «Stopp».
- No place selected (nothing in the list, or unreliable position): the card shows that state in words, never an old
  place.

## 7. Notifications

### 7.1 Text

| Part | Content | Example (nb) |
|---|---|---|
| Title | Place name | Pantheon |
| Subtitle | Distance and direction from the walking course; without a course, distance only | 50 m foran deg |
| Body | One factual sentence (7.2) | Romersk tempel fra rundt år 125, i dag kirke. |
| Actions | «Lytt», «Hopp over» (MORE: «Mer», «Hopp over») | |
| Image | Wikipedia image when one exists (7.3) | |

- The direction words are walking mode's (`BuzzText`) bands, translated: foran deg, til høyre, til venstre, bak
  deg; "50 m unna" without a course.
- Failure: title «Fikk ikke hentet fortellingen», the reason as body. MORE body: «Trykk Mer for neste del.».
  Auto-off and stop stories in the story language too.
- Interruption level, sound, thread and categories stay as today.

### 7.2 The factual sentence

From the place's own data, in this order; never written by a model at notification time and never invented:
1. the first sentence of the Wikipedia summary (`Candidate.summary`), when it is at most 140 characters; a longer
   first sentence is cut at a word boundary with "…";
2. otherwise a kind label from the OSM tags (a fixed table: Kirke, Museum, Minnesmerke, Statue, Fontene, Park,
   Slott, Festning, Tårn, Ruin, Historisk bygning, …), with the heritage or `start_date` tag when present
   ("Kirke · fra 1697");
3. otherwise no body line.

### 7.3 Pictures

- The Wikipedia page image of the place's article (`pageimages`, thumbnail about 600 px), fetched with the nearby
  list for the same top/good places that get article texts, plus its author and licence (`imageinfo` extmetadata).
- At buzz time the cached thumbnail is attached. If it is not cached yet, it is fetched with a **1.5 s** cap; past
  that the notification goes without a picture. A notification is never delayed longer.
- Credit ("Foto: <author>, <licence>, Wikimedia Commons") shows in the expanded notification, on the walk story
  screen and under «Kilder». The banner thumbnail has no room for it.
  *(Claude's call: attribution where there is room for it. Cost if wrong: the banner thumbnail goes, the expanded
  view keeps the picture.)*
- No picture: no attachment and no generated placeholder.

### 7.4 The expanded notification (Notification Content Extension)

A new extension target for categories BUZZ, MORE and STOP:
- ivory card, the picture on top (if any), «STED I NÆRHETEN», the name in Playfair, "↑ 50 m · foran deg", the
  factual sentence, the photo credit in caption size;
- the system action buttons «Lytt» / «Hopp over» stay (the extension does not play audio; the actions run in the
  app in the background as today);
- reads only the notification's `userInfo` and attachment; no network, no key, no shared store.

### 7.5 Live Activity and Dynamic Island

Restyled to the design: ivory/forest background following light and dark mode, Playfair for the place name, Inter
for text, coral for the active-audio and walking marks.
- Shows the latest buzzed or playing place: its name and its factual sentence (7.2), and the walking status. No
  distance: it would go stale between updates. Before the first buzz: «Gåmodus» and «Ser etter steder rundt deg».
- A buzz does not alert on the Live Activity (the notification already alerts); stop stories alert as today.
- Compact island: walking mark in coral and the place name shortened; minimal: walking mark.
- Stop stories as today, restyled.

## 8. The walk story screen

`WalkStoryView` gets the photo story screen's layout and components:
- hero: the place's Wikipedia image if there is one, else no hero (the sheet starts at the top);
- status label «STED I NÆRHETEN» (a stop story: «HER DU STOPPET»), the name in Playfair, the where-line with
  distance and relative direction (6.5 rules, from the position when the story was made);
- «KORT FORTELLING» and the levels with `StoryText`, deeper levels with their own label and Lytt;
- «Mer om …» and «Kilder» links (`StorySources` for the walk story's candidate, plus the photo credit);
- «Lytt til fortellingen» at the bottom; «Hopp over dette stedet» as a quiet link for buzz stories.

## 9. Acceptance criteria

1. With four places around the owner, the nearest within the current angle is selected.
2. A nearer place behind the owner is not selected while a place is within the angle.
3. When the owner turns clearly, the map's coral marker and the card change together after 1.5 s.
4. Small heading variations (±10° noise) cause no repeated switches.
5. 359° and 1° are treated as 2° apart.
6. Automatic selection never interrupts a playing story.
7. Without a reliable heading or position, no direction word appears.
8. No story starts before «Lytt» is pressed.
9. A notification for a place with a Wikipedia summary shows its name, "NN m <retning>", the first sentence and,
   when cached, the picture; the actions read «Lytt» and «Hopp over» in Norwegian.
10. A notification is never delayed more than 1.5 s by its picture.
11. The expanded notification, Live Activity, map screen and walk story screen use the design colours and fonts in
    light and dark mode.

## 10. Left to the builder

- Map styling details within section 5 (zoom level, marker sizes, cone length); the map follows the owner's heading
  only when they tap the compass/locate control.
- The kind-to-symbol table and the kind-label table (7.2), within the listed kinds.
- How the shared configuration is stored (a value type in core is enough; no settings screen in this part).
- Whether the picture cache lives with the nearby list's store or beside it.

## 11. Device checks after install

1. Stand in a square, turn slowly: the coral marker and the card follow after about 1.5 s; no flicker when still.
2. Indoors (poor GPS): no direction words, «Ta et bilde» offered.
3. Walk with the phone in the pocket: a notification with name, "NN m foran deg", a factual line, a picture;
   long-press shows the MyGuide card; «Lytt» plays without unlocking.
4. Lock screen during a walk: the Live Activity in the design.
5. Dark mode on all of the above.

## 12. Settled during the builder check *(Claude's calls)*

1. **«Lytt» or a tap on the map card for a place with no story yet.** A new "tell this place" entry in
   `WalkingStories`, reusing the walk-story pipeline with a new story kind for a place chosen on the map. It works
   with walking mode off, is saved as a walk story (shows in the diary), marks the place heard so walking mode will
   not buzz it later, and does not use the buzz budget. If a story for that place is already prepared (it was just
   buzzed), that story is used. *Cost if wrong: one story kind and its diary label.*
2. **One owner of audio.** `WalkingStories` owns playback of walk stories, and the map card reads from it which place
   is playing. A map «Lytt» stops whatever plays and plays its place. A buzz while the app is in the foreground makes
   the buzzed place the explicit selection (6.3), so the map and the notification agree.
3. **The 1.5 s gap.** Rules 5 and 7 are rewritten above: every change waits 1.5 s, the card keeps the old place with a
   live direction meanwhile, and the 15 % / 10 m rule applies in both modes.
4. **Heading flat versus upright.** One formula with no switch (6.4).
5. **Live Activity.** No live distance; no extra alert for a buzz; a waiting text before the first buzz (7.5).
6. **Pictures.**
   - Fetched ahead for the article-text places.
   - Fetched on demand, once, for a place selected on the map or buzzed without a cached picture. The 1.5 s cap
     applies only to notifications.
   - The image comes from the wiki in the candidate's `wikipediaTitle` prefix, or in its `wiki:<code>/` id.
   - Cached by that title, not by list language.
7. **A summary in another language.** The factual sentence is used only when the article's language is the story
   language. Otherwise it falls through to the kind label. No foreign-language line appears in a notification.
8. **Kinds that cannot occur.** Park and fountain leave the symbol and label tables; tiers and buzzing are unchanged.
   - A `heritage` tag alone gives «fredet» / «listed», as in "Kirke · fredet".
   - `start_date` is used only when it starts with a four-digit year: «fra 1697» / «from 1697».
9. **STOP and MORE expanded.**
   - STOP: «HER DU STOPPET», the story title in Playfair, the first two lines of its text. No distance or picture.
   - MORE: the BUZZ card with «NESTE DEL» as its label.
10. **Failure reasons.** A fixed set of translated categories: no network, the AI service failed, no API key, timed
    out, other. Each existing error maps to one of them.

## 13. Walking fixes from the Rome walk (owner, 2026-10-29)

The walk log of 29 Oct showed no notifications for two reasons:
- OpenStreetMap returned nothing and the failure was silent, so only 15 Wikipedia places of the lowest tier were found;
- every one of them was already heard, skipped or buzzed in the trip (which has lasted since 27 Oct).

The owner decided:

1. **30 days.** A place counts as used for 30 days after it was heard **or read**, or after it was skipped. After that it may buzz again. *(Owner: «30 dager er sikkert fint».)*
2. **Read counts.** Opening a walk story in the app counts as reading it, the same as hearing level 1. The expanded notification cannot write to the app's store, so it does not count. *(Owner: «varsel kan komme om jeg ikke har lest den».)*
3. **A buzz that was not read may come again.** The trip-wide "already buzzed" exclusion goes. Within one walking run, a buzzed place still does not buzz twice.
4. **No audio unless asked.** A notification never starts audio. Speech for a buzz is no longer made in advance: it is fetched when the owner presses «Lytt» / «Tell me». *(Owner: «trenger absolutt ikke å spille av lyd».)* Spec 12.1's chosen-place «Lytt» still plays at once after fetching.
5. **Reset button.** Settings → «Nullstill stedsvarsler» / «Reset place notifications», with a confirmation. It makes every place eligible again and deletes no stories, diary entries or buzz history. *(Owner: «lag en resett knapp … vi tester jo hele tiden».)*
6. **OpenStreetMap resilience.**
   - A failed OpenStreetMap request is logged even when Wikipedia answers.
   - A second endpoint is tried once on failure: `https://overpass.kumi.systems/api/interpreter`.
   - When both fail, the previous list's OpenStreetMap places are carried forward if that list is at most 7 days old and its centre is within 500 m.
7. **Honest status.** When the engine is quiet because every due place is used, the walking panel says «Du har hørt om alt i nærheten» / «You've heard about everything nearby».
8. **Lean towards more.** When a rule in this section is a judgement call, prefer more notifications over fewer; limits can be tightened later from walk logs. *(Owner: «bedre med for mye enn for lite i starten, vi kan heller begrense etterhvert».)* The tier rules are unchanged; widening them is not part of this section.

## 14. Landing page after the owner's sketch (2026-10-29)

The owner's sketch is `docs/design/landing-sketch.png`. It replaces the layout list in section 5. Data, selection
and card rules stay as written.

- **Map full screen.** A «MyGuide» pill in Playfair at the top left. Round compass (north) and locate buttons at
  the top right. The owner's dot with its view cone. Forest symbol markers. The selected place is a coral pin with
  its name in a small ivory label.
- **Camera button.** A large round coral button with a forest camera symbol at the bottom right of the map, with
  the label «Hva ser jeg på?» / «What am I looking at?» under it. It opens the camera.
- **Bottom sheet**, draggable, with a grabber, in ivory:
  - «Rundt deg» / «Around you» in Playfair;
  - the place card: picture on the left (none without one), the name in Playfair, «50 m · foran til høyre», and a
    round coral «Lytt» with a forest play symbol and the word under it;
  - a wide coral «Gå en tur» / «Go for a walk» button with a walking figure and a chevron, which starts walking
    mode. The line under it reads «Gå fritt, så forteller jeg om det du passerer» / «Walk freely and I'll tell you
    about what you pass». *(Claude's call: «velg en tematur» waits for tours.)*
  - While walking, the button's place shows the walking panel: status, pause, stop, and the «hørt om alt» line.
- **Tab bar:** «Utforsk» / «Explore» (map symbol) and «Dagbok» / «Diary» (book symbol). *(Claude's call: «Turer»
  comes with the tour modes; a dead tab is worse than none.)* History is reached from the diary. Settings moves to
  a gear in the diary's top bar.
- Parks and fountains are not shown (12.8). The map is MapKit muted and cannot look like the illustration's
  drawn trees; colours, symbols and the sheet follow the sketch.

## 15. Every screen in the design (owner, 2026-10-29)

Owner: «kan vi gå gjennom alle skjermbilder så de harmoniserer med selve design malen».

**Already covered by other parts:**
- Home and the walking panel: section 14.
- Walk story: section 8.
- Expanded notification and Live Activity: sections 7.4 and 7.5.
- Camera and photo story: done earlier.

**This section is a visual pass over the remaining screens:**
- Diary (`DiaryView`, `DiaryRows`, `DayStoryView`);
- History;
- Settings and its sub-screens (Story timings, Buzz log, Walk logs list and run);
- Self check;
- Walking check;
- Watch (`GuidedWalkView`, `WatchCheckView`).

**Rules:**
- Theme colour tokens and backgrounds in light and dark mode.
- Playfair for screen titles and place or story headings; Inter for body and interface.
- Section labels in spaced capitals, as on the story screen.
- Primary actions in forest, active audio in coral with forest text, secondary actions in stone.
- 8 pt rhythm, 16–24 pt margins, 44 pt targets.
- Status shown in words or symbols, never by colour alone.
- New and touched user-facing text comes in both story languages.
- The watch uses the design colours with the system font, as the design package says.

**Non-goals:** no new features and no changes to behaviour or data. The diary redesign (day pages, AI title,
«Del dagen») stays a separate project. Developer and diagnostic screens (logs, checks, timings) get the theme but
keep their dense layouts.

## 16. Additions from the owner's «Utforsk» developer spec (inspiration, 2026-10-29)

The owner shared a developer spec for the landing page "as inspiration". The following are adopted. Where this
section and earlier sections differ, this section wins, except rule 6.2.8, which stays.

1. **A tapped place is held until the owner taps the locate button.** Locate re-centres, resumes following and
   resumes automatic selection. This replaces the 20 s / 60° hold of 6.3.
2. **The map never re-centres while the owner pans or zooms by hand.** Locate re-centres and resumes following.
   Panning keeps the selection and any playing story.
3. **Expanded sheet:** nearby places sorted by distance, where a tap selects one. This list is also how VoiceOver
   reaches the markers. Under it, «Sist oppdaget» / «Recently discovered» shows the most recent stories from
   history, only when there are any.
4. **«Gå en tur»:**
   - The line under it reads «Få beskjed om interessante steder underveis» / «Get told about interesting places
     on the way» while there are no theme tours.
   - With a running or paused walk the button reads «Fortsett turen» / «Continue the walk», with the status
     under it, and opens the walk. It never starts a second walk.
5. **Camera button:** it moves up with the sheet and hides when there is no room. Accessibility label «Ta bilde
   for å identifisere et sted» / «Take a photo to identify a place».
6. **States:**

   | State | Norwegian | English | Action |
   |---|---|---|---|
   | Locating | Finner posisjonen din … | Finding your position … | — |
   | Location denied | Aktiver posisjon for å se steder rundt deg | Turn on location to see places around you | Open Settings |

   Poor accuracy shows an accuracy circle and no direction words. The camera stays available in every state.
7. **No picture:** the place kind's symbol on a stone square. This replaces "no picture" in 6.5.
8. **State is kept** across tab switches and a cancelled camera: map region, sheet height and selected place.
   Apple's map attribution stays visible above the sheet.
9. **Accessibility:**
   - VoiceOver does not announce compass changes or automatic re-selections.
   - Reduce Motion is respected.
   - The selected marker differs by size and label, not by colour alone.
10. **Deferred:**
    - Pause and resume within a story (the audio player has stop only).
    - The geometry of large places.
    - The choice sheet between free walk and theme tour, until tours exist.

## 17. Screen language follows the iPhone (owner, 2026-10-29)

Owner: «følg iphonens språk, ta det etter denne runden».

- **Screen texts follow the iPhone's language.** This covers the app, the notification texts and actions, the
  expanded card, the Live Activity and the watch. It goes through an Apple String Catalog
  (`Localizable.xcstrings`) with English (development language) and Norwegian Bokmål (`nb`). Every bilingual
  texts enum built so far moves into the catalog.
- **Any other iPhone language** falls back to English.
- **The story language stays a separate setting.** It decides the language of stories, prompts and Wikipedia.
  Its default on first launch is the iPhone language when that is Norwegian (`nb`, `no` or `nn`), and English
  otherwise. An explicit choice in Settings is kept.
- **Content texts follow the story language**, because they belong to the story: the factual line, the place
  kind labels, the walk story text and the photo credit wording.
- **Notification action titles and categories** follow the iPhone language and are registered at launch.
- **Order:** this is done after the current round (Task 14), before the whole-branch review.

## 18. A buzz reaches the watch during a guided walk (walk log 29 Oct 13:07–14:20)

**What the log shows:**
- Both buzzes were posted with every notification setting on: Horrea Galbae at 13:16:47 and Santa Maria
  Liberatrice at 13:16:56.
- The phone app was in the foreground from 13:16:34 to 13:16:49, so the iPhone was unlocked.
- iOS forwards an iPhone notification to the watch only when the iPhone is locked or asleep. That explains why
  no notification reached the watch. Even with the phone locked, a watch app that runs a workout and is in the
  foreground gets notifications for its own app through its notification delegate. The watch app has none, so
  they may not show. *(Uncertain; to verify on the device.)*
- OpenStreetMap failed on both endpoints again ("connection lost", "timed out"), so only 13 Wikipedia places
  were found.

**Decision** *(Claude's call, from the owner's report «jeg fikk ikke noe haptic eller notification på klokken»)*:
1. While a guided walk runs on the watch, the phone also sends each buzz straight to the watch over
   WatchConnectivity: `sendMessage` when reachable, otherwise `transferUserInfo`. The message carries the buzz id,
   the place name and the direction line.
2. The watch plays a notification haptic and shows the place in the guided walk view, with «Lytt», which sends
   the existing tell-me command to the phone.
3. The watch app gets a `UNUserNotificationCenter` delegate. It presents forwarded notifications while the app is
   frontmost, and skips one it has already shown through WatchConnectivity (same buzz id), so a buzz is felt once.
4. A third Overpass endpoint is added as a last fallback: `https://maps.mail.ru/osm/tools/overpass/api/interpreter`.
   The second endpoint's failure is logged with its error.

## 19. Ranking places without OpenStreetMap (walk logs 29 Oct 18:25–19:01 and 20:00–20:31)

Owner: «innimellom syntes jeg det var rart. spesielt når det var mange severdigheter virket det som den ikke helt
prioriterte riktig og den hoppet litt». Approved plan: «go» (2026-10-30).

**What the logs show:**
- OpenStreetMap failed on all 13 fetches, so every place was `wikiOnly` and nothing was ranked.
- The app already sends a descriptive User-Agent. Tested 30 Oct 08:00:
  - overpass-api.de answered a tiny query after 40 s; the app gives up after 12 s;
  - kumi, private.coffee, lz4/z mirrors, openstreetmap.ru and osm.jp timed out or refused;
  - mail.ru answered 504.

  Public Overpass cannot be relied on.
- Without tiers, the first place within 60 m wins. Wikipedia has articles about organisations placed at a
  building's coordinates:
  - «Jesuittordenen» and «Il Gesù» buzzed 5 s apart (same spot);
  - «École française de Rome» won over «Palazzo Farnese» by 4 m.
- The first fetch at 18:25 timed out. Places arrived 2.5 min later, after Palazzo Venezia and Piazza Venezia had
  been passed at 40–48 m. A failed fetch waits 60 s before the next try.
- The log does not record what the map showed, so «den hoppet» on the map cannot be checked.

**Decisions:**
1. **Wikidata facts.** Every candidate with a Wikidata id gets facts from one SPARQL request per 50 ids to
   `https://query.wikidata.org/sparql`, run as soon as the Wikipedia list is in (8 s timeout, same User-Agent).
   - **Sitelinks:** the number of Wikipedia language editions, used as importance.
   - **Class**, from `P31/P279*`:
     - `place`: subclass of architectural structure Q811979, square Q174782, park Q22698, archaeological site
       Q839954, monument Q4989906, work of art Q838948, or fountain Q483453;
     - `area`: street Q79007 (wins over place, since streets are structures in Wikidata), or neighbourhood
       Q123705 / administrative territorial entity Q56061 when it is not also a place (castles, city gates and
       walls reach Q56061 through odd subclass chains; final review 30 Oct);
     - `nonPlace`: organisation Q43229, human Q5, event Q1656682 or group of humans Q16334295, and none of the
       above;
     - `unknown`: none of these.

   Facts are cached by Wikidata id for 30 days, in memory and on disk (Caches). A failed lookup changes nothing:
   candidates keep today's tiers.
2. **Tiers with facts** *(the threshold of 30 sitelinks is Claude's call)*:
   - **OSM tags decide as today when present.** A `nonPlace` Wikipedia-only candidate is dropped.
   - **Wikipedia-only candidates:**
     - `place` with 30 or more sitelinks → `top`;
     - `place` with fewer → `good`;
     - `area` → `wikiOnly`;
     - `unknown` → `wikiOnly`.
   - **Example, worked from the 30 Oct lookup:**
     - Il Gesù (40), Palazzo Venezia (32) and Piazza Venezia (38) are `top`;
     - Largo di Torre Argentina (21) and Teatro Argentina (27) are `good`;
     - Via delle Botteghe Oscure is `wikiOnly`;
     - Jesuittordenen, École française and Liberatores are dropped.

   This applies to the nearby list (walking, map, camera's place list) and to tours.
3. **Order among due places:** tier, then sitelinks (more first, none counts as 0), then distance.
4. **Same spot:** when a place buzzes (or is heard, chosen on the map, or is a tour stop), every other place
   within 25 m of it, and every place with the same Wikidata id, is excluded for the run too, so one spot buzzes
   once.
5. **OpenStreetMap does not hold the list back.** Once Wikipedia (and Wikidata) are in, OpenStreetMap gets at
   most 5 s more. After that the list is used without it, marked `osmFailed` with the error "slow", and the
   existing 60 s OSM retry applies.
6. **Faster start:**
   - while the walk has no places, a failed fetch is retried after 15 s, then 30 s, then 60 s (reset on success),
     not 60 s;
   - at start, a stored nearby list centred within 250 m and at most 7 days old is used at once until the fresh
     one arrives. It is logged as `fetched` with `"stale": true`.
7. **The map's selection is logged while walking:** `shown` with place id, name and why (`heading`, `tap`,
   `buzz`, `cleared`). Only changes are logged, so the next walk can be compared with what was shown.
8. The `fetched` log line gains `facts` (how many candidates got facts), `factsFailed` (Wikidata batches that failed) and `dropped` (names removed as
   `nonPlace`).

## 20. Tuning from replayed walks (owner: «simuler … optimaliser 10 iterasjoner», 2026-10-30)

The four logged walks and four synthetic Rome routes were replayed offline through the core pipeline. The tool is
in the scratchpad, since the GPS tracks stay private. Iteration 1 findings and decisions *(Claude's calls; the
owner's earlier rulings «bedre med for mye enn for lite» and «for mange buzz om kjedelige steder» both apply)*:

1. **Coverage.** Norwegian articles often lack coordinates (Trevi, Campo de' Fiori, Porticus Octaviae). The
   English geosearch is always merged with the story-language one. Duplicates are matched by Wikidata id, and the
   story-language article wins for name and summary.
2. **Big objects.** The due radius grows with importance: top with ≥ 40 sitelinks 100 m, other top 80 m, the rest
   60 m. A place buzzes only while within its own due radius. It stays tracked out to 120 m for the override and
   for the "passed" check, but a late buzz at 92–107 m with "60 m left" no longer happens.
3. **Better place just ahead.** A due place is held while a better-ranked, not-excluded place within 60 m of it is
   still approaching (its distance shrank on the last fix) and is not yet due. The hold lasts at most 30 s.
4. **Complexes.** After a buzz, lower-ranked places within 40 m are excluded too. Every place within 25 m and every
   place with the same Wikidata id stays excluded.
5. **OSM tags and facts:**
   - an OSM candidate whose facts say `place` with ≥ 30 sitelinks is at least `top`;
   - one tagged top with fewer than 5 sitelinks is `good`;
   - an OSM candidate tiered `good` by tags, with no article and no Wikidata id, is `wikiOnly`.
6. **Classes:**
   - hill Q54050 and island Q23442 count as `place`;
   - human settlement Q486972 is `area`;
   - a Wikipedia-only `area` is dropped, unless it has ≥ 20 sitelinks and is not a settlement, in which case it
     is `wikiOnly`.
7. **Cadence.** At least 30 s between two buzzes, whatever the hourly setting.
8. **Refetching while OSM fails.** The OSM retry backs off 60 s → 120 s → 300 s while the list keeps failing, and
   resets when OSM answers or the walker moves 250 m.

### 20.2 Iteration 2 (replay after spec 20)

Spec 20 fixed coverage: Trevi, the Colosseum, Campo de' Fiori, Ponte Sant'Angelo and Palazzo Farnese now buzz,
and missed landmarks fell from 31 to 12. Volume became the problem: 47–62 buzzes per hour on the routes, a third
of them about places with fewer than 10 sitelinks. Decisions *(Claude's calls)*:

1. **The gap depends on rank.** After any buzz, the next one waits:
   - 30 s before a `top` place;
   - 90 s before a `good` place with at least 10 sitelinks;
   - 240 s before anything else (`good` with fewer than 10 sitelinks, `wikiOnly`).

   A Wikipedia-only `place` with fewer than 10 sitelinks is `wikiOnly`, not `good`.
2. **Exclusion respects rank.** The 25 m same-spot rule, like the 40 m complex rule, excludes only places ranked
   equal or lower. Same Wikidata id always excludes. Hills and islands never exclude others and are at most `good`.
3. **The wide radius buzzes at closest approach.** Between 60 m and a place's due radius, a place buzzes only once
   its distance has grown at least 5 m from the smallest distance seen (it is being passed). Within 60 m it buzzes
   as before.
4. **Wikipedia limit:** 100 articles per language per fetch, instead of 50.
5. **Complex radius:** 55 m, instead of 40.
6. **Classes:**
   - road Q34442 is `area`, like a street;
   - metro station Q928830 and treaty Q131569 are `nonPlace`;
   - `unknown` with fewer than 20 sitelinks is dropped;
   - a non-street `area` (neighbourhood, administrative) is dropped.

   An English-only candidate shows its story-language title when the Wikidata item has a sitelink in that
   language (from the same SPARQL query).
7. **Wikidata reliability.** A failed or timed-out batch is retried once, split into two halves run concurrently,
   each with the 8 s timeout.

### 20.3 Iteration 3 (replay after 20.2)

Without OSM the streams read like a guidebook: R1 has 26 buzzes (41/h) and none of them under 10 sitelinks. What
is left is landmarks lost to the gap, to lesser neighbours or to a story playing. Decisions *(Claude's calls)*:

1. **The gap follows importance, not tier:**
   - 30 s before a `top` place or one with at least 25 sitelinks;
   - 120 s before one with 15–24 sitelinks;
   - 240 s before anything else (fewer than 15, or `wikiOnly`).
2. **Hold for closest approach.** While a better-ranked place is due and waiting for its closest approach (20.2.3),
   lesser places are held too. The hold is limited to 30 s, as in 20.1.3.
3. **«Behind you».** When a story ends (busy → free), a place with at least 30 sitelinks that was due while busy,
   is not excluded and is still within 120 m buzzes once, within 60 s of the end, ignoring the gap.
4. **OSM minor items:**
   - an OSM candidate with fewer than 10 sitelinks is at most `wikiOnly`;
   - one with no Wikidata id is dropped, unless it is tagged `historic=castle|ruins|archaeological_site|monument`.
5. **Famous art in squares.** A work of art with at least 30 sitelinks is not excluded by the same-spot or complex
   rule of a different item. The same Wikidata id still excludes.
6. **Wikidata batches** are 25 ids, run concurrently (at most 4 in flight), with a 10 s timeout. The split retry
   stays.
7. The walking `perHour` default is unchanged. The owner sets it (60 now), and the gaps above keep dense routes
   near 30/h.

### 20.4 Iteration 4 (replay after 20.3)

Real walks now give 12–18 buzzes per hour and the routes 20–43, with 0–17 % under 10 sitelinks. Vespasian's
Forum, Pons Fabricius, Porticus Octaviae, Barcaccia and Quattro Fiumi buzz. Wikidata in batches of 25 has a
median of 2.6 s and 1.4 % timeouts, all saved by the retry. Decisions *(Claude's calls)*:

1. **Complex exclusion only for minor places.** The 55 m complex rule excludes only places with fewer than 20
   sitelinks. Places with 20 or more are excluded only by the same spot (25 m, rank-respecting) or the same
   Wikidata id. Before this, the Great Synagogue, Sant'Agnese in Agone and the Lupa capitolina were swallowed.
2. **Better place first.** A better place inside its due radius with no previous distance (the first decision of
   a run, or just added to the list) counts as approaching for the hold rule. A pending «behind you» goes before
   an ordinary due place with fewer sitelinks.
3. **«Behind you»:** reach 150 m, instead of 120, for places with 30 or more sitelinks.
4. **Gap:** 90 s for 20–24 sitelinks. Now 30 s for top or ≥ 25, 90 s for 20–24, 120 s for 15–19, and 240 s
   otherwise.
5. **`unknown` is always dropped.** Classes found so far cover the landmarks. Rione Campo Marzio (terrain, 44)
   went out this way.

### 20.5 Iteration 5 (replay after 20.4): diminishing returns

Spec 20.4 changed 2 buzzes in 32 run-variants. Decision traces found two real rule gaps; both are fixed here, and
then tuning stops until the owner's field test *(Claude's call)*:

1. **The hold looks from the walker.** A lesser place is held while a better-ranked place is inside its own due
   radius from the walker and is approaching, or has no previous distance. The old rule still holds too: a better
   place approaching within 60 m of the lesser place. Either one holds, with the same 30 s cap. Iteration 6
   showed San Crisogono lost to Sant'Agata at 49 m without the old rule. In the 18:25 walk, Palazzo Bonaparte (9 sitelinks) buzzed while Piazza Venezia (38) was at 78 m, 98 m
   from Bonaparte.
2. **Places passed during a story are remembered.** At each busy decision, and at the decision that started busy,
   every tracked place counts as due-while-busy for «behind you». Tracked means it has entered its due radius and
   is still within 120 m. In the same walk, Piazza Venezia was 2 cm outside its 80 m radius on the first busy fix
   and was never told.
3. **No change to the gap between neighbours in one piazza** (Sant'Agnese after Navona, the Synagogue after
   Porticus Octaviae). The walker has just heard about the place next door.

### 20.6 Fixes from the tuning review (2026-10-30)

1. **«Behind you» only after a real story, only for places passed.** The app is busy while a story is prepared,
   which takes a few seconds after every buzz. «Behind you» therefore applies only when busy lasted at least 20 s,
   and only to a remembered place whose distance has grown at least 5 m from its closest. It respects the 30 s
   minimum since the last buzz.
2. **Ordering.** «Behind you» is compared with the place that would actually buzz.
3. **One overall deadline for facts while walking:** 12 s from the start of the first lookup, covering retries and
   the second lookup for OSM ids. Whatever has not answered by then stays without facts.
4. **OSM objects without a Wikidata id are kept**, at most `wikiOnly`, instead of dropped. The 20.3.4 drop was
   tuned only on walks where OSM never answered. The castle/ruins/archaeological site/monument exception keeps
   its tag tier.
5. **Clock and jitter:**
   - the skip pause and the override interval use the same clock-back guard as the other timers;
   - "approaching" needs the distance to shrink by at least 2 m.
6. **Log:**
   - a buzz says whether it was «behind you» (`behind: true`);
   - a `held` quiet line names the place that holds.
7. **Merge without Wikidata id.** An English article without a Wikidata id is a duplicate when a story-language
   article has the same normalised title within 100 m.
8. A skip ends any pending «behind you» on purpose: the owner just asked for quiet.
