# MyGuide: tours — a loop with a duration, or A→B with at most 25 % detour

Status: written by Claude while the owner was away (owner: «om vi har features planlagt gjennomfør dette så bra
du kan»). Built on branch `tours` from `around-me`. The owner reviews before anything merges; every decision not
quoted from the owner is marked *(Claude's call)*.

## 1. Why

The owner, earlier, in their words:
- «appen burde ha to turmodes, kunne lage en tur fra der jeg [er] med en tids varighet eller fra der jeg er til
  der jeg skal med inntil 25 % omvei for å få med de beste eller viktigste severdigheter på vei dit jeg skal»
- «eneste er at jeg vil egentlig ikke ha et super detaljert kart»
- the landing sketch has a «Turer» tab; «Gå en tur» should later offer «velg en tematur».

Today walking mode is free roaming: it buzzes about whatever is near. A tour adds a plan: an ordered set of the
best places, a walking route through them, and the same buzz and story machinery on the way.

## 2. Goals, non-goals, anti-goals

**Goals**
1. **Loop:** from where the owner stands, a round trip of a chosen duration (30 min – 3 h) through the best places
   reachable in that time, back to the start.
2. **A→B:** from where the owner stands to a chosen destination, through the best places that fit within
   **125 %** of the direct walking time.
3. Preview before starting: muted map with the route and numbered stops, the stop list with walking times, total
   time and distance, «Start turen».
4. Starting a tour starts walking mode. Stops buzz when reached; the map and sheet show progress («Neste: Pantheon
   · 300 m»); the tour survives the app being closed.

**Non-goals (this part):** theme tours, saved or shared tours, turn-by-turn navigation voice, offline maps, the
diary's tour summary page.

**Anti-goals:** a route through places of no interest just to fill time; a tour that runs much longer than asked
(more than 10 % over); a busy map; a tour that silently fails when routing is unavailable.

## 3. Constraints

- Same as the around-me spec (design package, Swift 6, core logic in MyGuideCore with tests, no new third-party
  services). Walking routes come from MapKit `MKDirections` with `.walking`. Places come from the existing
  OpenStreetMap + Wikipedia sources and tiers.
- Screen texts follow the iPhone language (around-me spec 17); stories follow the story language.
- Routing calls are rate-limited by Apple: at most **25** `MKDirections` requests to build one tour
  *(Claude's call)*.

## 4. Places for a tour

- Fetched for the tour area, not the 500 m nearby list:
  - **loop:** a radius of `min(2500, walkingSpeed × duration / 2.5)` metres around the start, where the walking
    speed is 1.3 m/s;
  - **A→B:** the bounding box of the straight line, padded by 30 % of its length on each side.
- Wikipedia geosearch tops out at 10 km and 500 results, so a big area is covered by up to 4 geosearch tiles.
  Overpass gets one bbox query with the same tags as today.
- Only tier `top` and `good` places are candidates, plus `wikiOnly` when fewer than 4 top/good places exist
  *(Claude's call: the best or most important, in the owner's words)*.
- Score: top 3, good 2, wikiOnly 1. A place already heard in the last 30 days scores × 0.5, so it is not
  excluded but loses to new ones.

## 5. Planning

Pure logic in core (`TourPlanner`). The planner works on straight-line distances × a detour factor of **1.3**,
then the app checks the result with `MKDirections`.

- **Loop:** greedy insertion. Start with [start, start]. Repeatedly insert the candidate with the best
  score ÷ added minutes at its cheapest position, while the estimated total (walking + 4 min dwell per stop) stays
  ≤ the chosen duration. Then 2-opt to shorten the order.
- **A→B:** the same insertion, starting from [start, destination], with a budget of
  1.25 × the direct walking time + 4 min per stop.
- **Verification:** request walking routes leg by leg (≤ 25 legs). If the real total exceeds the budget by more
  than 10 %, drop the stop with the worst score ÷ saved minutes and re-route only the two affected legs. Repeat
  until the total fits or no stops remain.
- **No stops fit:** the preview says so honestly («Ingen severdigheter passer inn i 30 minutter herfra») and offers
  the plain direct route (A→B) or a longer duration (loop).
- **Routing unavailable** (no network, MapKit error): the preview shows the stops on straight lines, marked
  «Omtrentlig rute», and still allows starting.

## 6. Screens

**Turer tab** (spec 14's tab bar gets its third tab back, now that it has content):
- Two cards: «Rundtur» with a duration picker (30, 45, 60, 90, 120, 180 min) and «Til et sted» with a destination
  field (`MKLocalSearchCompleter`, as in Apple Maps search).
- «Lag tur» shows a progress line («Finner steder …», «Lager rute …»), then the preview.

**Preview:**
- muted map with the route polyline in forest and numbered stop pins (coral for the next stop);
- the stop list with name, kind symbol, walking minutes to it, and a picture when cached;
- totals: «1 t 25 min · 5,2 km · 6 stopp»;
- «Start turen» in coral. «Fjern» on a stop removes it and re-plans the order.

**During a tour:**
- The Utforsk map shows the route and the stops, and the sheet shows the tour panel in place of «Gå en tur»:
  - «Neste: Pantheon · 300 m», with progress «2 av 6»;
  - «Hopp over stopp»;
  - «Avslutt turen».
- Walking mode runs with the tour. Arriving within 60 m of the next stop buzzes it, even if its tier would not buzz
  on its own, and marks it visited. Other places still buzz as usual, but at most 1 buzz per 3 minutes between
  stops, so the tour stays the main thread *(Claude's call)*.
- The loop ends at the start and A→B ends at the destination: «Turen er ferdig · 6 stopp · 1 t 31 min».

## 7. State

- `ActiveTour` (Codable, in Application Support): plan, visited stop ids, started at, and the route polylines as
  coordinate arrays. It is restored at launch.
- Walking mode's existing controller takes an optional tour. Pausing walking mode pauses the tour, and stopping it
  ends the tour (with a confirmation if stops remain).
- The watch shows «Neste: Pantheon · 300 m» on the guided walk screen when a tour runs. It reuses the existing
  state channel.

## 8. Acceptance criteria

1. A 60 min loop from a central Rome spot plans 4–8 stops, and its routed total is within 60 min + 10 %.
2. An A→B whose direct route is 30 min plans a routed total ≤ 37.5 min + dwell, through top/good places.
3. With no candidate in range, the preview says so and offers the alternative.
4. Without network, the preview shows an approximate route and allows starting.
5. Arriving at the next stop buzzes it once and advances «Neste».
6. Closing and reopening the app restores the running tour.
7. All planner logic (insertion, 2-opt, budget, trimming, scoring) is tested in core with hand-computed cases.

## 9. Left to the builder

- Tile layout for big areas.
- Polyline simplification for storage.
- Exact progress texts.
- How the tour panel animates in the sheet.
