# MyGuide: guide server — the OpenAI key leaves the app

Status: written by Claude on 2026-10-30 from the conversation with the owner. The owner approves before anything is
installed. Every decision not quoted from the owner is marked *(Claude's call)*.

## 1. Why

- The App Store needs it. TestFlight builds carry the owner's OpenAI key (`OPENAI_BUNDLED_KEY`). Anyone who
  downloads a public app could pull the key out and spend on the owner's account. The App Store plan in this
  conversation lists this as the one blocker.
- The owner chose their own server: «vi kan jo bare kjøre den på min ssh server?»
- The owner keeps full personalisation: «jeg syntes det personlige er noe som gjør det ekstra bra». So the server
  caches no stories. Every story is made for one walker at one moment, as today.
- Payment later. Monetisation memory: RevenueCat credits and a small server that debits before each call. This
  server is that server, with a free daily quota first. Credits come in a later part.

## 2. Goals, non-goals, anti-goals

**Goals**
1. The app reaches OpenAI only through `https://myguide.itsalie.xyz`. The key lives only on the server.
2. Only the real MyGuide app on a real iPhone gets an answer. Apple App Attest proves it.
3. Each device gets a free daily quota, and the server enforces it before every call. A call that fails upstream
   gives its unit back.
4. One daily spend cap for the whole server stops everything when the money for the day is used. It sits below
   the limit set at OpenAI.
5. What the app sends today reaches OpenAI unchanged: the same prompts, the same personal context, the same
   streaming. The stories are as good as before.
6. A log of calls and their cost, with no content. The owner can see what a day cost.

**Non-goals (this part):** buying credits (StoreKit, receipt checks, refunds from Apple, Sign in with Apple), which
comes in its own spec; the credit ledger itself is in this part (6.2); accounts and sign-in; caching stories; switching to Kimi (the
server makes that possible later); Android; an admin web page.

**Anti-goals**
- The server keeps a photo, a position, a prompt or a story.
- One user can drain the day's budget.
- The server goes down and the app silently tells nothing.
- MyGuide disturbs Suverra on the same machine.

## 3. Constraints

- **Machine:** the owner's Hetzner VPS `204.168.153.170`, with Ubuntu 26.04, 1 vCPU, 1 GB RAM, 19 GB disk and
  Python 3.14.4. It is shared with Suverra (`kunngjoring-*` timers, user `kunngjoring`, `/opt/kunngjoring`,
  `/srv/kunngjoringer`). Nothing of Suverra is touched.
- **Domain:** `myguide.itsalie.xyz` (A record to the VPS, Namecheap DNS, the owner's company It's a Lie Venture).
- **Carried over from earlier specs:**
  - `store: false` on every Responses call;
  - the key never in source;
  - the repo is public, so the server code goes in it and no secret does;
  - the user's email is never sent anywhere;
  - the watch never holds a key or a token.
- **No push or deploy without asking.** The deploy itself needs the owner's go.

## 4. Shape

```
iPhone app ──HTTPS──▶ Caddy (443, Let's Encrypt) ──▶ guide service (127.0.0.1:8710) ──HTTPS──▶ api.openai.com
                                                       │
                                                       └─ SQLite /srv/myguide/guide.db
```

- **Caddy** terminates TLS for `myguide.itsalie.xyz` and proxies to the service. It never buffers streamed
  answers (`flush_interval -1`).
- **The guide service** is Python 3.14 with Starlette, uvicorn, httpx, cbor2 and cryptography, pinned in
  `requirements.txt` and installed in a venv in `/opt/myguide` *(Claude's call: small and readable, and the
  machine already has Python)*.
  - It runs as the system user `myguide` under systemd.
  - Limits: `MemoryMax=200M`, `CPUWeight=50`, so Suverra keeps priority when both are busy. Suverra has the default
    weight of 100.
- **Secrets** live in `/etc/myguide/env`, owned by `root:myguide` with mode `0640`: the OpenAI key, the Apple team
  id and bundle id, and the limits.
- **Firewall:** ufw allows 22, 80 and 443 in. All outbound traffic stays open, so Suverra's downloads are unaffected.
- **The code** lives in the repo in `server/`, with the Caddyfile, the systemd unit and an install script. Deploy
  is `server/deploy.sh`: rsync over ssh, then restart.

## 5. Proving the app: App Attest

Apple App Attest (DeviceCheck framework) is on every iPhone the app supports.

1. **Challenge.** `POST /v1/attest/challenge` returns `{challenge}`: 32 random bytes in base64, valid for 5 minutes
   and good for one use.
2. **Attest.** The app makes an App Attest key (`DCAppAttestService.generateKey`). It attests the key with
   SHA-256(challenge) and sends `POST /v1/attest {keyId, attestation, challenge}`.
3. **The server checks the attestation as Apple's documentation describes:**
   - the certificate chain up to Apple's App Attest root;
   - the nonce extension equals SHA-256(authData ‖ SHA-256(challenge));
   - the RP id hash equals SHA-256("TEAMID.io.github.birgerlie.MyGuide");
   - the counter is 0;
   - the aaguid is `appattest` (production: TestFlight and App Store). `appattestdevelop` (Xcode installs) is
     accepted only while `ALLOW_DEVELOPMENT_ATTEST=1`, which stays on during testing.
4. **Token.** On success the server returns `{token}`: 32 random bytes in base64url. It stores only SHA-256(token)
   with the key id and the device row. The app keeps the token in the Keychain.
5. **Every call** carries `Authorization: Bearer <token>`. That is the header the app already sends, so
   `OpenAIClient` needs no new code path.
   - An unknown or blocked token gets 401 `{"error":{"code":"attest_required"}}`.
   - The app then attests again once and retries once.

*(Claude's call: attest once, then a bearer token, instead of an App Attest assertion on every request. TLS protects
the token. A stolen token can only spend that device's quota. Per-request assertions can come later if abuse shows
up.)*

**Where App Attest is missing** (the simulator, Mac Catalyst): the app uses the key entered in Settings directly
against OpenAI, as today. Without one, it shows the existing missing-key text. The bundled key goes away (section 8).

## 6. Calls and quota

**Allowed paths** go to `https://api.openai.com/v1/<same path>`. Everything else gets 404.

| Path | Kind | Models allowed |
|---|---|---|
| `POST /v1/responses` (plain or `"stream": true`) | `story` | `gpt-5-mini` |
| `POST /v1/audio/speech` | `speech` | `gpt-4o-mini-tts` |
| `POST /v1/images/generations` | `image` | `gpt-image-2.5-flare` |

**Each request is checked before it is forwarded:**
- the body is at most 8 MB, which is room for the photo story's base64 JPEGs;
- the model is on the list;
- for `responses`, `store` is set to `false` whatever the app sent.

The rest of the body passes through as sent. The personal context stays in the prompt.

**Free daily quota per device**, counted per UTC day. The values are defaults; every number is a setting (6.1):
- `story` 80;
- `speech` 80;
- `image` 4 (day stories);
- at most 15 requests per minute in total.

**Unit lifecycle:**
- One unit is reserved before the call (debit first).
- The unit is kept when OpenAI answers 2xx.
- The unit is returned on a 5xx, a timeout, a network failure, or a stream that ends without its final event.
- On a 4xx from OpenAI, the unit is returned and the 4xx is passed on as it is.

**Token and request limits** (owner: «vi må også ha requests pr enhet, og antall tokens brukt pr enhet»):
- **Every request counts** against `REQUESTS_PER_DEVICE_PER_DAY` and the per-minute limit. Requests the server turns
  away (401, 404, 429) are counted too, so a device that hammers the server is seen and stopped.
- **Tokens are known only after the call:** a call is allowed while the device's tokens used today are below
  `TOKENS_PER_DEVICE_PER_DAY`. Its tokens are added from its `usage` when it ends, so one call can take the device
  over the limit, and the next call is then refused. Speech characters work the same way against
  `SPEECH_CHARS_PER_DEVICE_PER_DAY`.

**Over quota:** 429 `{"error":{"code":"daily_quota","message":"…"}}`. The app shows «Dagens gratis historier er brukt
opp. Prøv igjen i morgen.» / «Today's free stories are used up. Try again tomorrow.»

**Daily spend cap for the whole server:**
- The cost of each call is computed from its `usage` (Responses, images) or from the input characters (speech),
  using a price table in the env file. The table is the owner's to keep current.
- When the day's sum reaches `DAILY_SPEND_CAP_USD`, every call gets 503 `{"error":{"code":"server_budget"}}`
  until midnight UTC. *(Claude's call: the default is 5 USD.)*
- The app shows «Guiden tar en pause akkurat nå. Prøv igjen senere.» / «The guide is taking a break right now.
  Try again later.»

**Streaming:** the server passes the SSE stream through byte for byte. It reads the final `response.completed` event
for `usage` on its way through.

## 6.1 Configuration

The owner: «lag alle grenser som konfigurasjon». Every limit and number in this spec is a setting in
`/etc/myguide/env`. None is a constant in the code. The values below are the defaults the install script writes
*(Claude's call)*.

- **Changing limits:** `myguide-admin reload` (SIGHUP) reads the file again without dropping calls in progress.
- **Bad values:** a missing or invalid value stops the service at start with a message that names the setting. It
  never falls back silently.
- **Viewing them:** `myguide-admin limits` prints every setting, with the key shown as `<set>` or `<missing>`.

| Setting | Default | What it limits |
|---|---|---|
| `QUOTA_STORY_PER_DAY` | 80 | `responses` calls per device per UTC day |
| `QUOTA_SPEECH_PER_DAY` | 80 | `audio/speech` calls per device per day |
| `QUOTA_IMAGE_PER_DAY` | 4 | `images/generations` calls per device per day |
| `RATE_PER_MINUTE` | 15 | requests per device per minute, all kinds |
| `REQUESTS_PER_DEVICE_PER_DAY` | 200 | requests per device per UTC day, all kinds together, on top of the per-kind counts |
| `TOKENS_PER_DEVICE_PER_DAY` | 1500000 | input + output tokens per device per UTC day, from the `usage` of Responses and image calls (cached input counts too) |
| `SPEECH_CHARS_PER_DEVICE_PER_DAY` | 200000 | characters sent to speech per device per UTC day (speech reports no tokens) |
| `DAILY_SPEND_CAP_USD` | 5.00 | cost of all calls per UTC day before 503 |
| `DEVICE_SPEND_CAP_USD` | 1.00 | cost per device per UTC day, a second guard beside the counts |
| `MAX_BODY_BYTES` | 8388608 | request body size (8 MB) |
| `UPSTREAM_TIMEOUT_SECONDS` | 120 | one call to OpenAI, streamed or not |
| `CHALLENGE_TTL_SECONDS` | 300 | how long an attest challenge is valid |
| `ATTESTS_PER_IP_PER_HOUR` | 20 | attest attempts from one IP address, counted in memory only, never stored |
| `ALLOW_DEVELOPMENT_ATTEST` | 1 | accept `appattestdevelop` (Xcode installs); set to 0 before the App Store release |
| `MODELS_STORY` / `MODELS_SPEECH` / `MODELS_IMAGE` | `gpt-5-mini` / `gpt-4o-mini-tts` / `gpt-image-2.5-flare` | allowed models per kind, comma-separated |
| `PRICE_*` | OpenAI's list prices on install day | USD per million input, cached input and output tokens per model, and per million speech characters |
| `LOG_RETENTION_DAYS` | 90 | how long log rows are kept (the credit ledger is never pruned) |
| `CREDITS_PER_STORY` / `CREDITS_PER_SPEECH` / `CREDITS_PER_IMAGE` | 1 / 0 / 2 | credits a call costs once the free quota of its kind is used up (6.2) |
| `APPLE_TEAM_ID` / `APPLE_BUNDLE_ID` | `MW432M4HL3` / `io.github.birgerlie.MyGuide` | the App Attest RP id |
| `OPENAI_API_KEY` | (none) | the key; the service will not start without it |
| `LISTEN_PORT` | 8710 | local port behind Caddy |

The systemd limits (`MemoryMax=200M`, `CPUWeight=50`) are configuration too: they sit in a drop-in,
`/etc/systemd/system/myguide.service.d/limits.conf`, that the owner can change without touching the unit.

## 6.2 Credits

The owner said «ja, legg det inn»: the credit ledger is built now, so payment can be added later without rebuilding
anything. Credits can only be given by hand for now, with `myguide-admin grant`, for example to testers who use up
the free quota. Buying them comes in a later spec.

**Wallets**
- Every device gets a wallet when it attests. The ledger is keyed by wallet, not by device. Later, Sign in with Apple
  can move a buyer's devices onto one wallet so their credits follow them to a new phone, with no change to the
  ledger.
- A wallet's balance is the sum of its entries. Entries are only ever added, never changed or deleted.
- Each entry has a delta, a reason (`grant`, `debit`, `refund`, later `purchase` and `revoke`), a reference (the call
  id, the admin note, later Apple's transaction id) and a time.
- A reference can be used once per reason. So a purchase can never be counted twice, and a call never debited twice.

**What a call costs** (all settings, see 6.1):
- `CREDITS_PER_STORY` default 1;
- `CREDITS_PER_SPEECH` default 0, so reading a story aloud is part of the story *(Claude's call)*;
- `CREDITS_PER_IMAGE` default 2.

**Free first, then credits**
1. The per-kind daily quota is used first.
2. When that is used up, the call's credits are debited before it is forwarded, in the same SQLite transaction
   (`BEGIN IMMEDIATE`) that checks the balance. The balance can never go below 0, even with calls from two devices on
   one wallet at the same moment.
3. A call that fails upstream gets a `refund` entry with the same reference: 5xx, timeout, network failure, a stream
   with no final event, or a 4xx.
4. No quota and too few credits: 429 `daily_quota`. The app shows the quota text as in section 6. A «Kjøp flere»
   button comes with payment.

**Abuse guards still apply to everyone, paying or not:**
- the rate per minute;
- requests, tokens and speech characters per device per day;
- the device and server spend caps.

Their defaults are generous. If a paying user hits them, the owner raises them (6.1).

**Telling the app:** every answer carries `X-MyGuide-Free-Left: story=12,speech=40,image=4` and
`X-MyGuide-Credits: 37`. The app does not show them yet, but logs them in the walk log, so the owner can see the
balance during a test.

**Admin**
- `myguide-admin grant <device> <credits> <note>` adds credits.
- `balance <device>` shows the balance.
- `ledger <device>` shows the entries.

The `devices` view gains a balance column.

## 7. Log and admin

- **Every call writes one row:**
  - time;
  - device id (an internal number, not the token);
  - kind and model;
  - status;
  - latency in ms;
  - input, output and cached tokens;
  - speech characters;
  - cost in USD;
  - whether the unit was kept.

  There are no bodies, no prompts, no positions and no IP addresses. Rows are kept 90 days.
- **`myguide-admin` on the server** (run as root):
  - `today` and `days 7`: calls, tokens, cost and devices per day;
  - `devices [days]`: one line per device, with requests (allowed and refused), input, output and cached tokens,
    speech characters and cost, for today or the last `days` days, highest cost first;
  - `device <id>`: the same per day, and per kind, for one device;
  - `block <id>` and `unblock <id>`;
  - `limits`: the current limits from the env file;
  - `reload`: read the env file again (6.1).
- **`GET /health`** returns `{"ok":true}`, for a quick check from outside.

## 8. Changes in the app

- **`OpenAIClient`'s base URL** becomes `https://myguide.itsalie.xyz/v1` whenever no key of the owner's own is
  stored. Its `apiKey` is then the server token. The type stays the same, and the token is redacted the same way.
- **A `GuideServerSession`** (core, actor) gets and keeps the token:
  - challenge, attest, token in the Keychain;
  - re-attest once on 401;
  - never more than one attestation in flight.
  - The App Attest call itself sits behind a protocol in the app, so the core is testable.
- **New error cases with screen texts:** `dailyQuota` and `serverBudget` in `OpenAIError`. `attestUnavailable`
  falls back to «Legg inn en egen OpenAI-nøkkel i Innstillinger», as now.
- **The bundled key is removed:**
  - `OPENAI_BUNDLED_KEY`;
  - `MGBundledOpenAIKey`;
  - the bundled branch of `APIKeySource`;
  - the Settings line.

  TestFlight builds go through the server too.
- **A key of the owner's own in Settings still works** and goes straight to OpenAI. It is used for the simulator and
  for testing.
- **The walk log gets the server's two headers** (`X-MyGuide-Free-Left`, `X-MyGuide-Credits`) after each call, as a
  new optional field. Old lines still decode.
- **The watch is unchanged.** It never talks to OpenAI.

## 9. Acceptance criteria

1. A fresh install on the owner's iPhone (Xcode, development attest) tells a walking story, a photo story and a day
   story through the server. The log shows three rows with cost and `kept = 1`.
2. A request without a token, with a made-up token, or from `curl` gets 401. A model not on the list gets 400. An
   unknown path gets 404.
3. With the default limits, the 81st story call of the day gets 429 and the app shows the quota text. Calls work again the next UTC day.
4. An upstream failure returns the unit, as the admin `device` view shows.
5. Over the spend cap, everything gets 503 and the app shows the pause text.
5a. After the quota is used, `grant` 3 credits to the owner's device: three more story calls work, and the balance
    goes 3 → 2 → 1 → 0. The fourth gets 429. A story call that fails upstream leaves the balance unchanged (one
    debit and one refund entry).
6. A streamed photo story streams through the server as fast as directly, within about 100 ms of extra latency.
7. `grep` of the database and journal for a prompt word, a coordinate or a photo finds nothing.
8. Suverra's timers run as before after the install: `systemctl list-timers` and the last runs in the journal.
9. Server logic is tested with pytest:
   - attestation checks with a test chain made in the test (valid, wrong RP id, wrong nonce, counter ≠ 0,
     development aaguid with and without the flag);
   - quota reserve, keep and return;
   - credits:
     - free quota first, then credits;
     - debit and refund with the same reference;
     - a reference counted once;
     - a balance that never goes below 0 under two concurrent calls on one wallet;
     - the cost per kind from the settings;
   - requests per device per day, refused ones included;
   - tokens per device: allowed below the limit, refused once a call's `usage` took it over; the same for speech
     characters;
   - the day boundary;
   - the spend cap;
   - configuration: every setting read from the env file, a bad or missing value stopping the start with the
     setting's name, and reload changing a limit without a restart;
   - the model and path lists;
   - `store` forced to false;
   - stream pass-through with and without the final event.

   App changes are tested in core with hand-computed cases, as the project does.

## 10. Left to the builder

- File layout inside `server/`.
- SQLite schema details.
- The exact SSE parsing.
- The admin command's output format.
- The wording of the error JSON messages, which the app does not show.
