from decimal import Decimal
from pathlib import Path

import pytest

from myguide.config import ConfigError, Price, load_settings, parse_settings

TEMPLATE = Path(__file__).parent.parent / "env.template"


def template_env(**overrides):
    env = {}
    for line in TEMPLATE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        k, _, v = line.partition("=")
        env[k] = v
    env["OPENAI_API_KEY"] = "sk-test"
    env.update(overrides)
    return env


INT_SETTINGS = [
    "QUOTA_STORY_PER_DAY", "QUOTA_SPEECH_PER_DAY", "QUOTA_IMAGE_PER_DAY",
    "RATE_PER_MINUTE", "REQUESTS_PER_DEVICE_PER_DAY", "TOKENS_PER_DEVICE_PER_DAY",
    "SPEECH_CHARS_PER_DEVICE_PER_DAY", "MAX_BODY_BYTES", "UPSTREAM_TIMEOUT_SECONDS",
    "CHALLENGE_TTL_SECONDS", "ATTESTS_PER_IP_PER_HOUR", "LOG_RETENTION_DAYS",
    "CREDITS_PER_STORY", "CREDITS_PER_SPEECH", "CREDITS_PER_IMAGE", "LISTEN_PORT",
    "CHALLENGES_MAX_OUTSTANDING", "CHALLENGES_PER_IP_PER_HOUR", "ATTEST_MAX_BODY_BYTES",
]


def test_template_defaults():
    s = parse_settings(template_env())
    assert s.quota_story_per_day == 80
    assert s.quota_image_per_day == 4
    assert s.rate_per_minute == 15
    assert s.requests_per_device_per_day == 200
    assert s.tokens_per_device_per_day == 1_500_000
    assert s.speech_chars_per_device_per_day == 200_000
    assert s.daily_spend_cap_micro == 5_000_000
    assert s.device_spend_cap_micro == 1_000_000
    assert s.max_body_bytes == 8_388_608
    assert s.credits("speech") == 0
    assert s.credits("image") == 2
    assert s.models("story") == {"gpt-5-mini"}
    assert s.app_id == "MW432M4HL3.io.github.birgerlie.MyGuide"
    assert s.token_prices["gpt-5-mini"] == Price(Decimal("0.25"), Decimal("0.025"), Decimal("2.00"))
    assert s.speech_char_prices["gpt-4o-mini-tts"] == Decimal("15.00")
    assert s.quota("speech") == 80
    assert s.listen_port == 8710
    assert s.allow_development_attest is True
    assert s.challenges_max_outstanding == 10000
    assert s.challenges_per_ip_per_hour == 40
    assert s.attest_max_body_bytes == 65536


def test_template_has_empty_key_and_start_refuses():
    with pytest.raises(ConfigError) as e:
        load_settings(TEMPLATE)
    assert str(e.value).startswith("OPENAI_API_KEY")


def _cases():
    cases = [(f"missing {k}", {k: None}, k) for k in INT_SETTINGS]
    cases += [
        ("abc", {"QUOTA_STORY_PER_DAY": "abc"}, "QUOTA_STORY_PER_DAY"),
        ("negative", {"RATE_PER_MINUTE": "-1"}, "RATE_PER_MINUTE"),
        ("zero rate", {"RATE_PER_MINUTE": "0"}, "RATE_PER_MINUTE"),
        ("float int", {"QUOTA_STORY_PER_DAY": "1.5"}, "QUOTA_STORY_PER_DAY"),
        ("port 0", {"LISTEN_PORT": "0"}, "LISTEN_PORT"),
        ("port big", {"LISTEN_PORT": "65536"}, "LISTEN_PORT"),
        ("challenges cap 0", {"CHALLENGES_MAX_OUTSTANDING": "0"}, "CHALLENGES_MAX_OUTSTANDING"),
        ("challenges cap abc", {"CHALLENGES_MAX_OUTSTANDING": "abc"}, "CHALLENGES_MAX_OUTSTANDING"),
        ("challenges per ip 0", {"CHALLENGES_PER_IP_PER_HOUR": "0"}, "CHALLENGES_PER_IP_PER_HOUR"),
        ("challenges per ip neg", {"CHALLENGES_PER_IP_PER_HOUR": "-5"}, "CHALLENGES_PER_IP_PER_HOUR"),
        ("attest body 0", {"ATTEST_MAX_BODY_BYTES": "0"}, "ATTEST_MAX_BODY_BYTES"),
        ("attest body float", {"ATTEST_MAX_BODY_BYTES": "64.5"}, "ATTEST_MAX_BODY_BYTES"),
        ("usd word", {"DAILY_SPEND_CAP_USD": "five"}, "DAILY_SPEND_CAP_USD"),
        ("usd negative", {"DEVICE_SPEND_CAP_USD": "-1"}, "DEVICE_SPEND_CAP_USD"),
        ("usd nan", {"DEVICE_SPEND_CAP_USD": "NaN"}, "DEVICE_SPEND_CAP_USD"),
        ("usd missing", {"DAILY_SPEND_CAP_USD": None}, "DAILY_SPEND_CAP_USD"),
        ("attest yes", {"ALLOW_DEVELOPMENT_ATTEST": "yes"}, "ALLOW_DEVELOPMENT_ATTEST"),
        ("attest missing", {"ALLOW_DEVELOPMENT_ATTEST": None}, "ALLOW_DEVELOPMENT_ATTEST"),
        ("models empty", {"MODELS_STORY": ""}, "MODELS_STORY"),
        ("models only commas", {"MODELS_IMAGE": " , "}, "MODELS_IMAGE"),
        ("models missing", {"MODELS_SPEECH": None}, "MODELS_SPEECH"),
        ("model in two lists", {"MODELS_IMAGE": "gpt-5-mini,gpt-image-2.5-flare"}, "MODELS_IMAGE"),
        ("no price", {"PRICE_GPT_5_MINI": None}, "PRICE_GPT_5_MINI"),
        ("two parts", {"PRICE_GPT_5_MINI": "0.25,0.025"}, "PRICE_GPT_5_MINI"),
        ("bad part", {"PRICE_GPT_5_MINI": "0.25,x,2"}, "PRICE_GPT_5_MINI"),
        ("negative part", {"PRICE_GPT_5_MINI": "0.25,-1,2"}, "PRICE_GPT_5_MINI"),
        ("no speech price", {"PRICE_SPEECH_GPT_4O_MINI_TTS": None}, "PRICE_SPEECH_GPT_4O_MINI_TTS"),
        ("bad speech price", {"PRICE_SPEECH_GPT_4O_MINI_TTS": "a"}, "PRICE_SPEECH_GPT_4O_MINI_TTS"),
        ("team missing", {"APPLE_TEAM_ID": None}, "APPLE_TEAM_ID"),
        ("bundle empty", {"APPLE_BUNDLE_ID": ""}, "APPLE_BUNDLE_ID"),
        ("key missing", {"OPENAI_API_KEY": None}, "OPENAI_API_KEY"),
    ]
    return cases


