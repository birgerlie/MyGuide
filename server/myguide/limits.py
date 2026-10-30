"""Admission before a call and settlement after it (spec 6, 6.2).

Admission decides in one `BEGIN IMMEDIATE` transaction whether a device may make a call: abuse guards first,
then the free daily quota of the kind, then the wallet's credits. Settlement records the outcome: a returned
unit or a refund when the call was not kept, the usage and cost on the day the unit was reserved, and one
`calls` row. Day = UTC date of `now`. Money is integer micro-USD.
"""
from __future__ import annotations

import logging
import sqlite3
import threading
from collections import deque
from collections.abc import Callable, Hashable
from dataclasses import dataclass
from datetime import datetime
from uuid import uuid4

from . import ledger
from .config import KINDS, Settings
from .db import iso
from .pricing import Usage, cost_micro

log = logging.getLogger(__name__)

_TOKEN_KINDS = ("story", "image")


@dataclass
class Admission:
    allowed: bool
    status: int
    code: str | None
    call_id: str
    device_id: int
    wallet_id: int
    kind: str
    day: str
    paid_with: str | None  # "free" | "credits" | "none" (zero-credit kind) | None when refused
    credits_debited: int
    free_left: dict[str, int]
    credits: int


def utc_day(now: datetime) -> str:
    """YYYY-MM-DD of `now` in UTC; raises ValueError for a naive datetime."""
    return iso(now)[:10]


def _check_kind(kind: str) -> None:
    if kind not in KINDS:
        raise ValueError(f"unknown kind {kind!r}")


def _rollback(conn: sqlite3.Connection) -> None:
    if conn.in_transaction:
        conn.execute("ROLLBACK")


def _device(conn: sqlite3.Connection, device_id: int) -> sqlite3.Row:
    row = conn.execute("SELECT id, wallet_id FROM devices WHERE id=?", (device_id,)).fetchone()
    if row is None:
        raise LookupError(f"no device {device_id}")
    return row


def _count_request(conn: sqlite3.Connection, device_id: int, day: str, refused: int) -> None:
    conn.execute(
        "INSERT INTO device_days (device_id, day, requests, refused) VALUES (?,?,1,?) "
        "ON CONFLICT (device_id, day) DO UPDATE SET requests = requests + 1, refused = refused + excluded.refused",
        (device_id, day, refused),
    )


def allowance(conn: sqlite3.Connection, settings: Settings, device_id: int, wallet_id: int,
              day: str) -> tuple[dict[str, int], int]:
    """Free calls left per kind on `day` (never below 0) and the wallet's balance."""
    row = conn.execute(
        "SELECT used_story, used_speech, used_image FROM device_days WHERE device_id=? AND day=?",
        (device_id, day),
    ).fetchone()
    free_left = {
        kind: max(settings.quota(kind) - (row[f"used_{kind}"] if row is not None else 0), 0) for kind in KINDS
    }
    return free_left, ledger.balance(conn, wallet_id)


def count_refused(conn: sqlite3.Connection, settings: Settings, device_id: int,
                  now: datetime) -> tuple[dict[str, int], int]:
    """Count a request turned away before admission (404, 400, 413, rate); returns the header values."""
    day = utc_day(now)
    conn.execute("BEGIN IMMEDIATE")
    try:
        device = _device(conn, device_id)
        _count_request(conn, device_id, day, refused=1)
        result = allowance(conn, settings, device_id, device["wallet_id"], day)
        conn.execute("COMMIT")
    except BaseException:
        _rollback(conn)
        raise
    return result


def _guard(settings: Settings, kind: str, today: sqlite3.Row, server_cost: int) -> tuple[int, str] | None:
    """The first abuse guard that holds, as (status, code); None when all pass."""
    if today["requests"] > settings.requests_per_device_per_day:
        return 429, "daily_quota"
    if server_cost >= settings.daily_spend_cap_micro:
        return 503, "server_budget"
    if today["cost_micro"] >= settings.device_spend_cap_micro:
        return 429, "daily_quota"
    if kind in _TOKEN_KINDS and today["tokens_in"] + today["tokens_out"] >= settings.tokens_per_device_per_day:
        return 429, "daily_quota"
    if kind == "speech" and today["speech_chars"] >= settings.speech_chars_per_device_per_day:
        return 429, "daily_quota"
    return None


def admit(conn: sqlite3.Connection, settings: Settings, device: sqlite3.Row, kind: str,
          now: datetime) -> Admission:
    """Decide whether `device` may make one `kind` call now, and reserve or debit it if so.

    A refusal returns `allowed=False` with status and code; it writes no `calls` row and is never settled.
    The device row is read again inside the transaction, so a wallet changed since `device` was read is used.
    """
    _check_kind(kind)
    day = utc_day(now)
    call_id = uuid4().hex
    used_col = f"used_{kind}"  # kind is one of KINDS, so the column name is safe to interpolate
    conn.execute("BEGIN IMMEDIATE")
    try:
        current = _device(conn, device["id"])
        device_id, wallet_id = current["id"], current["wallet_id"]
        _count_request(conn, device_id, day, refused=0)
        today = conn.execute(
            "SELECT * FROM device_days WHERE device_id=? AND day=?", (device_id, day)
        ).fetchone()
        server = conn.execute("SELECT cost_micro FROM server_days WHERE day=?", (day,)).fetchone()
        server_cost = server["cost_micro"] if server is not None else 0

        refusal = _guard(settings, kind, today, server_cost)
        paid_with: str | None = None
        debited = 0
        if refusal is None:
            price = settings.credits(kind)
            if today[used_col] < settings.quota(kind):
                conn.execute(
                    f"UPDATE device_days SET {used_col} = {used_col} + 1 WHERE device_id=? AND day=?",
                    (device_id, day),
                )
                paid_with = "free"
            elif price == 0:
                paid_with = "none"
            elif ledger.try_debit(conn, wallet_id, price, call_id, now):
                paid_with, debited = "credits", price
            else:
                refusal = (429, "daily_quota")
        if refusal is not None:
            conn.execute(
                "UPDATE device_days SET refused = refused + 1 WHERE device_id=? AND day=?", (device_id, day)
            )
        free_left, credits = allowance(conn, settings, device_id, wallet_id, day)
        conn.execute("COMMIT")
    except BaseException:
        _rollback(conn)
        raise
    status, code = refusal if refusal is not None else (200, None)
    return Admission(
        allowed=refusal is None, status=status, code=code, call_id=call_id, device_id=device_id,
        wallet_id=wallet_id, kind=kind, day=day, paid_with=paid_with, credits_debited=debited,
        free_left=free_left, credits=credits,
    )


