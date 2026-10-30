import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from myguide import ledger
from myguide.config import parse_settings
from myguide.db import connect, create_device
from myguide.limits import Admission, RateWindow, admit, allowance, count_refused, settle
from myguide.pricing import Usage

TEMPLATE = Path(__file__).parent.parent / "env.template"
NOW = datetime(2026, 10, 30, 12, 0, tzinfo=timezone.utc)
DAY = "2026-10-30"
MODEL = {"story": "gpt-5-mini", "speech": "gpt-4o-mini-tts", "image": "gpt-image-2.5-flare"}


def settings(**overrides):
    env = {}
    for line in TEMPLATE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        k, _, v = line.partition("=")
        env[k] = v
    env["OPENAI_API_KEY"] = "sk-test"
    env.update({k: str(v) for k, v in overrides.items()})
    return parse_settings(env)


@pytest.fixture
def db_path(tmp_path):
    return tmp_path / "g.db"


@pytest.fixture
def conn(db_path):
    c = connect(db_path)
    yield c
    c.close()


def device(conn, n=1):
    did = create_device(conn, f"key{n}", f"tok{n}", NOW)
    return conn.execute("SELECT * FROM devices WHERE id=?", (did,)).fetchone()


def day_row(conn, device_id, day=DAY):
    return conn.execute("SELECT * FROM device_days WHERE device_id=? AND day=?", (device_id, day)).fetchone()


def used(conn, device_id, kind="story", day=DAY):
    row = day_row(conn, device_id, day)
    return 0 if row is None else row[f"used_{kind}"]


def done(conn, s, adm, *, kept=True, usage=Usage(), now=NOW):
    status = 200 if kept else 500
    settle(conn, s, adm, kept=kept, status=status, model=MODEL[adm.kind], usage=usage, latency_ms=10, now=now)


def test_free_quota_then_429(conn):
    s = settings(QUOTA_STORY_PER_DAY=2, CREDITS_PER_STORY=1)
    d = device(conn)
    a1 = admit(conn, s, d, "story", NOW)
    a2 = admit(conn, s, d, "story", NOW)
    a3 = admit(conn, s, d, "story", NOW)
    assert (a1.allowed, a1.paid_with, a1.status) == (True, "free", 200)
    assert (a2.allowed, a2.paid_with) == (True, "free")
    assert (a3.allowed, a3.status, a3.code, a3.paid_with) == (False, 429, "daily_quota", None)
    # quota 2: after a1 2-1 = 1 left, after a2 0, a3 refused so still 0
    assert [a.free_left["story"] for a in (a1, a2, a3)] == [1, 0, 0]
    assert a3.credits == 0 and a3.call_id and a3.day == DAY
    # a refusal writes no calls row
    assert conn.execute("SELECT COUNT(*) FROM calls").fetchone()[0] == 0
    # 3 requests, 1 refused
    assert (day_row(conn, d["id"])["requests"], day_row(conn, d["id"])["refused"]) == (3, 1)


def test_kept_unit_stays_returned_unit_comes_back(conn):
    s = settings()
    d = device(conn)
    done(conn, s, admit(conn, s, d, "story", NOW), kept=True)
    assert used(conn, d["id"]) == 1
    done(conn, s, admit(conn, s, d, "story", NOW), kept=False)
    assert used(conn, d["id"]) == 1
    rows = conn.execute("SELECT kept, paid_with FROM calls ORDER BY id").fetchall()
    assert [tuple(r) for r in rows] == [(1, "free"), (0, "free")]


def test_free_first_then_credits(conn):
    s = settings(QUOTA_STORY_PER_DAY=1, CREDITS_PER_STORY=1)
    d = device(conn)
    w = d["wallet_id"]
    ledger.grant(conn, w, 3, "tester", NOW)
    first = admit(conn, s, d, "story", NOW)
    assert (first.allowed, first.paid_with, first.credits_debited, first.credits) == (True, "free", 0, 3)
    balances = []
    for _ in range(3):
        a = admit(conn, s, d, "story", NOW)
        assert (a.allowed, a.paid_with, a.credits_debited) == (True, "credits", 1)
        assert a.credits == ledger.balance(conn, w)
        balances.append(a.credits)
    # 3 - 1 = 2, 2 - 1 = 1, 1 - 1 = 0
    assert balances == [2, 1, 0]
    fifth = admit(conn, s, d, "story", NOW)
    assert (fifth.allowed, fifth.status, fifth.code) == (False, 429, "daily_quota")

    ledger.grant(conn, w, 1, "tester-again", NOW)
    paid = admit(conn, s, d, "story", NOW)
    assert (paid.allowed, paid.paid_with, paid.credits) == (True, "credits", 0)
    done(conn, s, paid, kept=False)
    # 0 + 1 refunded = 1
    assert ledger.balance(conn, w) == 1
    refs = conn.execute("SELECT reason, delta FROM ledger WHERE reference=? ORDER BY id", (paid.call_id,)).fetchall()
    assert [tuple(r) for r in refs] == [("debit", -1), ("refund", 1)]


