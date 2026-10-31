"""Settings from the env file (spec 6.1). Every limit is a setting; none is a constant in code."""
from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation
from pathlib import Path

KINDS = ("story", "speech", "image")

_MICRO = Decimal(1_000_000)


class ConfigError(Exception):
    """A missing or invalid setting. The message starts with the setting name."""


@dataclass(frozen=True)
class Price:
    input_per_m: Decimal
    cached_input_per_m: Decimal
    output_per_m: Decimal


@dataclass(frozen=True)
class Settings:
    quota_story_per_day: int
    quota_speech_per_day: int
    quota_image_per_day: int
    rate_per_minute: int
    requests_per_device_per_day: int
    tokens_per_device_per_day: int
    speech_chars_per_device_per_day: int
    daily_spend_cap_micro: int
    device_spend_cap_micro: int
    max_body_bytes: int
    upstream_timeout_seconds: int
    challenge_ttl_seconds: int
    attests_per_ip_per_hour: int
    log_retention_days: int
    credits_per_story: int
    credits_per_speech: int
    credits_per_image: int
    listen_port: int
    challenges_max_outstanding: int
    challenges_per_ip_per_hour: int
    attest_max_body_bytes: int
    max_output_tokens_story: int
    max_inflight_per_device: int
    allow_development_attest: bool
    models_story: frozenset[str]
    models_speech: frozenset[str]
    models_image: frozenset[str]
    token_prices: dict[str, Price]
    speech_char_prices: dict[str, Decimal]
    apple_team_id: str
    apple_bundle_id: str
    openai_api_key: str

    def _check(self, kind: str) -> None:
        if kind not in KINDS:
            raise ValueError(f"unknown kind {kind!r}")

    def quota(self, kind: str) -> int:
        self._check(kind)
        return getattr(self, f"quota_{kind}_per_day")

    def credits(self, kind: str) -> int:
        self._check(kind)
        return getattr(self, f"credits_per_{kind}")

    def models(self, kind: str) -> frozenset[str]:
        self._check(kind)
        return getattr(self, f"models_{kind}")

    @property
    def app_id(self) -> str:
        return f"{self.apple_team_id}.{self.apple_bundle_id}"

    def redacted(self) -> list[tuple[str, str]]:
        """Every setting name and value for `myguide-admin limits`; the key shows as <set>/<missing>."""
        rows: list[tuple[str, str]] = []
        for name, attr in _INTS:
            rows.append((name, str(getattr(self, attr))))
        for name, attr in _USD:
            rows.append((name, str(Decimal(getattr(self, attr)) / _MICRO)))
        rows.append(("ALLOW_DEVELOPMENT_ATTEST", "1" if self.allow_development_attest else "0"))
        for kind in KINDS:
            rows.append((f"MODELS_{kind.upper()}", ",".join(sorted(self.models(kind)))))
        for model in sorted(self.token_prices):
            p = self.token_prices[model]
            rows.append((_price_key(model), f"{p.input_per_m},{p.cached_input_per_m},{p.output_per_m}"))
        for model in sorted(self.speech_char_prices):
            rows.append((_price_key(model, speech=True), str(self.speech_char_prices[model])))
        rows.append(("APPLE_TEAM_ID", self.apple_team_id))
        rows.append(("APPLE_BUNDLE_ID", self.apple_bundle_id))
        rows.append(("OPENAI_API_KEY", "<set>" if self.openai_api_key else "<missing>"))
        return rows


# (env name, attribute, minimum). LISTEN_PORT additionally has a maximum.
_INT_SPECS: list[tuple[str, str, int]] = [
    ("QUOTA_STORY_PER_DAY", "quota_story_per_day", 0),
    ("QUOTA_SPEECH_PER_DAY", "quota_speech_per_day", 0),
    ("QUOTA_IMAGE_PER_DAY", "quota_image_per_day", 0),
    ("RATE_PER_MINUTE", "rate_per_minute", 1),
    ("REQUESTS_PER_DEVICE_PER_DAY", "requests_per_device_per_day", 0),
    ("TOKENS_PER_DEVICE_PER_DAY", "tokens_per_device_per_day", 0),
    ("SPEECH_CHARS_PER_DEVICE_PER_DAY", "speech_chars_per_device_per_day", 0),
    ("MAX_BODY_BYTES", "max_body_bytes", 1),
    ("UPSTREAM_TIMEOUT_SECONDS", "upstream_timeout_seconds", 1),
    ("CHALLENGE_TTL_SECONDS", "challenge_ttl_seconds", 1),
    ("ATTESTS_PER_IP_PER_HOUR", "attests_per_ip_per_hour", 0),
    ("LOG_RETENTION_DAYS", "log_retention_days", 1),
    ("CREDITS_PER_STORY", "credits_per_story", 0),
    ("CREDITS_PER_SPEECH", "credits_per_speech", 0),
    ("CREDITS_PER_IMAGE", "credits_per_image", 0),
    ("LISTEN_PORT", "listen_port", 1),
    ("CHALLENGES_MAX_OUTSTANDING", "challenges_max_outstanding", 1),
    ("CHALLENGES_PER_IP_PER_HOUR", "challenges_per_ip_per_hour", 1),
    ("ATTEST_MAX_BODY_BYTES", "attest_max_body_bytes", 1),
    ("MAX_OUTPUT_TOKENS_STORY", "max_output_tokens_story", 1),
    ("MAX_INFLIGHT_PER_DEVICE", "max_inflight_per_device", 1),
]
_INTS = [(n, a) for n, a, _ in _INT_SPECS]
_USD = [("DAILY_SPEND_CAP_USD", "daily_spend_cap_micro"), ("DEVICE_SPEND_CAP_USD", "device_spend_cap_micro")]


