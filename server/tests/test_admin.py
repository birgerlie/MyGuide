"""myguide-admin and log retention (spec 6.2, 7)."""
from __future__ import annotations

import hashlib
import io
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx
import pytest
from starlette.testclient import TestClient

from myguide import admin, db, ledger, retention
from myguide.app import create_app
from myguide.config import parse_settings
from myguide.state import State, upstream_client
from tests.attest_fixtures import NOW
from tests.conftest import env_dict, write_env

TOKEN = "tok-admin-1"
DAY = "2026-10-30"  # UTC date of NOW


def sha(t: str) -> str:
    return hashlib.sha256(t.encode()).hexdigest()


class Admin:
    def __init__(self, tmp_path: Path) -> None:
        self.env = write_env(tmp_path / "env")
        self.db = tmp_path / "guide.db"
        self.signals = 0
        self.conn = db.connect(self.db)

    def signal(self) -> None:
        self.signals += 1

    def run(self, *argv: str, now: datetime = NOW) -> tuple[int, str]:
        out = io.StringIO()
        code = admin.main(list(argv), env_path=self.env, db_path=self.db, out=out, now=now,
                          signal_service=self.signal)
        return code, out.getvalue()

    def device(self, key: str = "k1", token: str = TOKEN) -> int:
        return db.create_device(self.conn, key, sha(token), NOW)

    def day_row(self, device_id: int, day: str, cost: int, requests: int = 1) -> None:
        self.conn.execute(
            "INSERT INTO device_days (device_id, day, requests, tokens_in, tokens_out, cost_micro) "
            "VALUES (?,?,?,?,?,?)", (device_id, day, requests, 10, 5, cost))

    def call_row(self, device_id: int, day: str, call_id: str, kind: str = "story", cost: int = 0,
                 kept: int = 1) -> None:
        self.conn.execute(
            "INSERT INTO calls (call_id, at, day, device_id, kind, cost_micro, kept) VALUES (?,?,?,?,?,?,?)",
            (call_id, day + "T10:00:00+00:00", day, device_id, kind, cost, kept))


@pytest.fixture
def adm(tmp_path) -> Admin:
    return Admin(tmp_path)


def settings(**o):
    return parse_settings(env_dict(**o))


# --- retention ---------------------------------------------------------------------------------------------

def test_prune_keeps_exactly_the_retention_window(adm):
    # Retention 90 at 2026-10-30: cutoff = 2026-10-30 - 90 days. October has 30 days back to 09-30 (30),
    # September 30 days back to 08-31 (60), then 30 more days back to 08-01 (90). So the cutoff is 2026-08-01.
    # 2026-07-31 is 91 days old: deleted. 2026-08-01 is 90 days old: kept.
    d = adm.device()
    for day in ("2026-07-31", "2026-08-01"):
        adm.day_row(d, day, 1)
        adm.call_row(d, day, f"c-{day}")
    ledger.grant(adm.conn, 1, 3, "x", NOW)
    assert retention.cutoff_day(settings(LOG_RETENTION_DAYS="90"), NOW) == "2026-08-01"
    n = retention.prune(adm.conn, settings(LOG_RETENTION_DAYS="90"), NOW)
    assert n == 2  # one calls row + one device_days row
    assert [r[0] for r in adm.conn.execute("SELECT day FROM calls")] == ["2026-08-01"]
    assert [r[0] for r in adm.conn.execute("SELECT day FROM device_days")] == ["2026-08-01"]
    assert ledger.balance(adm.conn, 1) == 3
    assert adm.conn.execute("SELECT COUNT(*) FROM devices").fetchone()[0] == 1
    assert adm.conn.execute("SELECT COUNT(*) FROM wallets").fetchone()[0] == 1


def test_prune_uses_the_utc_day_of_now(adm):
    # 2026-10-31T01:00+02:00 is 2026-10-30T23:00Z; retention 1 -> cutoff 2026-10-29.
    d = adm.device()
    adm.day_row(d, "2026-10-28", 1)
    adm.day_row(d, "2026-10-29", 1)
    local = datetime(2026, 10, 31, 1, 0, tzinfo=timezone(timedelta(hours=2)))
    assert retention.prune(adm.conn, settings(LOG_RETENTION_DAYS="1"), local) == 1


def test_prune_refuses_to_run_inside_a_transaction(adm):
    adm.conn.execute("BEGIN IMMEDIATE")
    try:
        with pytest.raises(RuntimeError):
            retention.prune(adm.conn, settings(), NOW)
    finally:
        adm.conn.execute("ROLLBACK")


def _service(tmp_path, test_root, clock):
    st = State(settings(), tmp_path / "guide.db", root=test_root, clock=lambda: clock[0])
    conn = db.connect(st.db_path)
    d = db.create_device(conn, "k", sha("t"), NOW)
    return st, conn, d