def test_cost_per_kind_from_settings(conn):
    s = settings(CREDITS_PER_IMAGE=2, QUOTA_IMAGE_PER_DAY=0)
    d = device(conn)
    ledger.grant(conn, d["wallet_id"], 3, "tester", NOW)
    a = admit(conn, s, d, "image", NOW)
    # 3 - 2 = 1
    assert (a.allowed, a.paid_with, a.credits_debited, a.credits) == (True, "credits", 2, 1)
    b = admit(conn, s, d, "image", NOW)
    # 1 < 2: refused, balance stays 1
    assert (b.allowed, b.code, b.credits) == (False, "daily_quota", 1)
    assert ledger.balance(conn, d["wallet_id"]) == 1


def test_zero_credit_kind_passes(conn):
    s = settings(QUOTA_SPEECH_PER_DAY=0, CREDITS_PER_SPEECH=0)
    d = device(conn)
    a = admit(conn, s, d, "speech", NOW)
    assert (a.allowed, a.paid_with, a.credits_debited, a.credits) == (True, "none", 0, 0)
    assert ledger.balance(conn, d["wallet_id"]) == 0
    assert used(conn, d["id"], "speech") == 0
    done(conn, s, a, kept=False)  # nothing to return; must not fail
    assert used(conn, d["id"], "speech") == 0 and ledger.balance(conn, d["wallet_id"]) == 0


def test_requests_per_day_counts_refused(conn):
    s = settings(REQUESTS_PER_DEVICE_PER_DAY=3)
    d = device(conn)
    count_refused(conn, s, d["id"], NOW)
    free_left, credits = count_refused(conn, s, d["id"], NOW)
    assert free_left == {"story": 80, "speech": 80, "image": 4} and credits == 0
    a = admit(conn, s, d, "story", NOW)  # requests = 3, 3 > 3 is false
    assert a.allowed
    b = admit(conn, s, d, "story", NOW)  # requests = 4 > 3
    assert (b.allowed, b.status, b.code) == (False, 429, "daily_quota")
    row = day_row(conn, d["id"])
    # requests 2 + 2 = 4; refused 2 (count_refused) + 1 (b) = 3
    assert (row["requests"], row["refused"]) == (4, 3)
    # the refused admit reserved nothing
    assert row["used_story"] == 1


def test_tokens_limit_after_usage(conn):
    s = settings(TOKENS_PER_DEVICE_PER_DAY=1000, SPEECH_CHARS_PER_DEVICE_PER_DAY=100)
    d = device(conn)
    done(conn, s, admit(conn, s, d, "story", NOW), usage=Usage(input_tokens=600, output_tokens=300))
    a = admit(conn, s, d, "story", NOW)  # 600 + 300 = 900 < 1000
    assert a.allowed
    done(conn, s, a, usage=Usage(input_tokens=200))
    b = admit(conn, s, d, "image", NOW)  # 900 + 200 = 1100 >= 1000; image shares the token limit
    assert (b.allowed, b.status, b.code) == (False, 429, "daily_quota")
    assert not admit(conn, s, d, "story", NOW).allowed

    # speech is bound by characters, not tokens
    sp = admit(conn, s, d, "speech", NOW)
    assert sp.allowed
    done(conn, s, sp, usage=Usage(speech_chars=99))
    sp2 = admit(conn, s, d, "speech", NOW)  # 99 < 100
    assert sp2.allowed
    done(conn, s, sp2, usage=Usage(speech_chars=1))
    sp3 = admit(conn, s, d, "speech", NOW)  # 99 + 1 = 100 >= 100
    assert (sp3.allowed, sp3.status, sp3.code) == (False, 429, "daily_quota")


