"""Log retention (spec 7): `calls` and `device_days` rows older than LOG_RETENTION_DAYS are deleted.

`ledger`, `devices`, `wallets` and `server_days` are never touched: the ledger is append-only money history.
"""
from __future__ import annotations

import logging
import sqlite3
from datetime import datetime, timedelta, timezone

from . import db
from .config import Settings
from .limits import utc_day

log = logging.getLogger(__name__)


def cutoff_day(settings: Settings, now: datetime) -> str:
    """The oldest UTC day kept: `now`'s UTC date minus LOG_RETENTION_DAYS days."""
    today = now.astimezone(timezone.utc).date()
    return (today - timedelta(days=settings.log_retention_days)).isoformat()


def prune(conn: sqlite3.Connection, settings: Settings, now: datetime) -> int:
    """Delete rows with `day` before the cutoff; returns how many rows went. Opens its own transaction, so
    the caller must not hold one."""
    if conn.in_transaction:
        raise RuntimeError("prune must not run inside another transaction")
    cutoff = cutoff_day(settings, now)
    conn.execute("BEGIN IMMEDIATE")
    try:
        n = conn.execute("DELETE FROM calls WHERE day < ?", (cutoff,)).rowcount
        n += conn.execute("DELETE FROM device_days WHERE day < ?", (cutoff,)).rowcount
        conn.execute("COMMIT")
    except BaseException:
        conn.execute("ROLLBACK")
        raise
    return n


def prune_if_new_day(state) -> None:
    """Prune at most once per UTC day (and once at start). Never raises: a failed prune is logged and the
    day is not retried until tomorrow, so a broken database does not slow every request."""
    now = state.clock()
    day = utc_day(now)
    if state.last_pruned_day == day:
        return
    state.last_pruned_day = day
    try:
        conn = db.connect(state.db_path)
        try:
            n = prune(conn, state.settings, now)
        finally:
            conn.close()
    except (sqlite3.Error, OSError) as e:
        log.error("log pruning failed: %s", type(e).__name__)
        return
    if n:
        log.info("log pruning removed %d rows", n)
