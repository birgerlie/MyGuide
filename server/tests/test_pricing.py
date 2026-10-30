from pathlib import Path

import pytest

from myguide.config import parse_settings
from myguide.pricing import Usage, cost_micro, usage_from_json

TEMPLATE = Path(__file__).parent.parent / "env.template"


def settings(**overrides):
    env = {}
    for line in TEMPLATE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        k, _, v = line.partition("=")
        env[k] = v
    env["OPENAI_API_KEY"] = "sk-test"
    env.update(overrides)
    return parse_settings(env)


# Prices are USD per million tokens, so tokens x price = micro-USD directly.

def test_story_cost_with_cached_input():
    s = settings()  # gpt-5-mini 0.25 / 0.025 / 2.00
    # (1000-200)*0.25 + 200*0.025 + 500*2.00 = 200 + 5 + 1000 = 1205 µUSD
    assert cost_micro(s, "story", "gpt-5-mini", Usage(input_tokens=1000, cached_tokens=200, output_tokens=500)) == 1205


def test_story_cost_input_only():
    s = settings()
    # 10000*0.25 = 2500 µUSD
    assert cost_micro(s, "story", "gpt-5-mini", Usage(input_tokens=10000)) == 2500


def test_speech_cost_per_character():
    s = settings()  # gpt-4o-mini-tts 15.00 per million characters
    # 900*15 = 13500 µUSD
    assert cost_micro(s, "speech", "gpt-4o-mini-tts", Usage(speech_chars=900)) == 13500


def test_speech_cost_rounds_half_up_once():
    tiny = settings(PRICE_SPEECH_GPT_4O_MINI_TTS="0.0004")
    # 1*0.0004 = 0.0004 -> rounds to 0
    assert cost_micro(tiny, "speech", "gpt-4o-mini-tts", Usage(speech_chars=1)) == 0
    half = settings(PRICE_SPEECH_GPT_4O_MINI_TTS="0.5")
    # 3*0.5 = 1.5 -> half-up -> 2 (banker's rounding also gives 2, hence the next case)
    assert cost_micro(half, "speech", "gpt-4o-mini-tts", Usage(speech_chars=3)) == 2
    # 5*0.5 = 2.5 -> half-up -> 3 (banker's rounding would give 2)
    assert cost_micro(half, "speech", "gpt-4o-mini-tts", Usage(speech_chars=5)) == 3


def test_image_cost():
    s = settings()  # gpt-image-2.5-flare 5 / 1.25 / 40
    # 100*5 + 4000*40 = 500 + 160000 = 160500 µUSD
    assert cost_micro(s, "image", "gpt-image-2.5-flare", Usage(input_tokens=100, output_tokens=4000)) == 160500


def test_rounding_happens_once_per_call_not_per_part():
    s = settings(PRICE_GPT_5_MINI="0.4,0.4,0.4")
    # per part: 1*0.4 -> 0 and 1*0.4 -> 0 = 0; once: (1*0.4 + 1*0.4) = 0.8 -> 1
    assert cost_micro(s, "story", "gpt-5-mini", Usage(input_tokens=1, output_tokens=1)) == 1


def test_cached_above_input_never_lowers_cost():
    s = settings()
    # cached is clamped to input: (100-100)*0.25 + 100*0.025 = 2.5 -> 3 µUSD
    # (unclamped: (100-400)*0.25 + 400*0.025 = -75 + 10 = -65, a negative cost)
    assert cost_micro(s, "story", "gpt-5-mini", Usage(input_tokens=100, cached_tokens=400)) == 3


def test_zero_usage_costs_nothing():
    s = settings()
    assert cost_micro(s, "story", "gpt-5-mini", Usage()) == 0
    assert cost_micro(s, "speech", "gpt-4o-mini-tts", Usage()) == 0


def test_unknown_model_or_kind_raises():
    s = settings()
    with pytest.raises(ValueError):
        cost_micro(s, "story", "gpt-4o", Usage(input_tokens=1))
    with pytest.raises(ValueError):
        cost_micro(s, "speech", "gpt-5-mini", Usage(speech_chars=1))
    with pytest.raises(ValueError):
        cost_micro(s, "video", "gpt-5-mini", Usage(input_tokens=1))


def test_usage_from_json_full():
    obj = {"usage": {"input_tokens": 1000, "output_tokens": 500,
                     "input_tokens_details": {"cached_tokens": 200}}}
    assert usage_from_json(obj) == Usage(input_tokens=1000, cached_tokens=200, output_tokens=500)


def test_usage_from_json_bad_part_is_zero():
    assert usage_from_json({"usage": {"input_tokens": 10, "output_tokens": "x"}}) == Usage(10, 0, 0)


def test_usage_from_json_no_usage():
    assert usage_from_json({}) == Usage()


@pytest.mark.parametrize("obj", [
    {"usage": None},
    {"usage": "lots"},
    {"usage": {"input_tokens": True, "output_tokens": 2.5}},
    {"usage": {"input_tokens": -5, "output_tokens": None}},
    {"usage": {"input_tokens_details": "x"}},
    {"usage": {"input_tokens_details": {"cached_tokens": "7"}}},
])
def test_usage_from_json_malformed_parts_are_zero(obj):
    assert usage_from_json(obj) == Usage()