def test_returned_call_still_counts_usage(conn):
    s = settings(TOKENS_PER_DEVICE_PER_DAY=1000)
    d = device(conn)
    done(conn, s, admit(conn, s, d, "story", NOW), kept=False, usage=Usage(input_tokens=1000))
    # the unit came back, but its 1000 tokens (1000*0.25 = 250 µUSD) were spent: 1000 >= 1000
    row = day_row(conn, d["id"])
    assert (row["used_story"], row["tokens_in"], row["cost_micro"]) == (0, 1000, 250)
    assert not admit(conn, s, d, "story", NOW).allowed


def test_server_spend_cap(conn):
    s = settings(DAILY_SPEND_CAP_USD="0.001205")  # 1205 µUSD
    a, b = device(conn, 1), device(conn, 2)
    adm = admit(conn, s, a, "story", NOW)
    # (1000-200)*0.25 + 200*0.025 + 500*2.00 = 200 + 5 + 1000 = 1205 µUSD
    done(conn, s, adm, usage=Usage(input_tokens=1000, cached_tokens=200, output_tokens=500))
    assert conn.execute("SELECT cost_micro FROM server_days WHERE day=?", (DAY,)).fetchone()[0] == 1205
    refused = admit(conn, s, b, "story", NOW)  # 1205 >= 1205
    assert (refused.allowed, refused.status, refused.code) == (False, 503, "server_budget")
    assert used(conn, b["id"]) == 0 and day_row(conn, b["id"])["refused"] == 1
    tomorrow = admit(conn, s, b, "story", NOW + timedelta(days=1))
    assert tomorrow.allowed and tomorrow.day == "2026-10-31"


def test_device_spend_cap(conn):
    s = settings(DEVICE_SPEND_CAP_USD="0.0025")  # 2500 µUSD
    a, b = device(conn, 1), device(conn, 2)
    # 10000*0.25 = 2500 µUSD
    done(conn, s, admit(conn, s, a, "story", NOW), usage=Usage(input_tokens=10000))
    assert day_row(conn, a["id"])["cost_micro"] == 2500
    refused = admit(conn, s, a, "story", NOW)  # 2500 >= 2500
    assert (refused.allowed, refused.status, refused.code) == (False, 429, "daily_quota")
    assert admit(conn, s, b, "story", NOW).allowed


def test_day_boundary(conn):
    s = settings(QUOTA_STORY_PER_DAY=1)
    d = device(conn)
    late = datetime(2026, 10, 30, 23, 59, 59, tzinfo=timezone.utc)
    first = admit(conn, s, d, "story", late)
    assert first.allowed and first.day == DAY
    assert not admit(conn, s, d, "story", late).allowed
    nxt = admit(conn, s, d, "story", datetime(2026, 10, 31, 0, 0, 0, tzinfo=timezone.utc))
    assert (nxt.allowed, nxt.paid_with, nxt.day) == (True, "free", "2026-10-31")


def test_day_is_utc_date_of_now(conn):
    s = settings()
    d = device(conn)
    # 2026-10-31T00:30+02:00 is 2026-10-30T22:30Z
    oslo = datetime(2026, 10, 31, 0, 30, tzinfo=timezone(timedelta(hours=2)))
    assert admit(conn, s, d, "story", oslo).day == DAY
    with pytest.raises(ValueError):
        admit(conn, s, d, "story", datetime(2026, 10, 30, 12, 0))


def test_settle_returns_to_reserved_day(conn):
    s = settings()
    d = device(conn)
    adm = admit(conn, s, d, "story", datetime(2026, 10, 30, 23, 59, 59, tzinfo=timezone.utc))
    assert used(conn, d["id"]) == 1
    after = datetime(2026, 10, 31, 0, 0, 1, tzinfo=timezone.utc)
    done(conn, s, adm, kept=False, usage=Usage(input_tokens=4), now=after)
    assert used(conn, d["id"], day=DAY) == 0
    assert used(conn, d["id"], day="2026-10-31") == 0
    # usage lands on the reserved day too: 4*0.25 = 1 µUSD
    assert day_row(conn, d["id"], DAY)["tokens_in"] == 4
    assert conn.execute("SELECT cost_micro FROM server_days WHERE day=?", (DAY,)).fetchone()[0] == 1
    assert conn.execute("SELECT COUNT(*) FROM server_days WHERE day='2026-10-31'").fetchone()[0] == 0
    call = conn.execute("SELECT day, at FROM calls").fetchone()
    assert call["day"] == DAY and call["at"].startswith("2026-10-31T00:00:01")


