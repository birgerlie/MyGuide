"""SQLite storage: schema, connection, devices (spec 6.1, 6.2).

Timestamps are ISO 8601 UTC strings. Money is integer micro-USD.
No request or response body, prompt, position, photo, story or IP is stored.
"""
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

REASONS = ("grant", "debit", "refund", "purchase", "revoke")

_REASON_LIST = ",".join(f"'{r}'" for r in REASONS)

SCHEMA = f"""
CREATE TABLE IF NOT EXISTS wallets (
    id INTEGER PRIMARY KEY
);
CREATE TABLE IF NOT EXISTS devices (
    id INTEGER PRIMARY KEY,
    key_id TEXT NOT NULL UNIQUE,
    token_hash TEXT NOT NULL UNIQUE,
    wallet_id INTEGER NOT NULL REFERENCES wallets(id),
    blocked INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS ledger (
    id INTEGER PRIMARY KEY,
    wallet_id INTEGER NOT NULL REFERENCES wallets(id),
    delta INTEGER NOT NULL,
    reason TEXT NOT NULL CHECK (reason IN ({_REASON_LIST})),
    reference TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE (reason, reference)
);
CREATE INDEX IF NOT EXISTS ledger_wallet ON ledger(wallet_id);
CREATE TRIGGER IF NOT EXISTS ledger_no_update BEFORE UPDATE ON ledger
BEGIN SELECT RAISE(ABORT, 'ledger is append-only'); END;
CREATE TRIGGER IF NOT EXISTS ledger_no_replace BEFORE INSERT ON ledger
WHEN EXISTS (SELECT 1 FROM ledger WHERE reason = NEW.reason AND reference = NEW.reference)
BEGIN SELECT RAISE(ABORT, 'ledger is append-only'); END;
CREATE TRIGGER IF NOT EXISTS ledger_no_delete BEFORE DELETE ON ledger
BEGIN SELECT RAISE(ABORT, 'ledger is append-only'); END;
CREATE TABLE IF NOT EXISTS device_days (
    device_id INTEGER NOT NULL REFERENCES devices(id),
    day TEXT NOT NULL,
    used_story INTEGER NOT NULL DEFAULT 0,
    used_speech INTEGER NOT NULL DEFAULT 0,
    used_image INTEGER NOT NULL DEFAULT 0,
    requests INTEGER NOT NULL DEFAULT 0,
    refused INTEGER NOT NULL DEFAULT 0,
    tokens_in INTEGER NOT NULL DEFAULT 0,
    tokens_out INTEGER NOT NULL DEFAULT 0,
    tokens_cached INTEGER NOT NULL DEFAULT 0,
    speech_chars INTEGER NOT NULL DEFAULT 0,
    cost_micro INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (device_id, day)
);
CREATE TABLE IF NOT EXISTS server_days (
    day TEXT PRIMARY KEY,
    cost_micro INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS calls (
    id INTEGER PRIMARY KEY,
    call_id TEXT NOT NULL UNIQUE,
    at TEXT NOT NULL,
    day TEXT NOT NULL,
    device_id INTEGER NOT NULL REFERENCES devices(id),
    kind TEXT NOT NULL,
    model TEXT,
    status INTEGER,
    latency_ms INTEGER,
    tokens_in INTEGER NOT NULL DEFAULT 0,
    tokens_out INTEGER NOT NULL DEFAULT 0,
    tokens_cached INTEGER NOT NULL DEFAULT 0,
    speech_chars INTEGER NOT NULL DEFAULT 0,
    cost_micro INTEGER NOT NULL DEFAULT 0,
    kept INTEGER NOT NULL DEFAULT 1,
    paid_with TEXT
);
"""


def connect(path: str | Path) -> sqlite3.Connection:
    conn = sqlite3.connect(str(path), isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA recursive_triggers=ON")
    conn.executescript(SCHEMA)
    return conn


def iso(now: datetime) -> str:
    if now.tzinfo is None or now.utcoffset() is None:
        raise ValueError("now must be a timezone-aware datetime")
    return now.astimezone(timezone.utc).isoformat()


def create_device(conn: sqlite3.Connection, key_id: str, token_hash: str, now: datetime) -> int:
    """New wallet and device in one transaction; returns the device id."""
    created = iso(now)
    conn.execute("BEGIN IMMEDIATE")
    try:
        wallet_id = conn.execute("INSERT INTO wallets DEFAULT VALUES").lastrowid
        device_id = conn.execute(
            "INSERT INTO devices (key_id, token_hash, wallet_id, created_at) VALUES (?,?,?,?)",
            (key_id, token_hash, wallet_id, created),
        ).lastrowid
        conn.execute("COMMIT")
    except BaseException:
        conn.execute("ROLLBACK")
        raise
    return device_id


def rekey_device(conn: sqlite3.Connection, device_id: int, key_id: str, token_hash: str) -> None:
    cur = conn.execute(
        "UPDATE devices SET key_id=?, token_hash=? WHERE id=?", (key_id, token_hash, device_id)
    )
    if cur.rowcount != 1:
        raise LookupError(f"no device {device_id}")


def device_by_token_hash(conn: sqlite3.Connection, token_hash: str) -> sqlite3.Row | None:
    return conn.execute("SELECT * FROM devices WHERE token_hash=?", (token_hash,)).fetchone()


def set_blocked(conn: sqlite3.Connection, device_id: int, blocked: bool) -> None:
    cur = conn.execute("UPDATE devices SET blocked=? WHERE id=?", (1 if blocked else 0, device_id))
    if cur.rowcount != 1:
        raise LookupError(f"no device {device_id}")
