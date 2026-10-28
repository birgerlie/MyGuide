# MyGuide: Diary and day story — design

**Status:** draft. The owner asked for this to be built on a branch while they test the guide voice outdoors, so the questions were skipped. Every *(Claude's call)* below is open for the owner to change when they review the branch.
**Builds on:** `2026-10-28-guide-voice-design.md` (branch `guide-voice`). Parent spec 8.2 lists a "trip diary" as later work, and walking mode already records the data it needs.

## 1. Why

The owner's words (2026-10-28), condensed:

1. **Feed.** A list with one section per day, where cells look different depending on the kind of entry. Photos taken in the app already carry their position. Photos from the Photos library are imported with time and GPS from EXIF, so the day's photos can be imported afterwards and sort themselves in among the facts.
2. **Album / story.** Link each photo to the nearest fact in time and place (±10 min, ±150 m) and let the model write the caption. The photo itself is sent, so the model sees what was actually photographed and the text says "the fountain in front of you is Bernini's…", not something generic from the coordinates. One request per day: all photos plus the event list go in; a short narrative caption per photo plus a 2–3 sentence day summary come out. It is shown as full-screen pages with the text at the bottom, like an Instagram story. To share it, render one image per page; a crossfade video is a later option.

## 2. Goals, non-goals, anti-goals

**Goals**
1. A diary that shows each day as it happened: photo stories, walking stories heard, stop stories, and imported library photos, in time order.
2. A day story: a caption for each of the day's photos and a short summary, grounded in what the app told that day and in the photos themselves.
3. The day story can be shared as images.

**Non-goals (this round)**
- Video export *(Claude's call: the owner called it optional)*.
- Importing library photos automatically. The owner picks them.
- Editing captions by hand.
- Changing the History screen, the photo story flow or walking mode.

**Anti-goals**
- Captions that invent facts. The same honesty rules as the guide voice apply. A photo with no matched event gets a caption about what is visible, not made-up history.
- Imported photos being sent anywhere before the owner asks for a day story.
- A day story that silently leaves photos out. If photos are skipped, the screen says how many.

## 3. Constraints

- Same stack and rules as the guide-voice work: Swift 6, iOS 26, SwiftData, OpenAI only with `store: false`, the key in the Keychain, Swift Testing in `MyGuideCore`, and complete implementations.
- **SwiftData:** new entities only. The eight existing models stay unchanged. A store version 3 adds the new entities, with a lightweight stage from version 2. Version 2 lists its eight models explicitly, so it stays the same shape.
- Photo upload size and count are bounded so a day story costs cents, not dollars (5.3).

## 4. The diary

### 4.1 What it lists *(Claude's call)*

| Entry | Source | Time used | Shown when |
|---|---|---|---|
| Photo story | `CaptureRecord` | `takenAt` | always |
| Buzz story | `WalkStoryRecord` kind buzz | its `createdAt` | only if heard (buzz `deepestLevel` ≥ 1) |
| Stop story | `WalkStoryRecord` kind stop | its `createdAt` | always |
| Library photo | new `LibraryPhotoRecord` | the photo's capture time | always |

- Days are local calendar days in the phone's time zone. The newest day comes first. Within a day, entries run oldest first, so the day reads as a timeline.
- Day header: weekday and date, the city of that day's first located entry when known (from stored addresses, no new lookup), and a "Day story" button (4.4).
- Cells differ by kind:
  - Photo story: thumbnail, title, time.
  - Buzz: a walking icon, title, place name, time.
  - Stop: a pin icon, title, time.
  - Library photo: thumbnail, time, and its caption once a day story exists.
- Tapping a photo story opens the existing `StoryView`. Tapping a buzz or stop story opens the existing `WalkStoryView`. Tapping a library photo opens it full screen.
- Swiping deletes a library photo. Other kinds are deleted where they are deleted today (History). The diary does not delete them *(Claude's call: one place for deleting stories)*.

### 4.2 Where it lives *(Claude's call)*

A "Diary" button on the Home screen, next to History, opens the diary in the existing navigation stack.

### 4.3 Importing library photos

- An "Add photos" toolbar button opens `PhotosPicker`, which allows multiple selection, up to 30 photos at once.
- **Time:**
  - First choice: the EXIF capture time, via the existing `PhotoMetadata`.
  - If there is none: the `PHAsset` creation date (after asking for read access, as `PhotoImport` does).
  - If neither exists, the photo is skipped and the owner is told how many were skipped.
- **Position:** EXIF GPS, otherwise the `PHAsset` location, otherwise none. A photo with no position still appears in the diary by time, and in the day story it is matched by time only (5.1).
- **Stored per photo:**
  - a 1536 px JPEG and a 400 px thumbnail, the same sizes as photo stories;
  - the capture time and optional coordinate;
  - the PhotoKit local identifier, so importing the same photo again is skipped.
- Nothing is sent to any service on import.

### 4.4 Day story button

The button is enabled when the day has at least one photo (photo story or library photo). If the day already has a day story, the button opens it, and a "Write again" action on the story screen replaces it.

## 5. The day story

### 5.1 Matching photos to events (core, pure)

- **Events** are the day's diary entries that are not library photos: photo stories, heard buzz stories and stop stories. Each event has a time, a position (when known), a title, a place name and its first level's first sentence.
- **Photos** are the day's library photos plus the photos of photo stories. A photo story's photo is matched to its own story.
- **Match rule:** a library photo matches the event with the smallest time gap among events within **±10 minutes**. When both the photo and the event have positions, the event must also be within **150 m**. No match is fine.
- **Upload cap:** the photos are taken in time order, at most **12** *(Claude's call: cost)*. When a day has more, 12 are chosen evenly spread over the day (first and last always included), and the story screen says "12 of N photos".

### 5.2 The request

- **System instructions:** one new constant, `PromptBuilder.dayStoryInstructions`. It uses the guide's honesty rules (the HONESTY section of the guide-voice prompt, word for word) and these task rules:
  - Write a caption for each photo: what is in the frame first, then the matched event's facts. At most 40 words, warm and specific, no greetings.
  - Then write a 2–3 sentence summary of the day as a walk the owner took.
  - Never state facts that are not in the event list or clearly visible in a photo.
  - Answer in the language named.
- **User message:** structured like the guide-voice requests.
  ```
  Day: Wednesday 28 October 2026, Oslo
  Events:
  - 11:58 walking buzz: Akershus Fortress (historic=castle) — "first sentence"
  - 12:40 photo story: Oslo Cathedral — "first sentence"
  Photos (in the order the images are attached):
  - [p1] 12:03, matches 11:58 Akershus Fortress
  - [p2] 12:41, photo story: Oslo Cathedral
  - [p3] 13:10, no matching event
  Answer in: Norwegian Bokmål
  Task: Write one caption per photo id, then the day summary.
  ```
  - Each photo is attached as an image, downscaled to **768 px** on the long side at JPEG quality 0.7.
  - `prompt_cache_key: "myguide-day-v1"`.
- **Schema (strict):** `{ "summary": string, "captions": [ { "photoID": string, "caption": string } ] }`.
  - A caption for an unknown id is dropped.
  - A photo with no caption shows no caption.
  - An empty summary counts as a malformed response.
- **Cost:** recorded in usage like other story requests.

### 5.3 Stored

- `DayStoryRecord`: the day key (`yyyy-MM-dd`, unique), `createdAt`, language, summary, captions as JSON (photo id → caption), photo ids in page order, and the total number of photos that day.
- A photo id is `capture:<uuid>` or `library:<uuid>`.
- Writing it again replaces the record.
- Deleting a library photo removes its caption, and its page drops out of the day story.

### 5.4 Viewing

- Full-screen `TabView` with `.page` style.
- Page 1 is the summary over the first photo. Each following page is one photo with its caption at the bottom on a dark gradient. The time is in the corner.
- A close button and a share button.
- When photos were left out: "12 of N photos" under the summary.

### 5.5 Sharing

- The share button renders each page to an image with `ImageRenderer` (1080 × 1920) and offers them through the share sheet.

## 6. Failure behaviour

- No API key: the button shows the existing missing-key message.
- Request fails: an alert with the existing user-facing error text. Nothing is stored.
- A photo whose bytes cannot be loaded for upload is skipped and counted, like over-cap photos.
- Import failures are counted and reported once per import.

## 7. Left to the builder

- Exact cell layouts and icons.
- The ImageRenderer page view's typography.
- The diary query strategy (fetching per kind and merging in Swift is fine).

## 8. Settled during the builder check *(Claude's calls)*

1. **Photo-story photos are captioned too.** Their story appears once, in the event list. The photo line only says `photo story: <title>`, without repeating its sentence.
2. **"Heard" buzz:** the `BuzzRecord` with the walk story's id has `deepestLevel ≥ 1` (buzz id = walk story id, as in `MemoryStore.priorStories`).
3. **First sentence:** `RecentStories.firstSentence` of the story's level 1 text.
4. **Event positions for the 150 m rule:**
   - buzz story: the buzzed place's coordinate (from `placeJSON`);
   - stop story: the story's position;
   - photo story: the capture coordinate.
5. **Library photo time:** whatever `PhotoMetadata` yields as `takenAt`, which already handles EXIF. Days and clock times use the phone's current time zone.
6. **Stale day stories:** a day story stays as written when photos are added or deleted later. A deleted photo's page drops out, the rest keep their order, and "Write again" rebuilds the whole story.
7. **City in the day header:** `Address.city`, taken from the day's first entry that has one. That is a walk story's decoded `addressJSON` or a capture's grounding address. With none, there is no city.
8. **Images:** each is attached at `detail: "low"`. `OpenAIClient.respond` gains a multi-image variant; the single-image call is unchanged.
9. **Model and usage:** the story model and reasoning effort (`OpenAIModels.story`), recorded as usage kind `.story`.