def test_settle_is_idempotent(conn):
    s = settings(QUOTA_STORY_PER_DAY=1, CREDITS_PER_STORY=1)
    d = device(conn)
    ledger.grant(conn, d["wallet_id"], 1, "tester", NOW)
    free = admit(conn, s, d, "story", NOW)
    paid = admit(conn, s, d, "story", NOW)
    assert (free.paid_with, paid.paid_with) == ("free", "credits")
    for _ in range(2):
        done(conn, s, free, kept=False, usage=Usage(input_tokens=100))
        done(conn, s, paid, kept=False, usage=Usage(input_tokens=100))
    assert conn.execute("SELECT COUNT(*) FROM calls").fetchone()[0] == 2
    assert used(conn, d["id"]) == 0
    refunds = conn.execute("SELECT COUNT(*) FROM ledger WHERE reason='refund'").fetchone()[0]
    assert refunds == 1 and ledger.balance(conn, d["wallet_id"]) == 1
    # usage added once per call: 2 calls * 100 = 200 tokens, 200*0.25 = 50 µUSD
    row = day_row(conn, d["id"])
    assert (row["tokens_in"], row["cost_micro"]) == (200, 50)


def test_settle_rejects_refused_admission(conn):
    s = settings(QUOTA_STORY_PER_DAY=0)
    d = device(conn)
    refused = admit(conn, s, d, "story", NOW)
    assert not refused.allowed
    with pytest.raises(ValueError):
        done(conn, s, refused, kept=False)
    assert conn.execute("SELECT COUNT(*) FROM calls").fetchone()[0] == 0


SNAPSHOT = "gpt-5-mini-2025-08-07"  # a dated id OpenAI may report; not a key in the price table


def test_settle_unknown_model_still_returns_unit_and_refunds(conn, caplog):
    s = settings(QUOTA_STORY_PER_DAY=1, CREDITS_PER_STORY=1)
    d = device(conn)
    ledger.grant(conn, d["wallet_id"], 1, "tester", NOW)
    free = admit(conn, s, d, "story", NOW)
    paid = admit(conn, s, d, "story", NOW)
    assert (free.paid_with, paid.paid_with, ledger.balance(conn, d["wallet_id"])) == ("free", "credits", 0)
    with caplog.at_level("ERROR", logger="myguide.limits"):
        for adm in (free, paid):
            settle(conn, s, adm, kept=False, status=500, model=SNAPSHOT, usage=Usage(input_tokens=100),
                   latency_ms=1, now=NOW)
    assert not conn.in_transaction
    assert used(conn, d["id"]) == 0  # 1 reserved - 1 returned
    assert ledger.balance(conn, d["wallet_id"]) == 1  # 0 + 1 refunded
    rows = conn.execute("SELECT call_id, model, kept, cost_micro FROM calls ORDER BY id").fetchall()
    assert [tuple(r) for r in rows] == [(free.call_id, SNAPSHOT, 0, 0), (paid.call_id, SNAPSHOT, 0, 0)]
    errors = [r for r in caplog.records if r.levelname == "ERROR"]
    assert len(errors) == 2
    for rec, adm in zip(errors, (free, paid)):
        assert adm.call_id in rec.getMessage() and SNAPSHOT in rec.getMessage()


def test_settle_unknown_model_kept_adds_tokens_at_cost_zero(conn, caplog):
    s = settings()
    d = device(conn)
    adm = admit(conn, s, d, "story", NOW)
    with caplog.at_level("ERROR", logger="myguide.limits"):
        settle(conn, s, adm, kept=True, status=200, model=SNAPSHOT,
               usage=Usage(input_tokens=600, output_tokens=300), latency_ms=1, now=NOW)
    row = day_row(conn, d["id"])
    # unit kept: used 1; tokens 600 in / 300 out added; cost 0 (no price)
    assert (row["used_story"], row["tokens_in"], row["tokens_out"], row["cost_micro"]) == (1, 600, 300, 0)
    assert conn.execute("SELECT cost_micro FROM server_days WHERE day=?", (DAY,)).fetchone()[0] == 0
    assert tuple(conn.execute("SELECT kept, cost_micro FROM calls").fetchone()) == (1, 0)
    assert any(r.levelname == "ERROR" and adm.call_id in r.getMessage() for r in caplog.records)


