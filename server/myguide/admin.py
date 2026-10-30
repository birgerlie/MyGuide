"""`myguide-admin`: the owner's view of usage and the levers (spec 6.1, 6.2, 7). Run on the server as root.

Prints plain aligned text. Never prints a key id, token hash or token; none of them is needed for any view.
"""
from __future__ import annotations

import argparse
import sqlite3
import subprocess
import sys
from collections.abc import Callable, Sequence
from datetime import datetime, timedelta, timezone
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path
from typing import TextIO

from . import db, ledger
from .config import ConfigError, load_settings
from .limits import utc_day

USAGE = """usage: myguide-admin COMMAND
  today                          the day's calls, tokens, cost and devices
  days N                         the same for each of the last N days
  devices [N]                    one line per device, highest cost first (today, or the last N days)
  device ID                      one device per day and per kind
  block ID | unblock ID          refuse / allow a device
  limits                         the limits from the env file
  reload                         make the service read the env file again
  grant ID CREDITS NOTE...       add credits to the device's wallet
  balance ID                     the device's credit balance
  ledger ID                      the device's credit entries
"""


_SQLITE_MAX = 2**63 - 1  # larger integers do not fit a SQLite INTEGER


class _Usage(Exception):
    pass


class _Failure(Exception):
    pass


def usd(micro: int) -> str:
    """Integer µUSD as USD with 4 decimals, rounded half up."""
    return str((Decimal(micro) / 1_000_000).quantize(Decimal("0.0001"), rounding=ROUND_HALF_UP))


def table(out: TextIO, header: Sequence[str], rows: Sequence[Sequence[object]]) -> None:
    """Aligned columns: the first column left, the rest right."""
    cells = [list(header)] + [[str(c) for c in r] for r in rows]
    widths = [max(len(r[i]) for r in cells) for i in range(len(header))]
    for r in cells:
        out.write("  ".join(c.ljust(w) if i == 0 else c.rjust(w) for i, (c, w) in enumerate(zip(r, widths))).rstrip() + "\n")


def _int(text: str, minimum: int = 1) -> int:
    try:
        n = int(text)
    except ValueError:
        raise _Usage from None
    if n < minimum or n > _SQLITE_MAX:
        raise _Usage
    return n


def _device(conn: sqlite3.Connection, text: str) -> sqlite3.Row:
    row = conn.execute("SELECT * FROM devices WHERE id=?", (_int(text),)).fetchone()
    if row is None:
        raise _Failure(f"no device {text}")
    return row


def _first_day(now: datetime, days: int) -> str:
    return (now.astimezone(timezone.utc).date() - timedelta(days=days - 1)).isoformat()


_SUMS = ("COALESCE(SUM(requests),0) r, COALESCE(SUM(refused),0) f, COALESCE(SUM(tokens_in),0) ti, "
         "COALESCE(SUM(tokens_out),0) tout, COALESCE(SUM(tokens_cached),0) tc, "
         "COALESCE(SUM(speech_chars),0) sc, COALESCE(SUM(cost_micro),0) c")


def _per_day(conn: sqlite3.Connection, out: TextIO, since: str) -> None:
    rows = conn.execute(
        f"SELECT day, COUNT(DISTINCT device_id) d, {_SUMS} FROM device_days WHERE day >= ? "
        "GROUP BY day ORDER BY day DESC", (since,)).fetchall()
    table(out, ["day", "devices", "requests", "refused", "tokens in", "tokens out", "tokens cached",
                "speech chars", "cost USD"],
          [(r["day"], r["d"], r["r"], r["f"], r["ti"], r["tout"], r["tc"], r["sc"], usd(r["c"])) for r in rows])


def _devices(conn: sqlite3.Connection, out: TextIO, since: str) -> None:
    rows = conn.execute(
        f"SELECT d.id, COALESCE(a.r,0) r, COALESCE(a.f,0) f, COALESCE(a.ti,0) ti, COALESCE(a.tout,0) tout, "
        "COALESCE(a.tc,0) tc, COALESCE(a.sc,0) sc, COALESCE(a.c,0) c, d.blocked, "
        "(SELECT COALESCE(SUM(delta),0) FROM ledger WHERE wallet_id=d.wallet_id) bal "
        f"FROM devices d LEFT JOIN (SELECT device_id, {_SUMS} FROM device_days WHERE day >= ? GROUP BY device_id) a "
        "ON a.device_id = d.id ORDER BY c DESC, d.id", (since,)).fetchall()
    table(out, ["device", "requests", "refused", "tokens in", "tokens out", "tokens cached", "speech chars",
                "cost USD", "balance"],
          [(f"{r['id']}{' (blocked)' if r['blocked'] else ''}", r["r"], r["f"], r["ti"], r["tout"], r["tc"],
            r["sc"], usd(r["c"]), r["bal"]) for r in rows])


