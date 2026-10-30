# Guide server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The app reaches OpenAI only through `https://myguide.itsalie.xyz`, a small Python service that proves the app with App Attest, enforces quotas, abuse limits, spend caps and a credit ledger, and passes calls through unchanged. The bundled key leaves the app.

**Architecture:** A Starlette service in `server/myguide/` with SQLite (stdlib `sqlite3`, WAL) holds devices, wallets, the ledger, per-device day counters and a content-free call log. Every limit comes from `/etc/myguide/env`. In the app, a decorating `HTTPClient` (`GuideServerHTTPClient`) puts the server token on each request and re-attests once on 401. `OpenAIClient` is unchanged apart from three new error cases.

**Tech Stack:** Python 3.14, Starlette, uvicorn, httpx, cbor2, cryptography, pytest (+ pytest-asyncio not needed: use Starlette `TestClient` and `httpx.MockTransport`). Swift 6 / Swift Testing in `Packages/MyGuideCore`, XcodeGen app.

**Spec:** `docs/superpowers/specs/2026-10-30-guide-server-design.md` (approved 2026-10-30, «ja, godkjent – kjør på»).

## Global Constraints

- Never deploy, ssh to or install on `204.168.153.170`. Deploy happens only after the owner says go. Nothing of Suverra (`kunngjoring-*`, `/opt/kunngjoring`, `/srv/kunngjoringer`) is ever touched by any script.
- No secret in the repo: the OpenAI key exists only in `/etc/myguide/env` on the server. The env template in the repo has `OPENAI_API_KEY=` empty. `Config/Local.xcconfig` stays git-ignored and is never read, printed or committed.
- The server stores no request or response body, prompt, position, photo, story or IP address: not in SQLite, not in logs. uvicorn runs with `--no-access-log`. The Caddyfile has no `log` directive. Python `logging` lines never include bodies.
- `store` is forced to `false` on every `/v1/responses` body.
- Every limit is a setting (spec 6.1 table), with the defaults shown there. None is a constant in code. A missing or invalid setting raises `ConfigError` naming the setting.
- Money is integer micro-USD (`µUSD`, 1e-6 USD) everywhere in code and DB; `PRICE_*` values are USD per million, so `cost_µUSD = tokens × price_per_million` (Decimal, rounded half-up to int once per call).
- Day = UTC calendar date (`YYYY-MM-DD`) of the request's `now`.
- Server tests run with `/opt/homebrew/bin/python3.14` in a venv at `server/.venv` (git-ignored): `cd server && .venv/bin/pytest -q`.
- Swift: Swift 6 strict concurrency; core tests `cd Packages/MyGuideCore && swift test`; app build `xcodegen generate && xcodebuild -project MyGuide.xcodeproj -scheme MyGuide -destination 'generic/platform=iOS' build` (restore `MyGuide.xcodeproj/project.pbxproj` with `git checkout --` if xcodegen rewrites it and it is not part of the task).
- User-visible copy, exactly: `dailyQuota` «Dagens gratis historier er brukt opp. Prøv igjen i morgen.» / «Today's free stories are used up. Try again tomorrow.»; `serverBudget` «Guiden tar en pause akkurat nå. Prøv igjen senere.» / «The guide is taking a break right now. Try again later.»; `attestUnavailable` «Legg inn en egen OpenAI-nøkkel i Innstillinger.» / «Add your own OpenAI API key in Settings.»
- Error JSON shape from the server: `{"error":{"code":"<code>","message":"<text>"}}`. Codes: `attest_required` (401), `blocked` (403), `not_found` (404), `model_not_allowed` (400), `bad_request` (400), `body_too_large` (413), `rate_limited` (429), `daily_quota` (429), `server_budget` (503), `upstream_unreachable` (502).
- Every proxy answer (2xx or refusal after auth) carries `X-MyGuide-Free-Left: story=<n>,speech=<n>,image=<n>` and `X-MyGuide-Credits: <n>`.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Work on branch `guide-server`. No push.

## Rulings made in this plan (Claude's calls beyond the spec)

1. **Token in a decorating HTTPClient** instead of passing the token as `OpenAIClient.apiKey`: getting a token is async (attest), `makeOpenAI()` is sync. `OpenAIClient` gets the placeholder key `"guide-server"`; `GuideServerHTTPClient` overwrites `Authorization`. Cost if wrong: none for behaviour; the placeholder never leaves the device (it is replaced before sending).
2. **Abuse-guard refusals** (requests/day, tokens/day, speech chars/day, device spend cap) answer 429 `daily_quota`, so the app shows the quota text; the per-minute rate answers 429 `rate_limited` (app: «OpenAI er opptatt…»). Server spend cap: 503 `server_budget`.
3. **Re-attest keeps the wallet:** `POST /v1/attest` takes optional `previousToken`; when it matches a non-blocked device, that device is re-keyed and gets a new token (credits and counters stay). A blocked match answers 403 `blocked`. No match → new device and wallet.
4. **Per-minute rate and attest-per-IP** are counted in memory (sliding 60 s / 3600 s windows); a restart resets them. Challenges are in memory too (single process).
5. **Tokens limit** applies to `story` and `image`; the **speech-chars limit** to `speech`.
6. `CREDITS_PER_SPEECH=0` means speech past its free quota is allowed with no debit (spec: «reading a story aloud is part of the story»); abuse guards still bound it.
7. **Install-day prices** in the env template are Claude's best knowledge and must be checked by the owner at openai.com/api/pricing before deploy: `PRICE_GPT_5_MINI=0.25,0.025,2.00`, `PRICE_GPT_IMAGE_2_5_FLARE=5.00,1.25,40.00` (deliberately high), `PRICE_SPEECH_GPT_4O_MINI_TTS=15.00` (USD per million characters).
8. The walk log writes a `server` line only when the allowance differs from the last one written in that run.

## Review Focus

1. **Client disconnects mid-stream** — the unit must be settled exactly once (returned if `response.completed` was not seen), never left reserved and never double-refunded. Test in Task 6.
2. **Two concurrent paid calls on one wallet with balance 1** — exactly one is admitted. Test in Task 3.
3. **Upstream timeout / connection refused** — the app gets 502 `upstream_unreachable`, the unit is returned, the call log row has `kept=0`. Test in Task 6.
4. **Midnight UTC between admit and settle** — settle returns the unit to the day it was reserved on, not the new day. Test in Task 3.
5. **Two app calls hit 401 at once** — exactly one attestation runs; both retry with the new token. Test in Task 10.

---

### Task 1: Server scaffolding and configuration