def test_prune_at_start_and_once_per_utc_day_on_a_request(tmp_path, test_root):
    clock = [NOW]
    st, conn, d = _service(tmp_path, test_root, clock)
    conn.execute("INSERT INTO device_days (device_id, day) VALUES (?, '2026-01-01')", (d,))
    with TestClient(create_app(st), client=("127.0.0.1", 50000)) as c:
        # pruned at start
        assert conn.execute("SELECT COUNT(*) FROM device_days").fetchone()[0] == 0
        # same day: an old row added later survives a request
        conn.execute("INSERT INTO device_days (device_id, day) VALUES (?, '2026-01-01')", (d,))
        assert c.post("/v1/responses", json={}).status_code == 401
        assert conn.execute("SELECT COUNT(*) FROM device_days").fetchone()[0] == 1
        # next UTC day: the first request prunes
        clock[0] = NOW + timedelta(days=1)
        assert c.post("/v1/responses", json={}).status_code == 401
        assert conn.execute("SELECT COUNT(*) FROM device_days").fetchone()[0] == 0
    assert st.last_pruned_day == "2026-10-31"


def test_a_failing_prune_does_not_break_the_request(tmp_path, test_root, monkeypatch):
    clock = [NOW]
    st, _, _ = _service(tmp_path, test_root, clock)
    import sqlite3

    def boom(*a, **k):
        raise sqlite3.OperationalError("disk I/O error")
    monkeypatch.setattr(retention, "prune", boom)
    with TestClient(create_app(st), client=("127.0.0.1", 50000)) as c:
        assert c.post("/v1/responses", json={}).status_code == 401


# --- admin -------------------------------------------------------------------------------------------------

def test_grant_adds_balance_and_one_ledger_line(adm):
    adm.device()
    code, out = adm.run("grant", "1", "3", "heidi", "test")
    assert code == 0, out
    assert adm.run("balance", "1") == (0, "3\n")
    code, out = adm.run("ledger", "1")
    assert code == 0
    lines = [l for l in out.splitlines() if "grant" in l]
    assert len(lines) == 1 and " 3 " in lines[0] and "heidi test" in lines[0]


@pytest.mark.parametrize("args", [("grant", "1", "0", "x"), ("grant", "1", "-2", "x"), ("grant", "1", "abc", "x"),
                                  ("grant", "1", "3"), ("grant", "1", "3", "  "), ("grant", "1"),
                                  ("frobnicate",), (), ("days",), ("days", "0"), ("devices", "x"),
                                  ("block",), ("today", "extra"), ("device", "one")])
def test_bad_arguments_print_usage_and_exit_2(adm, args):
    adm.device()
    code, out = adm.run(*args)
    assert code == 2
    assert out.startswith("usage: myguide-admin")
    assert adm.run("balance", "1") == (0, "0\n")  # nothing granted


@pytest.mark.parametrize("args", [("grant", "9", "3", "x"), ("balance", "9"), ("ledger", "9"), ("block", "9"),
                                  ("unblock", "9"), ("device", "9")])
def test_unknown_device_exits_1_with_a_message(adm, args):
    code, out = adm.run(*args)
    assert code == 1 and "no device 9" in out


def test_block_makes_the_proxy_answer_403_and_unblock_undoes_it(adm, test_root):
    adm.device()
    seen = []

    def upstream(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={"id": "r", "usage": {"input_tokens": 10, "output_tokens": 5}})

    st = State(settings(), adm.db, root=test_root, clock=lambda: NOW,
               upstream=upstream_client(httpx.MockTransport(upstream)))
    with TestClient(create_app(st), client=("127.0.0.1", 50000)) as c:
        h = {"Authorization": f"Bearer {TOKEN}"}
        body = {"model": "gpt-5-mini", "input": "x"}
        assert adm.run("block", "1") == (0, "device 1 blocked\n")
        r = c.post("/v1/responses", headers=h, json=body)
        assert r.status_code == 403 and r.json()["error"]["code"] == "blocked"
        assert seen == []
        assert adm.run("unblock", "1") == (0, "device 1 unblocked\n")
        r = c.post("/v1/responses", headers=h, json=body)
        assert r.status_code == 200 and len(seen) == 1
        assert "story=" in r.headers["X-MyGuide-Free-Left"] and r.headers["X-MyGuide-Credits"] == "0"


def test_missing_database_exits_1_and_is_not_created(adm, tmp_path):
    adm.db = tmp_path / "nowhere" / "absent.db"
    for args in (("today",), ("balance", "1"), ("grant", "1", "3", "x")):
        code, out = adm.run(*args)
        assert code == 1 and str(adm.db) in out
    assert not adm.db.exists() and not adm.db.parent.exists()


@pytest.mark.parametrize("args", [("grant", "1", "99999999999999999999", "x"), ("balance", "99999999999999999999"),
                                  ("block", "9223372036854775808")])
def test_numbers_beyond_sqlite_integer_exit_2(adm, args):
    adm.device()
    code, out = adm.run(*args)
    assert code == 2 and out.startswith("usage:")
    assert adm.run("balance", "1") == (0, "0\n")


def test_largest_sqlite_integer_is_accepted_as_an_id(adm):
    code, out = adm.run("balance", str(2**63 - 1))
    assert code == 1 and "no device" in out