def test_admit_reads_current_wallet(conn):
    s = settings(QUOTA_STORY_PER_DAY=0)
    a, b = device(conn, 1), device(conn, 2)
    ledger.grant(conn, b["wallet_id"], 1, "tester", NOW)
    conn.execute("UPDATE devices SET wallet_id=? WHERE id=?", (b["wallet_id"], a["id"]))
    adm = admit(conn, s, a, "story", NOW)  # the stale row still names a's old, empty wallet
    assert (adm.allowed, adm.wallet_id, adm.credits) == (True, b["wallet_id"], 0)


def test_allowance_never_below_zero(conn):
    s = settings(QUOTA_STORY_PER_DAY=2)
    d = device(conn)
    admit(conn, s, d, "story", NOW)
    admit(conn, s, d, "story", NOW)
    lowered = settings(QUOTA_STORY_PER_DAY=1)  # reload lowered the quota below today's use
    # max(1 - 2, 0) = 0; image 4 - 0 = 4
    assert allowance(conn, lowered, d["id"], d["wallet_id"], DAY) == ({"story": 0, "speech": 80, "image": 4}, 0)
    assert allowance(conn, lowered, d["id"], d["wallet_id"], "2026-11-01") == ({"story": 1, "speech": 80, "image": 4}, 0)


def test_unknown_kind_raises(conn):
    with pytest.raises(ValueError):
        admit(conn, settings(), device(conn), "video", NOW)
    assert not conn.in_transaction


def test_concurrent_paid_admits_one_wallet(db_path, conn):
    s = settings(QUOTA_STORY_PER_DAY=0, CREDITS_PER_STORY=1)
    a, b = device(conn, 1), device(conn, 2)
    conn.execute("UPDATE devices SET wallet_id=? WHERE id=?", (a["wallet_id"], b["id"]))
    ledger.grant(conn, a["wallet_id"], 1, "tester", NOW)
    rows = [conn.execute("SELECT * FROM devices WHERE id=?", (x["id"],)).fetchone() for x in (a, b)]
    barrier = threading.Barrier(2)
    results: list[Admission] = []
    errors: list[BaseException] = []

    def run(row):
        c = connect(db_path)
        try:
            barrier.wait()
            results.append(admit(c, s, row, "story", NOW))
        except BaseException as e:  # surfaced below
            errors.append(e)
        finally:
            c.close()

    threads = [threading.Thread(target=run, args=(r,)) for r in rows]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert errors == []
    assert sorted(r.allowed for r in results) == [False, True]
    assert ledger.balance(conn, a["wallet_id"]) == 0
    assert conn.execute("SELECT COUNT(*) FROM ledger WHERE reason='debit'").fetchone()[0] == 1


def test_rate_window():
    rw = RateWindow(lambda: 2, 60)
    # a hit counts while hit_time > now - 60; refused hits are recorded too
    # t=0  window (-60, 0]  holds 0           -> 1 <= 2 True
    # t=1  window (-59, 1]  holds 0, 1        -> 2 <= 2 True
    # t=2  window (-58, 2]  holds 0, 1, 2     -> 3 > 2  False
    # t=61 window (1, 61]   holds 2, 61       -> 2 <= 2 True
    # t=62 window (2, 62]   holds 61, 62      -> 2 <= 2 True
    # t=63 window (3, 63]   holds 61, 62, 63  -> 3 > 2  False
    assert [rw.hit("d", t) for t in (0, 1, 2, 61, 62, 63)] == [True, True, False, True, True, False]


def test_rate_window_keys_and_live_limit():
    limit = [1]
    rw = RateWindow(lambda: limit[0], 60)
    assert rw.hit("a", 0) is True
    assert rw.hit("b", 0) is True  # keys are independent
    assert rw.hit("a", 1) is False  # 2 hits in (-59, 1] > 1
    limit[0] = 5  # a reload raises the limit; the next hit sees it
    assert rw.hit("a", 2) is True  # 3 hits in (-58, 2] <= 5
    # long after: (1000-60, 1000] holds only this hit
    assert rw.hit("a", 1000) is True