**Files:**
- Create: `server/requirements.txt`, `server/requirements-dev.txt`, `server/pyproject.toml` (pytest config only: `testpaths = ["tests"]`, `pythonpath = ["."]`), `server/.gitignore` (`.venv/`, `__pycache__/`, `*.db`), `server/myguide/__init__.py`, `server/myguide/config.py`, `server/env.template`
- Test: `server/tests/test_config.py`

**Interfaces:**
- Produces:
  - `class ConfigError(Exception)` — message starts with the setting name, e.g. `"QUOTA_STORY_PER_DAY: must be a whole number >= 0, got 'abc'"`.
  - `@dataclass(frozen=True) class Price: input_per_m: Decimal; cached_input_per_m: Decimal; output_per_m: Decimal`
  - `@dataclass(frozen=True) class Settings` with fields: `quota_story_per_day, quota_speech_per_day, quota_image_per_day, rate_per_minute, requests_per_device_per_day, tokens_per_device_per_day, speech_chars_per_device_per_day: int`; `daily_spend_cap_micro, device_spend_cap_micro: int` (from USD); `max_body_bytes, upstream_timeout_seconds, challenge_ttl_seconds, attests_per_ip_per_hour, log_retention_days, credits_per_story, credits_per_speech, credits_per_image, listen_port: int`; `allow_development_attest: bool`; `models_story, models_speech, models_image: frozenset[str]`; `token_prices: dict[str, Price]` (story and image models); `speech_char_prices: dict[str, Decimal]` (speech models, USD per million chars); `apple_team_id, apple_bundle_id, openai_api_key: str`; method `quota(kind: str) -> int`, `credits(kind: str) -> int`, `models(kind: str) -> frozenset[str]`, `app_id -> str` (`f"{apple_team_id}.{apple_bundle_id}"`), `redacted() -> list[tuple[str, str]]` (every setting name and value, key as `<set>`/`<missing>`).
  - `parse_settings(env: Mapping[str, str]) -> Settings`, `load_settings(path: Path) -> Settings` (reads `KEY=VALUE` lines, `#` comments and blank lines ignored, values not quoted).
  - `KINDS = ("story", "speech", "image")`.

- [ ] **Step 1:** Create a venv: `/opt/homebrew/bin/python3.14 -m venv server/.venv && server/.venv/bin/pip install starlette uvicorn httpx cbor2 cryptography pytest`, then write `requirements.txt` (the five runtime packages) and `requirements-dev.txt` (`-r requirements.txt` + pytest) with the exact installed versions (`==`, from `pip freeze`).
- [ ] **Step 2: Write `env.template`** with every spec 6.1 setting and its default, `OPENAI_API_KEY=` empty, prices as in Ruling 7, a comment line above each group. Price syntax: `PRICE_<MODEL>=<input>,<cached_input>,<output>` for story/image models and `PRICE_SPEECH_<MODEL>=<per million chars>` for speech models; `<MODEL>` is the model name uppercased with `-` and `.` replaced by `_`.
- [ ] **Step 3: Write failing tests** in `test_config.py`:
  - `test_template_defaults` — `parse_settings` of the template with `OPENAI_API_KEY=sk-test` gives `quota_story_per_day == 80`, `quota_image_per_day == 4`, `rate_per_minute == 15`, `requests_per_device_per_day == 200`, `tokens_per_device_per_day == 1_500_000`, `speech_chars_per_device_per_day == 200_000`, `daily_spend_cap_micro == 5_000_000`, `device_spend_cap_micro == 1_000_000`, `max_body_bytes == 8_388_608`, `credits("speech") == 0`, `credits("image") == 2`, `models("story") == {"gpt-5-mini"}`, `app_id == "MW432M4HL3.io.github.birgerlie.MyGuide"`, `token_prices["gpt-5-mini"] == Price(Decimal("0.25"), Decimal("0.025"), Decimal("2.00"))`.
  - `test_template_has_empty_key_and_start_refuses` — template as is → `ConfigError` whose message starts with `OPENAI_API_KEY`.
  - parametrized `test_bad_value_names_setting` over: each int setting missing; `QUOTA_STORY_PER_DAY=abc`; `RATE_PER_MINUTE=-1`; `DAILY_SPEND_CAP_USD=five`; `ALLOW_DEVELOPMENT_ATTEST=yes` (only `0`/`1`); `MODELS_STORY=` empty; a model in `MODELS_STORY` with no `PRICE_` line (message names `PRICE_GPT_5_MINI`); `PRICE_GPT_5_MINI=0.25,0.025` (two parts) → message starts with that setting name.
  - `test_usd_to_micro` — `DAILY_SPEND_CAP_USD=5.00` → 5_000_000; `0.000001` → 1; `1.5` → 1_500_000.
  - `test_redacted_hides_key` — no value in `redacted()` contains `sk-test`; the `OPENAI_API_KEY` row is `<set>`.
  - `test_load_settings_reads_file` — `tmp_path` file with comments and blank lines parses like the dict.
- [ ] **Step 4:** Run `cd server && .venv/bin/pytest -q tests/test_config.py` → fails (no module).
- [ ] **Step 5:** Implement `config.py`.
- [ ] **Step 6:** Run the tests → pass.
- [ ] **Step 7:** Commit `feat(server): settings from the env file, every limit configurable (spec 6.1)`.

### Task 2: Database, devices and the credit ledger

**Files:**
- Create: `server/myguide/db.py`, `server/myguide/ledger.py`
- Test: `server/tests/test_ledger.py`