def test_wrapper_script_is_valid_shell_and_reload_stays_root():
    script = Path(__file__).parent.parent / "bin" / "myguide-admin"
    assert subprocess.run(["bash", "-n", str(script)]).returncode == 0
    text = script.read_text()
    assert "runuser -u myguide --" in text and "reload" in text
    lines = [l for l in text.splitlines() if "myguide.admin" in l]
    assert len(lines) == 2
    assert "runuser" not in next(l for l in lines if "runuser" not in l)  # the root branch (reload)


def test_devices_orders_by_cost_and_shows_balance(adm):
    a, b, c = adm.device("ka", "ta"), adm.device("kb", "tb"), adm.device("kc", "tc")
    adm.day_row(a, DAY, 1205)
    adm.day_row(b, DAY, 30000)
    adm.day_row(c, "2026-10-29", 99999)  # yesterday: not in "today"
    ledger.grant(adm.conn, 2, 7, "x", NOW)
    code, out = adm.run("devices")
    assert code == 0
    lines = out.splitlines()
    assert "balance" in lines[0] and "cost USD" in lines[0]
    # 30000 µUSD = 0.0300 USD; 1205 µUSD = 0.001205 -> 0.0012; device 3 has no cost today.
    assert [l.split()[0] for l in lines[1:]] == ["2", "1", "3"]
    assert lines[1].split()[-2:] == ["0.0300", "7"]
    assert lines[2].split()[-2:] == ["0.0012", "0"]
    # last 2 days: device 3 (99999 µUSD = 0.099999 -> 0.1000) comes first
    code, out = adm.run("devices", "2")
    assert [l.split()[0] for l in out.splitlines()[1:]] == ["3", "2", "1"]
    assert out.splitlines()[1].split()[-2:] == ["0.1000", "0"]


def test_today_prints_the_days_cost_in_usd(adm):
    a, b = adm.device("ka", "ta"), adm.device("kb", "tb")
    adm.day_row(a, DAY, 1205)
    code, out = adm.run("today")
    # 1205 µUSD / 1e6 = 0.001205 -> half-up at 4 places = 0.0012
    assert code == 0 and DAY in out and "0.0012" in out
    adm.day_row(b, DAY, 1205)
    # 2410 µUSD = 0.00241 -> 0.0024, two devices
    row = adm.run("today")[1].splitlines()[1].split()
    assert row[0] == DAY and row[1] == "2" and row[-1] == "0.0024"


@pytest.mark.parametrize("micro,text", [(0, "0.0000"), (1205, "0.0012"), (50, "0.0001"), (49, "0.0000"),
                                        (1_000_000, "1.0000"), (12_345_678, "12.3457")])
def test_usd_rounds_half_up(micro, text):
    # 50 µUSD = 0.00005 -> half-up 0.0001; 49 -> 0.000049 -> 0.0000; 12.345678 -> 12.3457
    assert admin.usd(micro) == text


def test_days_covers_the_last_n_days_newest_first(adm):
    d = adm.device()
    for day in ("2026-10-27", "2026-10-28", "2026-10-29", DAY):
        adm.day_row(d, day, 1000)
    # days 3 at 10-30: 10-30, 10-29, 10-28 (not 10-27)
    out = adm.run("days", "3")[1].splitlines()
    assert [l.split()[0] for l in out[1:]] == [DAY, "2026-10-29", "2026-10-28"]


def test_device_view_shows_days_kinds_and_balance(adm):
    d = adm.device()
    adm.day_row(d, DAY, 1205)
    adm.call_row(d, DAY, "a", "story", 1205, 1)
    adm.call_row(d, DAY, "b", "story", 0, 0)
    adm.call_row(d, DAY, "c", "speech", 0, 1)
    ledger.grant(adm.conn, 1, 2, "x", NOW)
    code, out = adm.run("device", "1")
    assert code == 0
    story = [l.split() for l in out.splitlines() if l.startswith("story")][0]
    assert story[:3] == ["story", "2", "1"]  # two calls, one kept
    assert any(l.startswith("speech") for l in out.splitlines())
    assert DAY in out and "balance 2" in out


def test_limits_shows_settings_and_hides_the_key(adm):
    code, out = adm.run("limits")
    assert code == 0
    assert "QUOTA_STORY_PER_DAY" in out and "<set>" in out
    assert "sk-test" not in out


def test_reload_signals_the_service_once(adm):
    assert adm.run("reload")[0] == 0
    assert adm.signals == 1


def test_a_bad_env_file_exits_1_naming_the_setting(adm):
    adm.env.write_text("QUOTA_STORY_PER_DAY=abc\n")
    code, out = adm.run("today")
    assert code == 1 and "QUOTA_STORY_PER_DAY" in out and adm.signals == 0


def test_no_key_id_or_token_hash_is_printed(adm):
    adm.device("secret-key-id", "secret-token")
    adm.day_row(1, DAY, 1)
    out = "".join(adm.run(*a)[1] for a in (("devices",), ("device", "1"), ("ledger", "1"), ("today",)))
    assert "secret-key-id" not in out and sha("secret-token") not in out
