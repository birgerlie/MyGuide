# MyGuide: Guide voice and richer grounding — design

**Status:** draft for owner approval
**Parent specs:** `2026-10-26-myguide-design.md` (sections 3, 6, 8.1) and `2026-10-27-phase-2-walking-mode-design.md` (7.5, 7.6). Where they differ, this document wins. It applies to every story: photo, walking buzz, stop story and all continuation levels.

## 1. Why

The owner used walking mode on a walk on 2026-10-27. Their verdict: the text is far too poor; it "only writes historical prose and makes up history". It should work like a normal guide.

Two causes, both in the design Claude wrote:

1. **The prompt asked for prose.** The system instructions ask for "short, true stories about the people who were here … the sounds, the smells, who walked past", with dates and architecture "only when they support a story about people". The parent spec even lists "guidebook voice" as an anti-goal. That steers the model into scene painting.
2. **Too little to stand on.** The model gets a place name, an OSM kind and at most 600 characters of Wikipedia intro. Walking buzz prompts get no street address at all. With thin facts and a request for vivid scenes, the model invents.

## 2. What the owner decided

- **The voice is the owner's guide prompt** (section 4), close to verbatim. *(owner)*
- **The context goes in a structured user message, not in the system prompt,** so the system prompt can be cached. *(owner)*
- **Where you are, from Apple Maps:** street address and direction go straight into the request. *(owner)*
- **Where you came from:** when walking, the previous position goes into the request. *(owner)*
- **A field for what was told in the last few hours,** so walking back and forth over the same ground does not repeat. *(owner)*
- **Length by trigger:** about 60 words when the app starts a story on its own while walking, scaled 15–30 seconds by how important the place is, with 2–3 points; about 200 words when the owner asks for it with a tap. *(owner; the table in section 5 is Claude's combination of the two, which the owner accepted: "la oss forsøke")*
- **When nothing is found:** say so and point to something worth the detour; stay silent rather than pad (section 9). *(owner raised it; the ladder is Claude's, accepted)*

## 3. Goals, non-goals, anti-goals

**Goals**
1. Stories sound like a good private guide: the most striking thing first, then specific, checkable points the listener can see, mixing history, architecture, food and science where the place invites it, ending with one concrete nudge.
2. Fewer invented facts, through stricter honesty rules and more real facts in each request.
3. The model knows exactly where the listener stands, which way they face or walk, where they came from, and what they already heard today.

**Non-goals**
- Changing models (gpt-5-mini stays; its 2026-12-11 shutdown is a separate decision).
- Web search tools in the OpenAI request. *(Claude's call: more cost and latency per buzz; revisit if fuller Wikipedia text and OSM facts still leave the stories invented.)*
- Changing the speech voice, the "then" image, or buzz selection.
- Recommending businesses.

**Anti-goals**
- Invented names, dates, numbers or quotes. A detail stated with confidence that belongs to a similar building elsewhere.
- Scene painting ("imagine the smell of…") as the main content.
- Greetings, "welcome to", restating the address back to the listener.
- Lists, headings or emojis in the text: it is read aloud.
- Padding a dull spot instead of pointing to something nearby worth the detour, or instead of staying silent.
- Repeating a point the listener heard earlier the same day.

## 4. The voice (system instructions)

The owner's prompt, adapted only where the app's context or the honesty rules require. Claude's adaptations are marked ◆ and are part of the decision, not left to the builder. The ◆ marks are not part of the prompt text.

The system instructions are **one constant string, byte-identical for every story request** (photo, buzz, stop, continuation, both languages). Language and length come in the user message (section 6), which is the one adaptation to the owner's `{{language}}` and "under 150 words" placeholders.

```
You are a brilliant private guide walking beside the user. You have the depth of a historian, the eye of an architect, the palate of a food writer and the curiosity of a scientist, and you wear it lightly — like a well-read friend, not a lecturer.

CONTEXT YOU RECEIVE
Each request is a structured message: where the user stands (street address, district and city from Apple Maps), the local time, which way they face or walk, where they came from if they are walking, nearby named places with their distance and side, facts about those places from OpenStreetMap and Wikipedia, what you have already told them, and sometimes a photo they just took. Treat these as what is actually in front of them. ◆

WHAT TO DO
- Start with the single most striking thing about where they stand. No greeting, no "welcome to", no restating the location.
- Give the number of short, vivid points the request asks for. ◆ Favour the specific over the general: a name, a date, a number, a detail they can look up and see with their own eyes right now ("notice the pockmarks on the left column — those are from…").
- Mix domains naturally when the place invites it: how it was built, who lived or died here, what people ate here and still do, the geology, optics, acoustics or engineering behind what they see. Don't force all four every time.
- Prefer the surprising-but-true over the famous-and-obvious. Assume the user has already read the plaque.
- If it's near a meal time and there's a real local dish or ingredient tied to this place or district, mention it in one line — what it is, why here. Never recommend a particular restaurant, café or shop. ◆
- If a photo is included, talk about what is actually in the frame first.
- End with one optional, concrete nudge: "If you walk 80 m to your right…" or a question that will make them look closer. Only one. For directions, use only the places, distances and sides given to you. ◆

HOW TO SOUND
- Warm, confident, lightly witty. Short sentences. Spoken rhythm — this will be read aloud. ◆
- No bullet points, no headers, no emojis. Plain flowing prose at the length the request asks for. ◆
- Answer in the language the request names. ◆

HONESTY
- Only state things you are genuinely confident are true of this specific place. If you are unsure whether a detail belongs here or somewhere similar, say "I believe" or leave it out. A guide who invents is worse than a guide who says less.
- The facts in the request are your ground. Never invent names, dates, numbers or quotes. Label legend, tradition or disputed history as such ("legend has it"). ◆
- Never repeat anything listed under "Told in the last 3 hours" or "Told here before"; find a new point. ◆
- Never pad. If the spot is genuinely unremarkable, say so in one sentence and tell them what *is* nearby that's worth the detour. If the facts run out before the requested length, stop shorter. ◆
- If nothing is known about what is in a photo, talk about what can actually be seen — building style, materials, plants, rock, light — and say plainly that you know no recorded history of it. ◆
```

**Caching** *(Claude's call)*: OpenAI caches automatically when the request prefix is at least 1,024 tokens. The instructions are about 700 tokens, so caching may not engage; the request also sends `prompt_cache_key: "myguide-story-v1"`. Nothing in the design depends on caching working. The schema name and JSON schema for each request kind stay constant too.

## 5. Story lengths and points

Length depends on what triggered the story and, for app-triggered stories, on how important the place is (the existing `PlaceTier`, walking design 7.3).

| Story | Words | ≈ Spoken (150 words/min) | Points |
|---|---|---|---|
| App-triggered first level (walking buzz, stop story), tier 1 place | 75 | 30 s | 2–3 |
| App-triggered first level, tier 2 place | 60 | 24 s | 2–3 |
| App-triggered first level, tier 3 place, or no tier | 40 | 16 s | 2–3 |
| Photo story first level (amended 2026-10-31: what it is and why it matters, first) | 75 | 30 s | 2–3 |
| "More" (level 2) after any story | 200 | 80 s | 3–4 |
| "Even more" (level 3) | 300 | 2 min | as many as the facts carry |

- **Tier for a buzz:** the buzzed place's tier. **For a stop story:** the best tier among the OSM/Wikipedia places in its request; 40 words if none (including the "nothing here, but nearby" case of section 9). Never-tier places and Apple Maps places count as no tier.
- **A buzz about a place with no facts** (no OSM fact tags, summary or article text) gets 40 words whatever its tier: less to say, less to invent. *(Ruling at the final review)*
- **Stop stories are capped at 50 words** (tier 1 and 2 both give 50) so they still fit the Live Activity layout (`WalkingLiveActivity`, about 8 lines). *(Claude's call: keeps widget work out of this change.)*
- Every level ends with the one nudge (each level may be the last one heard), different from earlier levels' nudges. *(Claude's call)*
- Today `StoryLevel.targetSeconds` fixes length per level. It becomes a function of the story kind, level and tier; `StoryLevel` keeps identifying the level. Audio level cards, cost estimates and the walking flow that read `targetSeconds` follow the new length.
- The request states length and points as one field: `Length: about 60 words (24 seconds spoken), 2–3 points`.

## 6. The user message

One user message per request, plain text, one field per line, always in this order. A field whose data is missing is left out unless its rule below says otherwise. Example for a walking buzz:

```
Story: walking buzz, first level
Position: Kirkegata 15, Kvadraturen, Oslo, Norway
Time: 12:40 Wednesday
Walking: north along Kirkegata
Came from: Stortorvet, 3 min ago, 220 m behind you, along Kirkegata
Subject: Oslo Cathedral (church), 40 m, to your right
Facts about Oslo Cathedral:
  OSM: start_date=1697; heritage=…
  Wikipedia: …
Nearby: Stortorvet (square), 220 m, behind; Christiania Torv (square), 310 m, ahead-left
Also on Apple Maps: Deichman Grünerløkka (library), 120 m, ahead
Told in the last 3 hours:
- 11:58 Akershus Fortress: "…first sentence…"
Told here before:
- [osm:way/123] level 1: …
Length: about 75 words (30 seconds spoken), 2–3 points
Answer in: Norwegian Bokmål
Task: Tell the user about the subject they are passing.
```

### 6.1 Story
`Story:` the kind (photo, walking buzz, stop, continuation of …) and level, so the model knows its situation. Photo requests keep the photo as an image part in the same user message.

### 6.2 Position (Apple Maps)
- Reverse geocoded with the existing `MKReverseGeocodingRequest` path, extended with the **district/neighbourhood** when MapKit returns one *(the builder verifies which `MKAddress` / `MKAddressRepresentations` field gives it on iOS 26; if none does, the field has no district)*.
- **Walking buzz stories get the position too** (today they get none). Use the route lookup (6.5) when it is within 50 m of the current position; otherwise a new lookup, with the existing 8 s limit.
- Photo requests keep the coordinates and their accuracy after the address, as today.
- On failure or timeout: `Position: address lookup failed` plus coordinates, so the model knows to be cautious. A continuation of a walk story saved before its address was looked up (a buzz story from before this design) says `Position: unknown` plus coordinates.
- The direction a buzz notification is worded with (route direction, else GPS course) is the one its story is told with.

### 6.3 Time
`Time:` 24-hour local time and English weekday, phone's time zone (`12:40 Wednesday`). English regardless of story language *(Claude's call: the request is English; only the answer is localised)*.

### 6.4 Direction in words
- **Photo:** `Facing: south-east (135°), compass ±10°` when the heading is usable; otherwise `Facing: unknown`. The existing in-view logic stays.
- **Walking:** the walking direction is the bearing from the track point about 100 m back (path length) to the current position, written as a compass word plus the current street: `Walking: north along Kirkegata`. Fallbacks, in order: GPS course; `Walking: direction unknown`. *(Claude's call: GPS course is unreliable at walking pace.)*
- **Stop:** `Standing still; walked in heading north along Kirkegata` when the track has it.
- **Every place** (subject, nearby, Apple Maps) gets distance and side relative to the facing/walking direction: ahead (within ±30°), ahead-left/right (30–60°), left/right (60–120°), behind-left/right (120–150°), behind (beyond ±150°). Without a direction: compass word instead (`north-east`). Distances rounded to 10 m like `BuzzText`. *(Claude's call)*

### 6.5 Came from (walking only)
- While walking mode runs, the phone reverse geocodes the street at most **once per 100 m walked** (path length) and remembers street name, time and position. Failed lookups are skipped, not retried. At 5 km/h that is about one lookup per 72 s.
- `Came from:` the oldest remembered street or told place within the last **300 m of path or 5 minutes**, whichever is shorter, with minutes ago, straight-line distance, side, and `along <street>` when one street covers the stretch.
- Left out at the start of walking mode, after a stop story, and when the window is empty. Never in photo requests.
- The remembered streets live in memory only (not SwiftData) and are cleared when walking mode stops.

### 6.6 Subject and facts
- `Subject:` the buzzed place, the matched photo candidate (continuations), or none (first photo level, stop story).
- `Facts about <name>:` for the subject (buzz; matched photo continuation) and, for a stop story, for the best-tier place listed *(Claude's call)*. Contents in 7.1 and 7.2, each on one line. With no facts: `Facts about <name>: none found`.
- A stop continuation whose position has no place within 500 m any more says `Facts: none found` and asks the model to continue only with what it genuinely knows about the spot and to stop short; it does not search Apple Maps again. *(Ruling at the final review)*
- **Photo first level:** the model must still identify the subject, so every candidate keeps its Wikipedia summary (600 characters, as today) and its OSM fact tags, in today's ranked order (in view first, nearest first). No 4,000-character fetch before identification, so no candidate is favoured by having more text *(Claude's call)*. **Photo continuation:** the matched candidate gets `Facts about` with the full text; with no match, the up-to-3 places of today's `factCandidates` keep their summaries and tags.
- `Nearby:` the other places as today (buzz: up to 4 best-tier-then-nearest; stop: within 150 m, up to 5; photo: the ranked candidates with in view/out of view), each with kind, distance, side, and its OSM fact tags on an indented line when it has any.

### 6.7 Told in the last 3 hours *(new)*
- Every story level **heard** in the last 3 hours, anywhere: photo story levels, buzz levels up to the buzz's `deepestLevel`, stop stories. Excluding the story being continued.
- **Plus buzz and stop stories prepared but not yet heard** (held by `PreparedWalkStories`, up to 5), marked `(prepared)`, so two buzzes prepared close together do not tell the same point *(Claude's call)*.
- Each as `- HH:mm <place name or "this spot"> level N: "<first sentence, at most 160 characters>"`, where `HH:mm` is when the story was written (`createdAt`); newest first, at most **10**.
- `Told in the last 3 hours: nothing` when empty.

### 6.8 Told here before
- Today's `priorStories` (same places anywhere, nearby unidentified captures and stop stories), minus any story already in 6.7. Same format and limits as today.

### 6.9 Length, language, task
- `Length:` from section 5. `Answer in:` `StoryLanguage.promptName`. `Task:` one sentence per kind; the photo task keeps the identification instructions and `matchedCandidateID` rule; continuations say "Continue from where the story left off; new points, from another domain where the facts allow; do not repeat."
- Continuations (levels 2 and 3, photo and walking) get a fresh Position, Time and direction (the listener may have moved), the subject's facts, `Told so far:` with the previous levels in full, and fields 6.7–6.9.

## 7. More facts per request

### 7.1 Fuller Wikipedia text
- For the place under `Facts about`, when it has a Wikipedia article: fetch the article's plain text, intro plus following sections, **up to 4,000 characters**, from the same Wikipedia language edition as today.
- Cached per place for the walking trip or the photo session. For buzzes it is fetched when the buzz is chosen, before the story request, within the existing preparation; the tap-to-audio time does not grow for a story that is ready.
- On failure or after 5 s: fall back to today's 600-character summary and carry on. Never block a story on it.
- One extra Wikipedia request per told place, within the Wikipedia usage policy (walking design 6).

### 7.2 OSM fact tags
- Add to `OverpassClient.keptTagKeys`: `start_date`, `architect`, `building:architecture`, `inscription`, `description`, `artist_name`, `name:etymology`, `wikidata`, `heritage:operator`, `memorial:type`, `material`.
- Listed as `OSM: key=value; …` (values over 200 characters cut). They never change a place's tier.

### 7.3 Apple Maps places
- One `MKLocalPointsOfInterestRequest` per first-level story: within **150 m** for walking and stop stories, **250 m** for photos *(Claude's call)*. Categories: museum, landmark, castle, fortress, monument, park, national park, library, university, theater, music venue, stadium, zoo, aquarium, planetarium, spring, beach, bakery, restaurant, café, brewery, winery, market (the builder skips any category that does not exist on iOS 26).
- Listed as `Also on Apple Maps:` with name, category, distance and side, at most 8, dropping names that match an already listed place (case- and diacritic-insensitive). Other categories come before food, nearest first within each, and at most 2 food places are listed, so food never crowds out sights. *(Ruling at the final review)*
- Food categories are there only to ground the meal-time line; the instructions forbid recommending them.
- 8 s limit; on failure the field is left out silently (it is supplementary). Continuations reuse the first level's result.

## 8. Requests and caching recap

- `instructions`: the constant of section 4.
- `input`: one user message (section 6), plus the photo image part for photo stories.
- `prompt_cache_key`: `"myguide-story-v1"`.
- `store: false` and strict JSON schema, as today.

## 9. When nothing is found

Each step applies only when the one above has nothing.

1. **Something notable at the spot:** the normal story.
2. **Stop story, nothing within 150 m but a tier 1–3 place within 500 m** (from the places walking mode already fetched): the request lists the best one or two as `Worth the detour:` with distance and side; the story says in one sentence there is little to tell right here and points there. 40 words.
3. **Photo with no candidates and no Apple Maps places:** the story is about what is in the frame (style, materials, plants, rock, light) and says plainly no recorded history was found. Normal photo length.
4. **Stop story with nothing within 500 m:** no stop story. No notification, no Live Activity update, nothing logged as a story. *(Silence beats padding.)*
5. **Map data or address lookup failed:** the request says which source failed (as today, `Map data unavailable: …`); the model stays with what it can see or say safely. If OpenAI fails, the existing error handling applies.
6. **Walking buzz:** unchanged; no due place means no buzz.

Apple Maps places (7.3) never decide a step: steps 1, 2 and 4 look only at the OSM/Wikipedia places walking mode already has, so the stop-story decision never waits for the Apple Maps request. The Apple Maps request runs only once a story is going to be written. *(Claude's call)*

## 10. Spec changes

- Photo schema field `era`: description becomes "The era the subject is best known from, e.g. 'built 1697' or 'around 1780'", so the "then" image keeps a useful era now that the story no longer paints one. *(Claude's call)*

- Parent spec section 3: drop the anti-goal "Guidebook voice"; add the anti-goals of section 3 above.
- Parent spec section 6, "Story style" row: "Private guide: most striking thing first, specific checkable points across history, architecture, food and science, one nudge at the end; see the guide-voice design."
- Parent spec section 6, "Story lengths" row: replaced by section 5's table.
- Walking design 7.5 ("Same story style") and 7.6 (stop story ≈ 50 words; the stop story's fallback) now refer to this document.

## 11. Measuring it

- Every story's text is already stored. No new logging.
- The owner judges on the next walk. If the text still invents, the next step is the web-search non-goal in section 3.

## 12. Left to the builder

- The exact `MKAddress`/`MKAddressRepresentations` field for district, and the exact `MKPointOfInterestCategory` cases for 7.3.
- How the route memory (6.5) and the 3-hour list (6.7) are threaded through `WalkingController`, `WalkingStories`, `AppServices` and `MemoryStore`.
- Wikipedia API parameters for 7.1.
- Task sentences per story kind, within section 6.9.

## Amendment 2026-10-31: open with what and why

The owner's wish after using the app: every story should say at once what the thing is and why it is interesting, briefly, and that should be the first thing the app gives, photo stories included.
- The instructions' first rule becomes: open with what it is and why it is worth their attention, naming the thing plainly and giving the single most striking reason it matters, in the first one or two sentences.
- The photo story's first level drops from 200 words (3–4 points) to 75 words (2–3 points), the same as a tier 1 buzz. "More" (200) and "Even more" (300) are unchanged and carry the depth.
- The photo first level's task ends "Then tell the user what it is and why it is interesting."