**Interfaces:**
- Consumes: nothing from Task 1 except `KINDS`.
- Produces:
  - `connect(path: str | Path) -> sqlite3.Connection` — `isolation_level=None` (explicit transactions), `PRAGMA journal_mode=WAL`, `PRAGMA busy_timeout=5000`, `PRAGMA foreign_keys=ON`, `row_factory=sqlite3.Row`; creates the schema if missing (idempotent).
  - Schema tables (names fixed, columns the builder's): `wallets(id)`, `devices(id, key_id UNIQUE, token_hash UNIQUE, wallet_id, blocked, created_at)`, `ledger(id, wallet_id, delta, reason, reference, created_at, UNIQUE(reason, reference))`, `device_days(device_id, day, used_story, used_speech, used_image, requests, refused, tokens_in, tokens_out, tokens_cached, speech_chars, cost_micro, PRIMARY KEY(device_id, day))`, `server_days(day PRIMARY KEY, cost_micro)`, `calls(id, call_id UNIQUE, at, day, device_id, kind, model, status, latency_ms, tokens_in, tokens_out, tokens_cached, speech_chars, cost_micro, kept, paid_with)`.
  - `create_device(conn, key_id: str, token_hash: str, now: datetime) -> int` (new wallet + device in one transaction), `rekey_device(conn, device_id: int, key_id: str, token_hash: str) -> None`, `device_by_token_hash(conn, token_hash: str) -> sqlite3.Row | None`, `set_blocked(conn, device_id: int, blocked: bool) -> None`.
  - `ledger.balance(conn, wallet_id: int) -> int`, `ledger.add_entry(conn, wallet_id: int, delta: int, reason: str, reference: str, now: datetime) -> bool` (False when `(reason, reference)` exists; never raises for that), `ledger.entries(conn, wallet_id: int) -> list[sqlite3.Row]`, `ledger.grant(conn, wallet_id, credits: int, note: str, now) -> bool` (reason `grant`, reference `grant:<now ISO>:<note>`; `credits` must be > 0 else `ValueError`), `ledger.try_debit(conn, wallet_id, credits: int, reference: str, now) -> bool` — must be called inside an open `BEGIN IMMEDIATE`; inserts `-credits` with reason `debit` only when `balance >= credits`, `ledger.refund(conn, wallet_id, credits: int, reference: str, now) -> bool` (reason `refund`, `+credits`, only if a `debit` with that reference exists and no `refund` yet).
  - `REASONS = ("grant", "debit", "refund", "purchase", "revoke")`; a CHECK constraint enforces it.

- [ ] **Step 1: Write failing tests** (`tmp_path` DB file):
  - `test_new_device_has_empty_wallet` — balance 0.
  - `test_grant_then_balance` — grant 3 → 3; `entries` has one `grant` row with delta 3.
  - `test_reference_counted_once` — `add_entry(w, 5, "purchase", "tx1")` True, again False; balance 5.
  - `test_debit_and_refund_same_reference` — grant 3; debit 1 ref `c1` → True, balance 2; refund 1 ref `c1` → True, balance 3; refund again → False, balance 3; entries reasons `["grant","debit","refund"]`.
  - `test_refund_without_debit_refused` — refund ref `c9` → False.
  - `test_debit_never_below_zero` — balance 1, debit 2 → False, balance 1.
  - `test_concurrent_debits_one_wallet` — balance 1; two threads, each with its own `connect()`, each `BEGIN IMMEDIATE; try_debit(1, ref_i); COMMIT` started behind a `threading.Barrier(2)` → exactly one True, final balance 0.
  - `test_ledger_rows_never_updated` — a trigger refuses `UPDATE` and `DELETE` on `ledger` (assert `sqlite3.IntegrityError` or `DatabaseError`).
  - `test_grant_must_be_positive` — `grant(…, 0, …)` raises `ValueError`.
  - `test_rekey_keeps_wallet` — rekey changes `token_hash`, `wallet_id` unchanged.
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Implement `db.py` and `ledger.py` (append-only via `BEFORE UPDATE`/`BEFORE DELETE` triggers that `RAISE(ABORT, 'ledger is append-only')`).
- [ ] **Step 4:** Run → pass.
- [ ] **Step 5:** Commit `feat(server): devices, wallets and the append-only credit ledger (spec 6.2)`.

### Task 3: Admission, settlement and cost

**Files:**
- Create: `server/myguide/pricing.py`, `server/myguide/limits.py`
- Test: `server/tests/test_pricing.py`, `server/tests/test_limits.py`

**Interfaces:**
- Consumes: `Settings`, `KINDS` (Task 1); `connect`, `ledger.try_debit`, `ledger.refund`, `ledger.balance` (Task 2).
- Produces:
  - `@dataclass(frozen=True) class Usage: input_tokens: int = 0; cached_tokens: int = 0; output_tokens: int = 0; speech_chars: int = 0`
  - `pricing.cost_micro(settings, kind: str, model: str, usage: Usage) -> int` — story/image: `(input - cached)·in + cached·cached_in + output·out`; speech: `speech_chars · char_price`; Decimal, `ROUND_HALF_UP` to int.
  - `pricing.usage_from_json(obj: dict) -> Usage` — reads `usage.input_tokens`, `usage.output_tokens`, `usage.input_tokens_details.cached_tokens`; any missing or non-int part is 0; no `usage` → `Usage()`.
  - `class RateWindow` — `__init__(limit_getter: Callable[[], int], window_seconds: float)`, `hit(key, now: float) -> bool` (records the hit, returns False when this hit exceeds the limit within the window; refused hits are recorded too).
  - `@dataclass class Admission: allowed: bool; status: int; code: str | None; call_id: str; device_id: int; wallet_id: int; kind: str; day: str; paid_with: str | None  # "free" | "credits" | "none" (zero-credit kind) | None; credits_debited: int; free_left: dict[str, int]; credits: int`
  - `limits.count_refused(conn, settings, device_id: int, now: datetime) -> tuple[dict[str,int], int]` — counts a request refused before admission (404, 400, 413, rate): `requests += 1`, `refused += 1`; returns `(free_left, credits)` for the headers.
  - `limits.admit(conn, settings, device: sqlite3.Row, kind: str, now: datetime) -> Admission` — one `BEGIN IMMEDIATE` transaction, in this order: `requests += 1`; then refuse (with `refused += 1`) on the first that holds: requests today > `requests_per_device_per_day` → 429 `daily_quota`; server cost today ≥ `daily_spend_cap_micro` → 503 `server_budget`; device cost today ≥ `device_spend_cap_micro` → 429 `daily_quota`; kind in (story,image) and `tokens_in + tokens_out` today ≥ `tokens_per_device_per_day` → 429; kind speech and `speech_chars` today ≥ `speech_chars_per_device_per_day` → 429; then `used_<kind> < quota(kind)` → reserve (`used_<kind> += 1`, `paid_with="free"`); else `credits(kind) == 0` → `paid_with="none"`; else `try_debit(credits(kind), reference=call_id)` → `paid_with="credits"`; else 429 `daily_quota`. `call_id` = `uuid4().hex`. Per-minute rate is not here (in memory, Task 6).
  - `limits.settle(conn, settings, admission: Admission, *, kept: bool, status: int, model: str, usage: Usage, latency_ms: int, now: datetime) -> None` — one transaction: if not kept: `paid_with=="free"` → `used_<kind> -= 1` on `admission.day` (not today's day); `"credits"` → `ledger.refund`. Always: add usage tokens/chars and cost to `device_days(admission.day)` and `server_days(admission.day)`; insert one `calls` row (`kept` 0/1). Idempotent per `call_id` (second call is a no-op, guarded by `calls.call_id UNIQUE`).
  - `limits.allowance(conn, settings, device_id: int, wallet_id: int, day: str) -> tuple[dict[str, int], int]` — free left per kind (never below 0) and balance.

- [ ] **Step 1: Write failing `test_pricing.py`**, hand-computed in comments:
  - gpt-5-mini 1000 in / 200 cached / 500 out at 0.25/0.025/2.00: `800·0.25 + 200·0.025 + 500·2.00 = 200 + 5 + 1000 = 1205` µUSD.
  - gpt-5-mini 10000 in / 0 / 0: `10000·0.25 = 2500` µUSD.
  - speech 900 chars at 15.00: `900·15 = 13500` µUSD; 1 char at 0.0004 → `0.0004` rounds to 0; 3 chars at 0.5 → `1.5` rounds half-up to 2.
  - image gpt-image-2.5-flare 100 in / 0 / 4000 out at 5/1.25/40: `500 + 160000 = 160500`.
  - `usage_from_json({"usage":{"input_tokens":10,"output_tokens":"x"}})` → `Usage(10, 0, 0)`; `{}` → `Usage()`.
- [ ] **Step 2: Write failing `test_limits.py`** (settings from `parse_settings` of a small dict helper with low limits; `now` fixed at `2026-10-30T12:00Z`):
  - `test_free_quota_then_429` — `QUOTA_STORY_PER_DAY=2`, `CREDITS_PER_STORY=1`, balance 0: admit, admit allowed (`free`), third → 429 `daily_quota`; `free_left["story"]` 1, 0, 0.
  - `test_kept_unit_stays_returned_unit_comes_back` — admit, settle `kept=True` → used 1; admit, settle `kept=False` → used 1.
  - `test_free_first_then_credits` (acceptance 5a) — quota 1, grant 3: first admit `free`; next three `credits` with balance after each 2, 1, 0; fifth → 429. Then one more grant 1, admit `credits`, settle `kept=False` → balance 1 and ledger has one `debit` and one `refund` with that `call_id`.
  - `test_cost_per_kind_from_settings` — `CREDITS_PER_IMAGE=2`, quota image 0, balance 3: admit image → balance 1, `credits_debited == 2`; second image → 429 (1 < 2).
  - `test_zero_credit_kind_passes` — speech quota 0, `CREDITS_PER_SPEECH=0`, balance 0 → allowed, `paid_with=="none"`, balance 0.
  - `test_requests_per_day_counts_refused` — `REQUESTS_PER_DEVICE_PER_DAY=3`: `count_refused` twice, `admit` → allowed (3rd request), `admit` → 429; `device_days.refused == 3` (2 + the last).
  - `test_tokens_limit_after_usage` — `TOKENS_PER_DEVICE_PER_DAY=1000`: admit, settle with `Usage(input 600, output 300)` (900 < 1000) → next admit allowed; settle with `Usage(input 200)` (1100) → next admit 429. Speech: `SPEECH_CHARS_PER_DEVICE_PER_DAY=100`, settle 99 chars → allowed, settle 1 more (100) → 429 (≥).
  - `test_server_spend_cap` — `DAILY_SPEND_CAP_USD=0.001205`: settle one call with the 1205 µUSD usage above → next admit on any device → 503 `server_budget`; the next UTC day → allowed.
  - `test_device_spend_cap` — `DEVICE_SPEND_CAP_USD=0.0025`, settle 2500 µUSD on device A → A gets 429, device B allowed.
  - `test_day_boundary` — quota 1 used at `2026-10-30T23:59:59Z` → admit at `2026-10-31T00:00:00Z` allowed.
  - `test_settle_returns_to_reserved_day` (Review Focus 4) — admit at `23:59:59Z` day 30, settle `kept=False` at `00:00:01Z` day 31 → `used_story` of day 30 is 0, day 31 has no `used_story` increment.
  - `test_settle_is_idempotent` — settle twice `kept=False` → one `calls` row, unit returned once (used not negative), one refund.
  - `test_concurrent_paid_admits_one_wallet` (Review Focus 2) — two devices sharing one wallet (update `wallet_id` directly), quota 0, balance 1, two threads with own connections behind a Barrier → exactly one allowed.
  - `test_rate_window` — limit 2, window 60 s, a hit counts while `hit_time > now - 60`, refused hits are recorded: t=0 True (1 in window), t=1 True (2), t=2 False (3), t=61 True (window (1, 61] holds t=2, t=61 → 2), t=62 True ((2, 62] holds t=61, t=62 → 2), t=63 False ((3, 63] holds t=61, t=62, t=63 → 3). Hand-check written in the test comment.
- [ ] **Step 3:** Run → fail.
- [ ] **Step 4:** Implement `pricing.py` and `limits.py`.
- [ ] **Step 5:** Run → pass.
- [ ] **Step 6:** Commit `feat(server): admission and settlement — free quota, credits, abuse guards, spend caps (spec 6, 6.2)`.

### Task 4: App Attest verification

**Files:**
- Create: `server/myguide/attest.py`, `server/myguide/apple_app_attest_root.pem` (Apple App Attestation Root CA, downloaded from `https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem`; check its SHA-256 fingerprint against the one Apple publishes on `https://www.apple.com/certificateauthority/` and write it in a comment at the top of `attest.py`)
- Test: `server/tests/test_attest.py`, `server/tests/attest_fixtures.py` (builds a test chain)

**Interfaces:**
- Produces:
  - `class AttestError(Exception)` with a short reason (`"chain"`, `"nonce"`, `"rp_id"`, `"counter"`, `"aaguid"`, `"key_id"`, `"format"`).
  - `verify_attestation(*, attestation: bytes, key_id_b64: str, challenge: bytes, app_id: str, allow_development: bool, root: x509.Certificate, now: datetime) -> None` — raises `AttestError` or returns. Steps per Apple's "Validating apps that connect to your server": CBOR `{fmt: "apple-appattest", attStmt: {x5c: [leaf, intermediate], receipt}, authData}`; leaf signed by intermediate, intermediate by `root` (ECDSA with each cert's `signature_hash_algorithm`), all valid at `now`; `clientDataHash = SHA256(challenge)`; `nonce = SHA256(authData ‖ clientDataHash)` equals the leaf extension OID `1.2.840.113635.100.8.2`, whose DER value is exactly `30 24 a1 22 04 20` + 32 bytes; `SHA256(leaf public key, X9.62 uncompressed point) == base64decode(key_id_b64)`; `authData[0:32] == SHA256(app_id)`; counter `authData[33:37] == 0`; aaguid `authData[37:53]` is `b"appattest" + b"\x00"*7` (production) or `b"appattestdevelop"` (only if `allow_development`); credential id (`authData[53:55]` big-endian length, then the id) equals the decoded key id.
  - `apple_root() -> x509.Certificate` (loads the PEM next to the module).
  - `class Challenges` — `issue(now: float) -> str` (32 random bytes, standard base64), `consume(challenge_b64: str, now: float) -> bytes | None` (one use, `ttl` from a getter `Callable[[], int]` passed to `__init__`; expired → None).
  - `attest_fixtures.make_attestation(*, app_id, challenge, aaguid=b"appattestdevelop", counter=0, nonce_override=None, root_key=None) -> tuple[bytes, str, x509.Certificate]` returning `(attestation, key_id_b64, root_cert)`.

- [ ] **Step 1: Write failing tests:** valid development attestation passes with `allow_development=True`; same with `False` → `AttestError("aaguid")`; production aaguid passes with `False`; wrong `app_id` → `"rp_id"`; `nonce_override` → `"nonce"`; `counter=1` → `"counter"`; chain built on another root → `"chain"`; key id of another key → `"key_id"`; `fmt` not `apple-appattest` or garbage CBOR → `"format"`; leaf expired at `now` → `"chain"`; `apple_root()` loads and its subject CN contains `Apple App Attestation Root CA`. `Challenges`: issued challenge consumed once (second → None); expired after ttl (+1 s) → None; unknown → None.
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Implement `attest.py` and the fixtures.
- [ ] **Step 4:** Run → pass.
- [ ] **Step 5:** Commit `feat(server): App Attest attestation check against Apple's root (spec 5)`.

### Task 5: The service — health, attest and token auth

**Files:**
- Create: `server/myguide/app.py`, `server/myguide/state.py`
- Test: `server/tests/test_attest_api.py`, `server/tests/conftest.py`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces:
  - `class State` (`state.py`): `settings: Settings` (replaceable), `db_path`, `challenges: Challenges`, `attest_window: RateWindow` (per IP, 3600 s, `attests_per_ip_per_hour`), `rate_window: RateWindow` (per device, 60 s, `rate_per_minute`), `root: x509.Certificate`, `upstream: httpx.AsyncClient`, `clock: Callable[[], datetime]` (UTC), `reload(path) -> None` (replaces `settings` only if `load_settings` succeeds; logs `ConfigError` text otherwise).
  - `create_app(state: State) -> Starlette` with routes `GET /health` → `{"ok": true}`; `POST /v1/attest/challenge` → `{"challenge": "<b64>"}`; `POST /v1/attest` body `{keyId, attestation, challenge, previousToken?}` → `{"token": "<base64url, 32 bytes, no padding>"}`; the proxy routes come in Task 6.
  - `authenticate(request, conn) -> sqlite3.Row` raising `HTTPError(401, "attest_required")` for a missing/unknown bearer, `HTTPError(403, "blocked")` for a blocked device; token lookup by `sha256(token).hexdigest()`.
  - `client_ip(request) -> str` — the last `X-Forwarded-For` entry when the peer is `127.0.0.1`/`::1`, else the peer address. Never stored.
  - `json_error(status, code, message, headers=None) -> JSONResponse` in the Global Constraints shape.
  - `server/myguide/__main__.py`: `python -m myguide --env /etc/myguide/env --db /srv/myguide/guide.db` loads settings (exit 1 printing the `ConfigError` on stderr), installs a SIGHUP handler calling `state.reload`, runs uvicorn on `127.0.0.1:<LISTEN_PORT>` with `access_log=False`.

- [ ] **Step 1: Write failing tests** (TestClient; attestation from `attest_fixtures` with the fixture root injected into `State.root`):
  - health → 200 `{"ok": true}`.
  - challenge → 200, base64 decodes to 32 bytes.
  - attest valid → 200 token; DB has one device whose `token_hash == sha256(token)` and no row/column contains the token itself (scan all text values of all tables).
  - attest with a reused challenge → 400 `bad_request`; with an unknown challenge → 400; with a bad attestation → 401 `attest_required`; development aaguid with `ALLOW_DEVELOPMENT_ATTEST=0` → 401.
  - attest with `previousToken` of an existing device → same device id, new token works, old token → 401; with a blocked device's previous token → 403 `blocked`.
  - the 21st attest from one `X-Forwarded-For` IP within an hour (peer 127.0.0.1, `ATTESTS_PER_IP_PER_HOUR=20`) → 429 `rate_limited`; another IP → allowed.
  - `test_reload_changes_limit_without_restart` — write env file with `QUOTA_STORY_PER_DAY=80`, build state, rewrite with `5`, `state.reload(path)` → `state.settings.quota_story_per_day == 5`; rewrite with `abc`, reload → still 5.
  - `test_main_refuses_bad_env` — `subprocess.run([sys.executable, "-m", "myguide", "--env", bad, "--db", tmp])` exits 1 and stderr starts with the setting name.
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run → pass.
- [ ] **Step 5:** Commit `feat(server): health, challenge, attest and bearer tokens (spec 5)`.

### Task 6: The proxy — allowlists, store:false, streaming, headers

**Files:**
- Create: `server/myguide/proxy.py` (routes registered by `create_app`), `server/myguide/sse.py`
- Test: `server/tests/test_proxy.py`, `server/tests/test_sse.py`

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces:
  - `ROUTES = {"responses": "story", "audio/speech": "speech", "images/generations": "image"}`; `POST /v1/{path:path}`: unknown path → 404 `not_found` (after auth; counted with `count_refused`). Non-POST on a known path → 405.
  - `class CompletedWatcher` (`sse.py`): `feed(chunk: bytes) -> None` splits lines across chunk boundaries (LF, CRLF), tracks `event:`/`data:` per SSE event; `completed: bool`; `usage: Usage` from the `response.completed` event's `response.usage`.
  - Request order for a known path: authenticate → `rate_window.hit(device_id)` false → `count_refused` + 429 `rate_limited`; `Content-Length` or read body > `max_body_bytes` → 413; body not a JSON object or `model` not a string → 400 `bad_request`; model not in `models(kind)` → 400 `model_not_allowed` (both counted refused); for story set `body["store"] = False`; `admit` → refusal answered with its status/code; forward `POST https://api.openai.com/v1/<path>` with only `Authorization: Bearer <OPENAI_API_KEY>`, `Content-Type: application/json` (and `Accept: text/event-stream` when streaming); timeout `upstream_timeout_seconds`.
  - Non-streaming: read the whole upstream body, return status + body + upstream `Content-Type`; `kept = 2xx`; usage from `usage_from_json` (story/image), speech chars = `len(body["input"])` if it is a string; settle; latency from admit to upstream end.
  - Streaming (`kind == "story"` and `body.get("stream") is True`): open `upstream.stream`; on non-2xx read the body and answer like non-streaming (`kept=False`); on 2xx return `StreamingResponse` yielding each upstream chunk unchanged (`aiter_raw`) while feeding `CompletedWatcher`; settle in `finally` with `kept = watcher.completed`, so a client disconnect or upstream break settles once.
  - Upstream `httpx.TimeoutException`/`httpx.TransportError` before the head → 502 `upstream_unreachable`, settle `kept=False`, status 502.
  - Every answer after auth carries the two `X-MyGuide-*` headers from `allowance` (computed after admit/settle as fits; on a streamed answer, after admit).

- [ ] **Step 1: Write failing `test_sse.py`:** completed event split across three chunks with CRLF → `completed`, usage `Usage(1000, 200, 500)`; deltas only → not completed; `data: [DONE]` alone → not completed; garbage JSON in the completed data → not completed.
- [ ] **Step 2: Write failing `test_proxy.py`** with `httpx.MockTransport` as the upstream (records requests):
  - no token / made-up token → 401 `attest_required` and the upstream saw nothing (acceptance 2).
  - `/v1/models` → 404; `/v1/responses` with `"model":"gpt-4o"` → 400 `model_not_allowed`; both count in `device_days.refused`.
  - body over `MAX_BODY_BYTES=1000` → 413.
  - story with `"store": true` → upstream body has `"store": false`, all other keys equal to what was sent; upstream `Authorization` is the server key, and the request carried no `X-Forwarded-For` or client `Authorization`.
  - story 200 with usage → `calls` row `kept=1`, `cost_micro=1205` (with the Task 3 usage), headers `X-MyGuide-Free-Left: story=79,speech=80,image=4` and `X-MyGuide-Credits: 0`.
  - upstream 500 → client gets 500 with the upstream body, unit returned (`free_left` story back to 80), row `kept=0`.
  - upstream 400 → passed through, unit returned (acceptance 4).
  - upstream raises `httpx.ConnectTimeout` → 502 `upstream_unreachable`, unit returned (Review Focus 3).
  - streaming with the final event: the client receives bytes identical to the upstream bytes; `kept=1`, usage counted.
  - streaming without the final event → client receives the bytes; unit returned, `kept=0`.
  - `test_stream_client_disconnect_settles_once` (Review Focus 1) — client reads the first chunk and closes; then exactly one `calls` row with `kept=0` and the unit returned once.
  - speech 200 with `"input": "Hei på deg"` → `speech_chars == 10`, cost from the speech price.
  - 81st story call with default quota → 429 `daily_quota` (acceptance 3); spend cap reached → 503 `server_budget` (acceptance 5).
  - 16th request within a minute → 429 `rate_limited`.
  - `test_nothing_personal_stored` (acceptance 7) — after a story with a prompt word `Colosseum`, coordinate `41.8902`, and a base64 image string, no text value in any table of the DB and no captured log record (`caplog`, all levels) contains any of them.
- [ ] **Step 3:** Run → fail.
- [ ] **Step 4:** Implement `sse.py` and `proxy.py`.
- [ ] **Step 5:** Run → pass; run the whole server suite.
- [ ] **Step 6:** Commit `feat(server): the OpenAI pass-through — allowlists, store:false, SSE, quota headers (spec 6)`.

### Task 7: Admin command and log retention

**Files:**
- Create: `server/myguide/admin.py`, `server/myguide/retention.py`
- Modify: `server/myguide/proxy.py` or `app.py` (prune once per UTC day on the first request of the day, and at start)
- Test: `server/tests/test_admin.py`

**Interfaces:**
- Consumes: Tasks 1–3, 5.
- Produces:
  - `retention.prune(conn, settings, now) -> int` — deletes `calls` and `device_days` rows with `day` older than `log_retention_days` days before `now`'s day; never touches `ledger`, `devices`, `wallets`.
  - `admin.main(argv: list[str], *, env_path: Path, db_path: Path, out: TextIO, now: datetime, signal_service: Callable[[], None]) -> int`. Commands: `today`, `days N`, `devices [N]` (columns: device, requests, refused, tokens in/out/cached, speech chars, cost USD, balance; highest cost first), `device ID` (per day and per kind), `block ID`, `unblock ID`, `limits` (from `Settings.redacted()`), `reload` (calls `signal_service`, which in production runs `systemctl kill -s HUP myguide`), `grant ID CREDITS NOTE...`, `balance ID`, `ledger ID`. Unknown command or bad args → usage on `out`, exit 2. Unknown device → exit 1 with a message.
  - Entry point `server/bin/myguide-admin` (shell, `exec /opt/myguide/venv/bin/python -m myguide.admin --env /etc/myguide/env --db /srv/myguide/guide.db "$@"`).

- [ ] **Step 1: Write failing tests:** prune with retention 90 at `2026-10-30` deletes a `2026-07-31` row (91 days) and keeps `2026-08-01` (90 days) — hand computation in a comment; ledger untouched. Admin: `grant 1 3 heidi test` → balance 3 and `ledger 1` shows one grant line; `grant 1 0 x` → exit 2; `block 1` then a proxy call by that device → 403 (via the Task 5 app); `devices` orders by cost and shows the balance column; `limits` output contains `QUOTA_STORY_PER_DAY` and `<set>` and not the key; `reload` calls `signal_service` once; `today` prints the day's cost in USD (`1205` µUSD prints `0.0012`); unknown command → 2.
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run → pass.
- [ ] **Step 5:** Commit `feat(server): myguide-admin and 90-day log retention (spec 6.2, 7)`.

### Task 8: Deploy files (written, not run)

**Files:**
- Create: `server/deploy/Caddyfile`, `server/deploy/myguide.service`, `server/deploy/limits.conf`, `server/deploy/install.sh`, `server/deploy.sh`, `server/README.md`
- Test: `server/tests/test_deploy_files.py`

**Interfaces:**
- Consumes: `env.template` (Task 1), `bin/myguide-admin` (Task 7), `python -m myguide` (Task 5).
- Produces (contents pinned):
  - `Caddyfile`: `myguide.itsalie.xyz { reverse_proxy 127.0.0.1:8710 { flush_interval -1 } }`, no `log` directive. Installed as `/etc/caddy/Caddyfile` only if Caddy has no config yet; otherwise `install.sh` stops and prints what to add (never overwrites another site).
  - `myguide.service`: `User=myguide`, `Group=myguide`, `WorkingDirectory=/opt/myguide`, `ExecStart=/opt/myguide/venv/bin/python -m myguide --env /etc/myguide/env --db /srv/myguide/guide.db`, `ExecReload=/bin/kill -HUP $MAINPID`, `Restart=on-failure`, `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ReadWritePaths=/srv/myguide`, `ProtectHome=yes`, `PrivateTmp=yes`.
  - `limits.conf` (drop-in `/etc/systemd/system/myguide.service.d/limits.conf`): `[Service]` `MemoryMax=200M` `CPUWeight=50`.
  - `install.sh` (run as root on the server, idempotent, `set -euo pipefail`): installs `caddy` and `python3.14-venv` via apt if missing; creates system user `myguide`; dirs `/opt/myguide` (root-owned), `/srv/myguide` (`myguide:myguide`, 0750), `/etc/myguide`; writes `/etc/myguide/env` from `env.template` only if missing (`root:myguide`, 0640) and prints that `OPENAI_API_KEY` must be filled in; creates the venv and installs `requirements.txt`; installs unit, drop-in, `/usr/local/bin/myguide-admin`; `ufw allow 22/tcp`, `80/tcp`, `443/tcp` before `ufw --force enable`; `systemctl daemon-reload`, enables (not starts) `myguide` when the key is empty, else restarts it. It never references `kunngjoring`.
  - `deploy.sh` (run locally): refuses to run unless `MYGUIDE_DEPLOY_GO=1` is set, `rsync -a --delete --exclude .venv --exclude tests --exclude __pycache__ server/ root@204.168.153.170:/opt/myguide/src/`, then `ssh … 'bash /opt/myguide/src/deploy/install.sh'`.
  - `README.md`: what runs where, first install steps, `myguide-admin` usage, how to check Suverra's timers afterwards (`systemctl list-timers 'kunngjoring-*'`).

- [ ] **Step 1: Write failing `test_deploy_files.py`:** Caddyfile contains `flush_interval -1` and no `log`; unit has `ProtectSystem=strict`, `User=myguide`, no `MemoryMax` (it lives in the drop-in); drop-in has `MemoryMax=200M` and `CPUWeight=50`; no deploy file contains `kunngjoring`; `install.sh` and `deploy.sh` start with `set -euo pipefail`; `deploy.sh` checks `MYGUIDE_DEPLOY_GO`; `env.template` contains no `sk-`; `bash -n` passes on both scripts (subprocess); `shellcheck` passes if it is installed (skip otherwise).
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Write the files.
- [ ] **Step 4:** Run → pass. Do not run `deploy.sh` or `install.sh`.
- [ ] **Step 5:** Commit `feat(server): Caddy, systemd, install and deploy scripts (not run) (spec 4)`.

### Task 9: App core — new error cases and their texts

**Files:**
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/OpenAI/OpenAIError.swift`, `OpenAIClient.swift` (`mapError`), `Packages/MyGuideCore/Sources/MyGuideCore/Story/UserFacingMessage.swift`, `MyGuide/Story/StoryViewModel.swift:544-546`, any exhaustive switch or retry classification over `OpenAIError` (find with `grep -rn "OpenAIError\|\.rateLimited\|\.server(" MyGuide Packages/MyGuideCore/Sources MyGuideWatch`)
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/OpenAIClientTests.swift` (or the file holding `mapError` tests), `UserFacingMessageTests.swift`

**Interfaces:**
- Produces: `OpenAIError.dailyQuota`, `.serverBudget`, `.attestUnavailable`. `mapError(status:body:)`: code `daily_quota` (any status) → `.dailyQuota`; `server_budget` → `.serverBudget`; `attest_required` → `.attestUnavailable`; checked before the status switch, after `permanentError`.

- [ ] **Step 1: Write failing tests:** `mapError(429, {"error":{"code":"daily_quota"}})` → `.dailyQuota`; `(503, server_budget)` → `.serverBudget`; `(401, attest_required)` → `.attestUnavailable`; `(401, no code)` → `.invalidAPIKey` (unchanged); `(503, no body)` → `.server(503)` (unchanged); `(429, rate_limited)` → `.rateLimited`. Messages: the three Global Constraints texts in both languages, exactly.
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Implement. In `StoryViewModel`'s speech failure, show the message for `.dailyQuota`, `.serverBudget`, `.attestUnavailable` too. Where code retries on `.rateLimited`/`.server`, the three new cases are never retried.
- [ ] **Step 4:** `swift test` → pass.
- [ ] **Step 5:** Commit `feat(core): daily quota, server budget and attest errors with screen texts (spec 8)`.

### Task 10: App core — GuideServerSession and GuideServerHTTPClient

**Files:**
- Create: `Packages/MyGuideCore/Sources/MyGuideCore/GuideServer/GuideServer.swift`, `GuideServerSession.swift`, `GuideServerHTTPClient.swift`, `ServerAllowance.swift`
- Test: `Packages/MyGuideCore/Tests/MyGuideCoreTests/GuideServerSessionTests.swift`, `GuideServerHTTPClientTests.swift`, `ServerAllowanceTests.swift`

**Interfaces:**
- Consumes: `HTTPClient`, `OpenAIError` (Task 9).
- Produces:
  - `public enum GuideServer { public static let baseURL = URL(string: "https://myguide.itsalie.xyz/v1")!; public static let placeholderKey = "guide-server" }`
  - `public protocol AppAttestProvider: Sendable { var isSupported: Bool { get }; func generateKey() async throws -> String; func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data }`
  - `public protocol GuideTokenStore: Sendable { func read() throws -> String?; func write(_ token: String?) throws }`
  - `public actor GuideServerSession { public init(baseURL: URL, http: HTTPClient, attest: AppAttestProvider, store: GuideTokenStore); public func token() async throws -> String; public func renewToken(rejected: String) async throws -> String }` — `token()` returns the stored token or attests. `renewToken` returns the current token if it differs from `rejected` (another call already renewed), otherwise attests with `previousToken: rejected`. At most one attestation in flight (`Task<String, Error>?` shared by callers). Attest flow: `POST {base}/attest/challenge` → `challenge` (base64); `generateKey()`; `attestKey(keyId, clientDataHash: SHA256(base64-decoded challenge bytes))`; `POST {base}/attest` JSON `{"keyId", "attestation" (base64), "challenge" (as received), "previousToken"?}` → `token`; store it. Errors: `!isSupported`, a thrown attest error, or a non-2xx from either endpoint → `OpenAIError.attestUnavailable`; `URLError` → `OpenAIError.network`; cancellation stays `CancellationError`.
  - `public struct GuideServerHTTPClient: HTTPClient { public init(session: GuideServerSession, base: HTTPClient, onAllowance: @escaping @Sendable (ServerAllowance) -> Void) }` — `send` and `lines`: set `Authorization: Bearer <token>`; on a 401 response renew once (`renewToken(rejected:)`) and resend once; a second 401 is returned as is (so `OpenAIClient.mapError` makes `.attestUnavailable`). After each response, `ServerAllowance(headers:)` non-nil → `onAllowance`.
  - `public struct ServerAllowance: Sendable, Equatable, Codable { public var freeLeft: [String: Int]; public var credits: Int?; public init?(headers: [AnyHashable: Any]) }` — parses `X-MyGuide-Free-Left` (`story=12,speech=40,image=4`; malformed pairs skipped) and `X-MyGuide-Credits` (int); nil when both are absent or empty. Header lookup is case-insensitive.

- [ ] **Step 1: Write failing tests** with a recording fake `HTTPClient` (actor-backed), a fake `AppAttestProvider` counting calls, and an in-memory `GuideTokenStore`:
  - first `token()` with an empty store → challenge + attest requests in that order; attest body has `keyId`, base64 `attestation`, the challenge as received, no `previousToken`; `clientDataHash` equals SHA-256 of the decoded challenge bytes (compute the expected hash in the test with CryptoKit from the same bytes); token stored.
  - stored token → no network.
  - `isSupported == false` → `.attestUnavailable`; attest endpoint 401 → `.attestUnavailable`; challenge `URLError(.notConnectedToInternet)` → `.network`.
  - `renewToken(rejected: old)` → attest body has `previousToken: old`; `renewToken(rejected: "stale")` when current is different → returns current, no attestation.
  - `test_concurrent_401_one_attestation` (Review Focus 5) — two `send`s through `GuideServerHTTPClient`, both first get 401, then 200 → fake attest provider's `attestKey` called once, both retried with the new token, both return 200.
  - `send` 401 twice → second 401 returned, exactly one renewal.
  - `lines` 401 then 200 → retried once.
  - `Authorization` header on the outgoing request is `Bearer <token>` even when the incoming request had `Bearer guide-server`.
  - `onAllowance` called with `freeLeft == ["story": 12, "speech": 40, "image": 4]`, `credits == 37` from headers; not called when headers absent.
  - `ServerAllowance(headers:)`: lowercase header names parse; `"story=12,bad,image=x"` → `["story": 12]`; only credits header → `freeLeft == [:]`, `credits == 5`.
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test` → pass.
- [ ] **Step 5:** Commit `feat(core): guide server session — App Attest token, one re-attest on 401 (spec 5, 8)`.

### Task 11: App core — walk log `server` line

**Files:**
- Modify: `Packages/MyGuideCore/Sources/MyGuideCore/WalkLog/WalkLogEvent.swift`, `WalkLogCodec.swift`, `WalkLogText.swift` (and `WalkLogSummary.swift` only if its switch is exhaustive)
- Test: the existing walk log codec/text test files

**Interfaces:**
- Consumes: `ServerAllowance` (Task 10).
- Produces: `WalkLogEvent.Kind.server(ServerAllowance)`; JSON tag `"server"` with fields `freeLeft` (object) and `credits` (int, omitted when nil), following the codec's existing pattern; text line `server · free story 12 speech 40 image 4 · credits 37` (kinds in the order story, speech, image; missing ones left out; `credits –` when nil).

- [ ] **Step 1: Write failing tests:** round trip with and without credits; the text line for both; an existing line from the current format (copy one from the current tests) still decodes unchanged.
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test` → pass.
- [ ] **Step 5:** Commit `feat(walklog): the guide server's free quota and credits after each call (spec 8)`.

### Task 12: App wiring — server by default, bundled key removed

**Files:**
- Create: `MyGuide/GuideServer/DeviceAppAttest.swift` (`AppAttestProvider` over `DCAppAttestService.shared`), `MyGuide/GuideServer/KeychainGuideTokenStore.swift` (`GuideTokenStore` over `KeychainStore`, account `guideServerToken`)
- Modify: `MyGuide/AppServices.swift:354-387`, `MyGuide/Settings/SettingsView.swift` (bundled line → server line), `MyGuide/Walking/WalkLog.swift` (`logServer(_:)` with Ruling 8), `MyGuide/Info.plist` and `project.yml` (remove `MGBundledOpenAIKey`; add entitlement `com.apple.developer.devicecheck.appattest-environment: development` under `entitlements.properties`), `MyGuide/MyGuide.entitlements` (regenerated), `Config/Signing.xcconfig` (remove `OPENAI_BUNDLED_KEY`), `Packages/MyGuideCore/Sources/MyGuideCore/Secrets/APIKeySource.swift`, `Packages/MyGuideCore/Tests/MyGuideCoreTests/APIKeySourceTests.swift`
- Test: `APIKeySourceTests.swift`

**Interfaces:**
- Consumes: Tasks 9–11.
- Produces:
  - `APIKeySource` becomes `public enum APIKeySource { public static func usable(_ value: String?) -> String? }` (trimmed; blank → nil). The `.stored`/`.bundled` cases and `resolve` are deleted, with every caller.
  - `AppServices`: one shared `GuideServerSession` (`baseURL: GuideServer.baseURL`, `http`, `DeviceAppAttest()`, `KeychainGuideTokenStore(keychain)`) and one `GuideServerHTTPClient` whose `onAllowance` hops to the main actor and calls `walkLog.logServer(_:)`. `makeOpenAI()`: own key from the Keychain → `OpenAIClient(apiKey: key, http: http)` (straight to OpenAI); else `DeviceAppAttest().isSupported` → `OpenAIClient(apiKey: GuideServer.placeholderKey, http: guideHTTP, baseURL: GuideServer.baseURL)`; else throw `.missingAPIKey`. `hasAPIKey(keychain:)` → true when an own key exists or App Attest is supported (keep the name; update its doc comment).
  - Settings: with no own key and App Attest supported, the line «Historiene går via MyGuide-serveren.» / «Stories go through the MyGuide server.» where the bundled-key line was.

- [ ] **Step 1: Write failing tests** for `APIKeySource.usable`: `" sk-own \n"` → `"sk-own"`; `"  \n"` → nil; nil → nil.
- [ ] **Step 2:** Run → fail; implement; run → pass.
- [ ] **Step 3:** Implement the wiring, the two app types, the entitlement, Settings, WalkLog, and remove the bundled key everywhere: `grep -rn "Bundled\|OPENAI_BUNDLED\|MGBundled" MyGuide project.yml Config/Signing.xcconfig Packages scripts` must find only `Theme.Font.verifyBundled`.
- [ ] **Step 4:** `xcodegen generate` and the device build in Global Constraints → `BUILD SUCCEEDED`; `swift test` → all pass. Commit `MyGuide.xcodeproj/project.pbxproj` only if the build needs the change (new files).
- [ ] **Step 5:** Commit `feat(app): stories through the guide server by default; bundled key removed (spec 8)`.

---

## After the plan

Final whole-branch review. Then report to the owner: the server is built and tested but **not deployed**; until it is deployed, a build of this branch on the phone tells stories only with an own key in Settings, so it is not installed or uploaded to TestFlight before deploy; prices in `env.template` need the owner's check (Ruling 7); `OPENAI_BUNDLED_KEY` in the owner's git-ignored `Config/Local.xcconfig` is now unused and can be deleted by the owner.