def settle(conn: sqlite3.Connection, settings: Settings, admission: Admission, *, kept: bool, status: int,
           model: str, usage: Usage, latency_ms: int, now: datetime) -> None:
    """Record the outcome of an admitted call, once per `call_id`; a repeat is a no-op.

    Not kept: a free unit goes back to `admission.day` (not today), credits are refunded.
    Usage and cost are always added to `admission.day`, kept or not: the tokens were spent.
    """
    if not admission.allowed:
        raise ValueError("a refused admission is never settled")
    _check_kind(admission.kind)
    for name in ("input_tokens", "cached_tokens", "output_tokens", "speech_chars"):
        if getattr(usage, name) < 0:
            raise ValueError(f"usage.{name} must be >= 0")
    cost = cost_micro(settings, admission.kind, model, usage)
    at = iso(now)
    day = admission.day
    conn.execute("BEGIN IMMEDIATE")
    try:
        inserted = conn.execute(
            "INSERT INTO calls (call_id, at, day, device_id, kind, model, status, latency_ms, tokens_in, "
            "tokens_out, tokens_cached, speech_chars, cost_micro, kept, paid_with) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT (call_id) DO NOTHING",
            (admission.call_id, at, day, admission.device_id, admission.kind, model, status, latency_ms,
             usage.input_tokens, usage.output_tokens, usage.cached_tokens, usage.speech_chars, cost,
             1 if kept else 0, admission.paid_with),
        ).rowcount
        if inserted == 0:
            conn.execute("COMMIT")
            return
        if not kept:
            if admission.paid_with == "free":
                used_col = f"used_{admission.kind}"
                conn.execute(
                    f"UPDATE device_days SET {used_col} = {used_col} - 1 "
                    f"WHERE device_id=? AND day=? AND {used_col} > 0",
                    (admission.device_id, day),
                )
            elif admission.paid_with == "credits":
                if not ledger.refund(conn, admission.wallet_id, admission.credits_debited,
                                     admission.call_id, now):
                    log.warning("settle: no debit to refund for call %s", admission.call_id)
        conn.execute(
            "INSERT INTO device_days (device_id, day, tokens_in, tokens_out, tokens_cached, speech_chars, "
            "cost_micro) VALUES (?,?,?,?,?,?,?) ON CONFLICT (device_id, day) DO UPDATE SET "
            "tokens_in = tokens_in + excluded.tokens_in, tokens_out = tokens_out + excluded.tokens_out, "
            "tokens_cached = tokens_cached + excluded.tokens_cached, "
            "speech_chars = speech_chars + excluded.speech_chars, cost_micro = cost_micro + excluded.cost_micro",
            (admission.device_id, day, usage.input_tokens, usage.output_tokens, usage.cached_tokens,
             usage.speech_chars, cost),
        )
        conn.execute(
            "INSERT INTO server_days (day, cost_micro) VALUES (?,?) "
            "ON CONFLICT (day) DO UPDATE SET cost_micro = cost_micro + excluded.cost_micro",
            (day, cost),
        )
        conn.execute("COMMIT")
    except BaseException:
        _rollback(conn)
        raise


class RateWindow:
    """Sliding-window hit counter in memory, per key (spec 6: per-minute rate; Ruling 4).

    A hit counts while `hit_time > now - window_seconds`. Refused hits are recorded too, so a client that
    keeps hammering stays refused. The limit is read on every hit, so a settings reload applies at once.
    """

    def __init__(self, limit_getter: Callable[[], int], window_seconds: float) -> None:
        if window_seconds <= 0:
            raise ValueError("window_seconds must be > 0")
        self._limit = limit_getter
        self._window = window_seconds
        self._hits: dict[Hashable, deque[float]] = {}
        self._lock = threading.Lock()
        self._last_sweep: float | None = None

    def hit(self, key: Hashable, now: float) -> bool:
        """Record a hit; False when this hit takes the key over the limit within the window."""
        start = now - self._window
        with self._lock:
            self._sweep(now, start)
            hits = self._hits.setdefault(key, deque())
            while hits and hits[0] <= start:
                hits.popleft()
            hits.append(now)
            return len(hits) <= self._limit()

    def _sweep(self, now: float, start: float) -> None:
        """Drop keys with no hit in the window, at most once per window, so idle keys do not pile up."""
        if self._last_sweep is not None and now - self._last_sweep < self._window:
            return
        self._last_sweep = now
        for key in [k for k, hits in self._hits.items() if not hits or hits[-1] <= start]:
            del self._hits[key]
