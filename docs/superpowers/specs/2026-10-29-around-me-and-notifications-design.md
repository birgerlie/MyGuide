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