@pytest.mark.parametrize("label,overrides,name", _cases(), ids=[c[0] for c in _cases()])
def test_bad_value_names_setting(label, overrides, name):
    env = template_env()
    for k, v in overrides.items():
        if v is None:
            env.pop(k, None)
        else:
            env[k] = v
    with pytest.raises(ConfigError) as e:
        parse_settings(env)
    assert str(e.value).startswith(name)


def test_zero_allowed_where_documented():
    s = parse_settings(template_env(QUOTA_STORY_PER_DAY="0", CREDITS_PER_IMAGE="0", DAILY_SPEND_CAP_USD="0"))
    assert s.quota("story") == 0 and s.credits("image") == 0 and s.daily_spend_cap_micro == 0


def test_usd_to_micro():
    # 5.00 * 1e6 = 5_000_000; 0.000001 * 1e6 = 1; 1.5 * 1e6 = 1_500_000
    assert parse_settings(template_env(DAILY_SPEND_CAP_USD="5.00")).daily_spend_cap_micro == 5_000_000
    assert parse_settings(template_env(DAILY_SPEND_CAP_USD="0.000001")).daily_spend_cap_micro == 1
    assert parse_settings(template_env(DAILY_SPEND_CAP_USD="1.5")).daily_spend_cap_micro == 1_500_000


def test_extra_keys_ignored_and_whitespace_trimmed():
    s = parse_settings(template_env(SOMETHING_ELSE="x", QUOTA_IMAGE_PER_DAY=" 7 "))
    assert s.quota("image") == 7


def test_multiple_models_per_kind():
    env = template_env(MODELS_STORY="gpt-5-mini, gpt-5", PRICE_GPT_5="1,0.1,8")
    s = parse_settings(env)
    assert s.models("story") == {"gpt-5-mini", "gpt-5"}
    assert s.token_prices["gpt-5"] == Price(Decimal("1"), Decimal("0.1"), Decimal("8"))


def test_unknown_kind_raises():
    s = parse_settings(template_env())
    with pytest.raises(ValueError):
        s.quota("video")


def test_redacted_hides_key():
    rows = parse_settings(template_env()).redacted()
    assert all("sk-test" not in v for _, v in rows)
    assert ("OPENAI_API_KEY", "<set>") in rows
    names = [n for n, _ in rows]
    assert "QUOTA_STORY_PER_DAY" in names and "PRICE_GPT_5_MINI" in names and "MODELS_STORY" in names
    assert ("CHALLENGES_MAX_OUTSTANDING", "10000") in rows
    assert ("CHALLENGES_PER_IP_PER_HOUR", "40") in rows
    assert ("ATTEST_MAX_BODY_BYTES", "65536") in rows


def test_load_settings_reads_file(tmp_path):
    env = template_env()
    lines = ["# header", "", "   "]
    for k, v in env.items():
        lines.append(f"{k}={v}")
        lines.append("# between")
    p = tmp_path / "env"
    p.write_text("\n".join(lines) + "\n")
    assert load_settings(p) == parse_settings(env)


def test_load_settings_missing_file(tmp_path):
    with pytest.raises(ConfigError):
        load_settings(tmp_path / "nope")


def test_attest_guard_settings_accept_one():
    s = parse_settings(template_env(CHALLENGES_MAX_OUTSTANDING="1", CHALLENGES_PER_IP_PER_HOUR="1",
                                    ATTEST_MAX_BODY_BYTES="1"))
    assert (s.challenges_max_outstanding, s.challenges_per_ip_per_hour, s.attest_max_body_bytes) == (1, 1, 1)