def _device_view(conn: sqlite3.Connection, out: TextIO, device: sqlite3.Row) -> None:
    out.write(f"device {device['id']}{' (blocked)' if device['blocked'] else ''}  created {device['created_at']}\n\n")
    rows = conn.execute(
        "SELECT day, requests, refused, tokens_in, tokens_out, tokens_cached, speech_chars, cost_micro "
        "FROM device_days WHERE device_id=? ORDER BY day DESC", (device["id"],)).fetchall()
    table(out, ["day", "requests", "refused", "tokens in", "tokens out", "tokens cached", "speech chars", "cost USD"],
          [(r["day"], r["requests"], r["refused"], r["tokens_in"], r["tokens_out"], r["tokens_cached"],
            r["speech_chars"], usd(r["cost_micro"])) for r in rows])
    out.write("\n")
    rows = conn.execute(
        "SELECT kind, COUNT(*) n, COALESCE(SUM(kept),0) kept, COALESCE(SUM(tokens_in),0) ti, "
        "COALESCE(SUM(tokens_out),0) tout, COALESCE(SUM(tokens_cached),0) tc, COALESCE(SUM(speech_chars),0) sc, "
        "COALESCE(SUM(cost_micro),0) c FROM calls WHERE device_id=? GROUP BY kind ORDER BY kind",
        (device["id"],)).fetchall()
    table(out, ["kind", "calls", "kept", "tokens in", "tokens out", "tokens cached", "speech chars", "cost USD"],
          [(r["kind"], r["n"], r["kept"], r["ti"], r["tout"], r["tc"], r["sc"], usd(r["c"])) for r in rows])
    out.write(f"\nbalance {ledger.balance(conn, device['wallet_id'])}\n")


def _run(argv: list[str], *, env_path: Path, db_path: Path, out: TextIO, now: datetime,
         signal_service: Callable[[], None]) -> None:
    if not argv:
        raise _Usage
    cmd, args = argv[0], argv[1:]
    arity = {"today": (0, 0), "days": (1, 1), "devices": (0, 1), "device": (1, 1), "block": (1, 1),
             "unblock": (1, 1), "limits": (0, 0), "reload": (0, 0), "grant": (3, None), "balance": (1, 1),
             "ledger": (1, 1)}.get(cmd)
    if arity is None or len(args) < arity[0] or (arity[1] is not None and len(args) > arity[1]):
        raise _Usage
    credits = note = None
    if cmd == "grant":
        credits = _int(args[1])
        note = " ".join(args[2:]).strip()
        if not note:
            raise _Usage
    n = _int(args[0]) if cmd in ("days", "devices") and args else None

    try:
        settings = load_settings(env_path)
    except ConfigError as e:
        raise _Failure(str(e)) from None
    if cmd == "limits":
        table(out, ["setting", "value"], settings.redacted())
        return
    if cmd == "reload":
        signal_service()
        out.write("reload signalled\n")
        return

    if not db_path.is_file():  # never create a database (and root-owned files beside it) from the admin
        raise _Failure(f"database not found: {db_path}")
    conn = db.connect(db_path)
    try:
        if cmd == "today":
            _per_day(conn, out, utc_day(now))
        elif cmd == "days":
            _per_day(conn, out, _first_day(now, n))
        elif cmd == "devices":
            _devices(conn, out, _first_day(now, n or 1))
        elif cmd == "device":
            _device_view(conn, out, _device(conn, args[0]))
        elif cmd in ("block", "unblock"):
            device = _device(conn, args[0])
            db.set_blocked(conn, device["id"], cmd == "block")
            out.write(f"device {device['id']} {cmd}ed\n")
        elif cmd == "grant":
            device = _device(conn, args[0])
            if not ledger.grant(conn, device["wallet_id"], credits, note, now):
                raise _Failure("an identical grant was just made; try again")
            out.write(f"granted {credits} to device {device['id']}; balance "
                      f"{ledger.balance(conn, device['wallet_id'])}\n")
        elif cmd == "balance":
            device = _device(conn, args[0])
            out.write(f"{ledger.balance(conn, device['wallet_id'])}\n")
        elif cmd == "ledger":
            device = _device(conn, args[0])
            table(out, ["id", "at", "delta", "reason", "reference"],
                  [(e["id"], e["created_at"], e["delta"], e["reason"], e["reference"])
                   for e in ledger.entries(conn, device["wallet_id"])])
    finally:
        conn.close()


def main(argv: list[str], *, env_path: Path, db_path: Path, out: TextIO, now: datetime,
         signal_service: Callable[[], None]) -> int:
    """0 on success, 2 for an unknown command or bad arguments (usage on `out`), 1 for a failure."""
    try:
        _run(argv, env_path=env_path, db_path=db_path, out=out, now=now, signal_service=signal_service)
    except _Usage:
        out.write(USAGE)
        return 2
    except _Failure as e:
        out.write(f"error: {e}\n")
        return 1
    except (sqlite3.Error, subprocess.CalledProcessError, OSError) as e:
        out.write(f"error: {type(e).__name__}: {e}\n")
        return 1
    return 0


def _signal_service() -> None:
    subprocess.run(["systemctl", "kill", "-s", "HUP", "myguide"], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(prog="myguide-admin", add_help=False)
    parser.add_argument("--env", required=True, type=Path)
    parser.add_argument("--db", required=True, type=Path)
    ns, rest = parser.parse_known_args()
    sys.exit(main(rest, env_path=ns.env, db_path=ns.db, out=sys.stdout, now=datetime.now(timezone.utc),
                  signal_service=_signal_service))
