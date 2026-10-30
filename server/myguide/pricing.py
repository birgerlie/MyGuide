"""Cost of one call in integer micro-USD (spec 6, 6.1).

Prices are USD per million tokens (or speech characters), so `count x price` is micro-USD.
The sum is rounded half-up to an integer once per call, never per part.
"""
from __future__ import annotations

from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal
from typing import Any

from .config import KINDS, Settings


@dataclass(frozen=True)
class Usage:
    input_tokens: int = 0
    cached_tokens: int = 0
    output_tokens: int = 0
    speech_chars: int = 0


def cost_micro(settings: Settings, kind: str, model: str, usage: Usage) -> int:
    """Raises ValueError for an unknown kind or a model without a price for that kind."""
    if kind not in KINDS:
        raise ValueError(f"unknown kind {kind!r}")
    if kind == "speech":
        price = settings.speech_char_prices.get(model)
        if price is None:
            raise ValueError(f"no speech price for model {model!r}")
        total = usage.speech_chars * price
    else:
        p = settings.token_prices.get(model)
        if p is None:
            raise ValueError(f"no token price for model {model!r}")
        # Cached tokens are part of the input; clamp so a malformed report cannot make the cost negative.
        cached = min(usage.cached_tokens, usage.input_tokens)
        total = (
            (usage.input_tokens - cached) * p.input_per_m
            + cached * p.cached_input_per_m
            + usage.output_tokens * p.output_per_m
        )
    return int(Decimal(total).quantize(Decimal(1), rounding=ROUND_HALF_UP))


def _count(obj: Any, key: str) -> int:
    """A non-negative int at obj[key], else 0. bool is not a count."""
    if not isinstance(obj, dict):
        return 0
    value = obj.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return 0
    return value


def usage_from_json(obj: dict) -> Usage:
    """Usage from a Responses or images body (or a `response.completed` event's `response`)."""
    usage = obj.get("usage") if isinstance(obj, dict) else None
    if not isinstance(usage, dict):
        return Usage()
    return Usage(
        input_tokens=_count(usage, "input_tokens"),
        cached_tokens=_count(usage.get("input_tokens_details"), "cached_tokens"),
        output_tokens=_count(usage, "output_tokens"),
    )