def _price_key(model: str, speech: bool = False) -> str:
    norm = model.upper().replace("-", "_").replace(".", "_")
    return f"PRICE_SPEECH_{norm}" if speech else f"PRICE_{norm}"


def _get(env: Mapping[str, str], name: str) -> str:
    raw = env.get(name)
    if raw is None:
        raise ConfigError(f"{name}: missing")
    return raw.strip()


def _int(env: Mapping[str, str], name: str, minimum: int, maximum: int | None = None) -> int:
    raw = _get(env, name)
    if not (raw.isascii() and raw.isdigit()):
        raise ConfigError(f"{name}: must be a whole number >= {minimum}, got {raw!r}")
    value = int(raw)
    if value < minimum or (maximum is not None and value > maximum):
        bound = f"{minimum}..{maximum}" if maximum is not None else f">= {minimum}"
        raise ConfigError(f"{name}: must be a whole number {bound}, got {raw!r}")
    return value


def _decimal(name: str, raw: str, what: str = "USD amount") -> Decimal:
    try:
        d = Decimal(raw.strip())
    except InvalidOperation:
        raise ConfigError(f"{name}: must be a {what} >= 0, got {raw!r}") from None
    if not d.is_finite() or d < 0:
        raise ConfigError(f"{name}: must be a {what} >= 0, got {raw!r}")
    return d


def _usd_micro(env: Mapping[str, str], name: str) -> int:
    d = _decimal(name, _get(env, name))
    return int((d * _MICRO).quantize(Decimal(1), rounding=ROUND_HALF_UP))


def _models(env: Mapping[str, str], kind: str, seen: dict[str, str]) -> frozenset[str]:
    name = f"MODELS_{kind.upper()}"
    models = [m.strip() for m in _get(env, name).split(",") if m.strip()]
    if not models:
        raise ConfigError(f"{name}: needs at least one model")
    for m in models:
        if m in seen:
            raise ConfigError(f"{name}: model {m!r} is already listed under {seen[m]}")
        seen[m] = name
    return frozenset(models)


def _token_price(env: Mapping[str, str], model: str) -> Price:
    name = _price_key(model)
    raw = env.get(name)
    if raw is None:
        raise ConfigError(f"{name}: missing (needed for model {model!r})")
    parts = raw.split(",")
    if len(parts) != 3:
        raise ConfigError(f"{name}: must be <input>,<cached_input>,<output> in USD per million, got {raw!r}")
    a, b, c = (_decimal(name, p, "USD price") for p in parts)
    return Price(a, b, c)


def parse_settings(env: Mapping[str, str]) -> Settings:
    ints = {attr: _int(env, name, lo, 65535 if name == "LISTEN_PORT" else None) for name, attr, lo in _INT_SPECS}
    daily = _usd_micro(env, "DAILY_SPEND_CAP_USD")
    device = _usd_micro(env, "DEVICE_SPEND_CAP_USD")

    flag = _get(env, "ALLOW_DEVELOPMENT_ATTEST")
    if flag not in ("0", "1"):
        raise ConfigError(f"ALLOW_DEVELOPMENT_ATTEST: must be 0 or 1, got {flag!r}")

    seen: dict[str, str] = {}
    story = _models(env, "story", seen)
    speech = _models(env, "speech", seen)
    image = _models(env, "image", seen)

    token_prices = {m: _token_price(env, m) for m in sorted(story | image)}
    speech_prices: dict[str, Decimal] = {}
    for m in sorted(speech):
        name = _price_key(m, speech=True)
        raw = env.get(name)
        if raw is None:
            raise ConfigError(f"{name}: missing (needed for model {m!r})")
        speech_prices[m] = _decimal(name, raw, "USD price per million characters")

    team = _get(env, "APPLE_TEAM_ID")
    if not team:
        raise ConfigError("APPLE_TEAM_ID: must not be empty")
    bundle = _get(env, "APPLE_BUNDLE_ID")
    if not bundle:
        raise ConfigError("APPLE_BUNDLE_ID: must not be empty")
    key = _get(env, "OPENAI_API_KEY")
    if not key:
        raise ConfigError("OPENAI_API_KEY: must not be empty; the service will not start without it")

    return Settings(
        **ints,
        daily_spend_cap_micro=daily,
        device_spend_cap_micro=device,
        allow_development_attest=flag == "1",
        models_story=story,
        models_speech=speech,
        models_image=image,
        token_prices=token_prices,
        speech_char_prices=speech_prices,
        apple_team_id=team,
        apple_bundle_id=bundle,
        openai_api_key=key,
    )


def load_settings(path: Path) -> Settings:
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as e:
        raise ConfigError(f"{path}: cannot read settings file ({e.strerror or e})") from None
    env: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep:
            continue
        env[key.strip()] = value.strip()
    return parse_settings(env)
