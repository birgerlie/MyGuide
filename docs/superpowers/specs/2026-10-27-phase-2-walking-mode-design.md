# MyGuide phase 2: Walking mode — design

**Status:** draft for owner approval
**Parent spec:** `docs/superpowers/specs/2026-10-26-myguide-design.md` (sections 7, 8.2, 8.3, 9.2). This document refines phase 2 from the owner conversation on 2026-10-27. Where the two differ, this document wins for phase 2.

## 1. Intent

A guide in the ear while walking. The owner switches walking mode on, puts the phone in a pocket, and walks. Whenever they come near a place worth hearing about, the watch buzzes with a short title, direction and distance. A tap plays the short story (16–30 seconds, longer for more important places) in the AirPods; another tap goes deeper. When they stop for a while, a short story about where they stand is waiting on the lock screen.

It should feel like a generous guide who knows which places matter, not a stream of notifications.

## 2. What the owner decided

- **Start:** the owner opens the app and switches walking mode on. *(owner)*
- **Photos during a walk:** while walking mode runs, the owner can still open the app and take photos for a photo story. Walking mode keeps running. *(owner)*
- **Buzz → story:** a tap on the watch plays the story in the AirPods. Another tap continues to the next level (levels: 40–75 words by place tier, then 200, then 300 words; guide-voice design section 5). *(owner, spec)* The Ultra 1 Action button is an optional extra, not required.
- **Pace:** a setting, **buzzes per hour, 5 to 60**. The owner expects a guide to buzz often ("perhaps more than 30"). *(owner)*
- **Skip:** a skip control on the watch while a story plays. A skipped place never buzzes again. *(owner)*
- **No buzzes about boring places.** Being buzzed about dull places is what would make the owner switch walking mode off. *(owner)*
- **Place-kind heuristics, tuned later by hand:** a fixed list of place kinds decides what may buzz and what wins. Every buzz and its outcome is logged, so the owner and Claude can look at the numbers after some walks and adjust the list. No automatic learning in phase 2. *(owner)*
- **Stop story:** after standing still for about a minute, a **short story about where I am** is on the lock screen. No detour suggestions. *(owner; this drops the spec's "suggestion to divert")*

## 3. Goals

1. Buzz for nearby places that are worth a story, at the pace the owner set.
2. Tap → story in AirPods within a few seconds; tap again → next level; skip → silence and the place is retired.
3. Stop → short text story on the lock screen.
4. Work with the phone locked in a pocket for a walk of several hours.
5. Log buzzes and outcomes per place kind so the heuristics can be tuned.

## 4. Non-goals (phase 2)

- Themes (phase 4) and routing (phase 3).
- Automatic learning from skips.
- Detour suggestions in the stop story.
- A watch app that talks to OpenAI or works without the phone.
- The trip diary screen (the data is recorded; the screen comes later).
- Requiring the Action button.

## 5. Anti-goals

- Buzzing about boring places (a plain "historic=yes" house with no story behind it).
- Buzzing while a story is playing.
- Buzzing about shops, restaurants or cafés (spec).
- Buzzing twice about the same place in one trip, or ever again after it was heard or skipped.
- Silently draining the battery: walking mode is visibly on, and turns itself off rather than run forever.
- A tap that does nothing for 15 seconds.

## 6. Constraints (from the parent spec and the platform)

- Apple Watch **Ultra 1**: no double-tap gesture. Tap on the watch is the primary control.
- **Free Personal Team** signing. Watch app, background location, Live Activities and time-sensitive notifications must each be verified on the owner's devices (spec section 7). Anything blocked waits for the paid account; the rest ships.
- **No server.** A Live Activity can only be started in the foreground (when walking mode is switched on) and updated from the background. The time-sensitive local notification is the baseline for the stop story; the Live Activity is the upgrade.
- **OpenAI only**, key in the phone's Keychain. The watch never holds the key.
- **OSM and Wikipedia usage policies:** Overpass and Wikipedia are public, shared services. Fetching must be sparse (see 7.2).
- Swift 6, iOS 26, watchOS 26, same package and test discipline as phase 1.

## 7. How it works

### 7.1 Who does what *(Claude's call, owner agreed to the outline)*

The **phone does all the work**: location, finding places, choosing buzzes, OpenAI requests, speech, audio to the AirPods, memory, logging. The **watch is buzzer, screen and remote**: it shows the title, direction and distance, buzzes, and sends "tell me", "more" and "skip" back to the phone.

Two ways to reach the watch, to be settled by the step-0 check:

- **A. Mirrored notifications (baseline).** The phone posts a local notification per buzz with actions "Tell me" and "Skip". With the phone locked in a pocket, iOS shows it on the watch, with the watch's notification haptic. A tap on an action wakes the phone app in the background, which starts the story. This needs no watch app at all, so it works even if a watch app cannot be signed on the free team. "More" is a notification action posted when a level finishes.
- **B. Watch app with a walking workout session (upgrade).** A small watch app started together with walking mode runs a workout session, which keeps it alive with the wrist down. That allows a **distinct** buzz pattern (spec 8.3), a custom screen with a direction arrow, and instant tap/more/skip over WatchConnectivity. Side effect: the walk is recorded in Fitness.

Build A first; build B if step 0 shows it works on the free team and the owner wants the distinct haptic.

**If neither A nor B works** *(owner agreed)*: the trigger becomes an App Intent bound to the Action button through Shortcuts, which starts the story in the AirPods. If that also cannot start audio, the watch notification shows the title, direction and distance, and tapping it opens the story on the phone. Phase 2 ships either way; it does not wait for a perfect watch tap.

### 7.2 Finding places

- Location: background location while walking mode is on ("Always" permission requested when the owner first switches walking mode on; "When in use" plus the background location indicator is acceptable if that works).
- Places come from the phase-1 grounding (OSM via Overpass, Wikipedia geosearch), fetched for a **500 m radius** around the owner and fetched again only after they move **250 m** from the last fetch point. At walking pace that is roughly one fetch per three minutes. *(Claude's call)*
- Filtered by the place-kind list (7.3). Shops, restaurants and cafés never buzz.

### 7.3 Place-kind list *(Claude's call, tuned by hand later)*

Three tiers, highest first. A place's tier comes from its OSM tags.

1. **Top:** castle, palace, cathedral, city gate/city wall, ruins, archaeological site, monuments to people or events, famous landmarks. Also tier-2 places that have a Wikipedia article.
2. **Good:** church, museum, memorial, historic square, notable historic building with a name.
3. **Only with a Wikipedia article:** plaques, `historic=yes` buildings, statues, fountains, bridges, squares and streets, theatres, and **anything else that has a Wikipedia article but no kind in this list**, including Wikipedia geosearch results with no OSM match. Tier 3 is never lifted. *(Claude's call: tier 3 only buzzes when no tier 1–2 place is due, so these fill quiet stretches without crowding out better places; the buzz log shows whether they bore the owner.)*
4. **Never, even with a Wikipedia article:** shops, food and drink, hotels, banks, offices, schools, embassies, stations and other transport stops, unnamed objects.

The list lives in one place in the code, with its own tests, so changing it is a one-file edit.

### 7.4 Choosing when to buzz

- **Approach:** a place becomes due when it is within **60 m**, and stays due until it is **120 m** away, so a place passed during a wait can still buzz ("90 m behind you") *(Claude's call)*.
- **Pace:** the setting is an **average** ("average buzzes per hour", owner's words) and a ceiling, never a quota *(Claude's call)*. Implemented as a budget that refills at the set rate (60/h → one per minute, 5/h → one per 12 minutes) and holds at most **3** unused buzzes, so a cluster of good places after a quiet stretch can buzz close together. The app never widens its search or lowers its bar to reach the rate: in a quiet area the owner simply gets fewer buzzes.
- When a buzz is available, the highest-tier due place wins; ties go to the nearer place. A **tier-1** place that would otherwise drop out of range (beyond 120 m) may buzz even with an empty budget, at most once per **10 minutes** *(Claude's call)*.
- No buzz while a story is playing or being prepared; no buzz in the minute after a skip *(Claude's call)*.
- A place buzzes at most once per trip (parent spec 8.2). Heard or skipped: retired for good. Ignored: may buzz again on a later trip.
- A place the owner photographed during this trip counts as heard *(Claude's call)*.
- **Direction and distance** are relative to the walking direction (GPS course), since the phone is in a pocket: "50 m left", "ahead", "behind you". Distance rounded to 10 m.

### 7.5 The walking story

- Same story style, levels and memory priors as phase 1, but made from position, walking direction and the chosen place instead of a photo. Style, lengths and the request's contents (address, walking direction, where the walker came from, stories told lately, Apple Maps places): see the guide-voice design (`2026-10-28-guide-voice-design.md`, sections 4–7).
- **Prepared when the buzz goes out:** the first-level text (40–75 words by place tier, guide-voice design section 5) and its speech are fetched as soon as the place is chosen, so a tap plays within a second or two *(Claude's call)*. An ignored buzz therefore costs one small text request and one short speech request (roughly a cent or less; the cost counter shows the real figure). If the owner taps before it is ready, it plays as soon as it is.
- "More" fetches the next level the same way as phase 1's "Tell me more".
- Audio plays through the phone to the AirPods (or the phone speaker if none are connected), with the phase-1 audio session handling.

### 7.6 Stop story

- **Stopped:** speed below walking pace and within **25 m** of one point for **60 s** *(Claude's call)*.
- The phone makes a **short text story about the spot** (at most 50 words; see below) from position and nearby places, and puts it on the lock screen: by updating the Live Activity started with walking mode if step 0 shows that works, otherwise as a time-sensitive notification. One tap opens the full story in the app, where "Tell me more" and speech work as in phase 1.
- At most one stop story per spot: not again within 100 m in the same trip *(Claude's call)*.
- Length (at most 50 words), what the request holds and what happens when there is little or nothing nearby ("worth the detour", or no stop story at all): see the guide-voice design (`2026-10-28-guide-voice-design.md`, sections 5, 6 and 9).
- The stop story is about the spot. Places already heard this trip go into the request as memory priors, so it takes a new angle and doesn't repeat them. Places it mentions are **not** retired, since the app can't know whether the lock-screen text was read; the story itself is saved, so a later buzz about the same place gets it as a prior and takes a different angle *(Claude's call)*.

### 7.7 Trips, memory and the buzz log

- **Trips** (parent spec 8.2, not built in phase 1): a new trip starts when the app is used in a different city than the current trip, or after 3 or more days without use.
- Memory per place gains: buzzed (time, trip), heard, skipped, deepest level heard.
- **Buzz log:** every buzz with time, place, place kind, tier, distance, and outcome (heard / skipped / ignored), plus the level reached. Viewable as a simple list with counts per place kind in Settings, and exportable as CSV through the share sheet so it can be handed to Claude for tuning *(Claude's call)*.
- The walked track is recorded while walking mode is on (parent spec 8.2), for the later trip diary.

### 7.8 Switching off

- The owner switches it off in the app (or from the Live Activity / watch if available).
- It turns itself off after **4 hours**, or when the phone battery drops below **15%**, with a notification saying so *(Claude's call)*.

### 7.9 Settings added

- Buzzes per hour, 5 to 60, default **20** *(Claude's call)*.
- Buzz log (list, counts per kind, export).

## 8. Build steps

Each step runs on the owner's phone (and watch) before the next starts.

0. **Platform check** on the owner's devices with the free team: background location keeps running for 30 minutes with the phone locked; a notification action from the watch wakes the phone app and starts audio in the AirPods from the background; a time-sensitive notification arrives on the watch; a Live Activity started in the foreground can be updated from the background; a minimal watch app installs and can run a workout session and play a custom haptic. Also try binding an App Intent to the Action button. Results decide A vs B (7.1) and Live Activity vs notification (7.6).
1. **Walking engine on the phone:** walking mode switch, background location, place fetch, place-kind tiers, buzz choice and pace, trips. Buzzes as mirrored notifications (path A) with "Tell me" / "Skip".
2. **Walking story:** prepared at buzz time, played on tap, "More", skip, memory updates.
3. **Stop story** on the lock screen.
4. **Buzz log, settings, auto-off.** Then path B (watch app) if step 0 cleared it.

## 9. Left to the builder

- Exact OSM tag-to-tier mapping within the tiers above.
- Stationary detection details beyond the thresholds given.
- The watch screen layout (path B).
- How the walking story prompt differs from the photo prompt, within the phase-1 style rules.
