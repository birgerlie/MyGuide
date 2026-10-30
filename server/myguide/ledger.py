"""Append-only credit ledger (spec 6.2). A wallet's balance is the sum of its entries."""
import sqlite3
from datetime import datetime

from .db import REASONS, iso


def balance(conn: sqlite3.Connection, wallet_id: int) -> int:
    return conn.execute(
        "SELECT COALESCE(SUM(delta), 0) FROM ledger WHERE wallet_id=?", (wallet_id,)
    ).fetchone()[0]


def entries(conn: sqlite3.Connection, wallet_id: int) -> list[sqlite3.Row]:
    return conn.execute("SELECT * FROM ledger WHERE wallet_id=? ORDER BY id", (wallet_id,)).fetchall()


def add_entry(conn: sqlite3.Connection, wallet_id: int, delta: int, reason: str,
              reference: str, now: datetime) -> bool:
    """False when (reason, reference) already exists; never raises for that."""
    if reason not in REASONS:
        raise ValueError(f"unknown ledger reason {reason!r}")
    cur = conn.execute(
        "INSERT INTO ledger (wallet_id, delta, reason, reference, created_at) VALUES (?,?,?,?,?) "
        "ON CONFLICT(reason, reference) DO NOTHING",
        (wallet_id, delta, reason, reference, iso(now)),
    )
    return cur.rowcount == 1


def grant(conn: sqlite3.Connection, wallet_id: int, credits: int, note: str, now: datetime) -> bool:
    if credits <= 0:
        raise ValueError("credits must be > 0")
    return add_entry(conn, wallet_id, credits, "grant", f"grant:{iso(now)}:{note}", now)


def try_debit(conn: sqlite3.Connection, wallet_id: int, credits: int, reference: str,
              now: datetime) -> bool:
    """Must run inside the caller's BEGIN IMMEDIATE; opens and commits nothing itself."""
    if credits <= 0:
        raise ValueError("credits must be > 0")
    if not conn.in_transaction:
        raise RuntimeError("try_debit must be called inside BEGIN IMMEDIATE")
    if balance(conn, wallet_id) < credits:
        return False
    return add_entry(conn, wallet_id, -credits, "debit", reference, now)


def refund(conn: sqlite3.Connection, wallet_id: int, credits: int, reference: str,
           now: datetime) -> bool:
    """+credits, only if this wallet has a debit with that reference and no refund yet."""
    if credits <= 0:
        raise ValueError("credits must be > 0")
    own = not conn.in_transaction
    if own:
        conn.execute("BEGIN IMMEDIATE")
    try:
        debit = conn.execute(
            "SELECT 1 FROM ledger WHERE reason='debit' AND reference=? AND wallet_id=?",
            (reference, wallet_id),
        ).fetchone()
        done = bool(debit) and add_entry(conn, wallet_id, credits, "refund", reference, now)
        if own:
            conn.execute("COMMIT")
        return done
    except BaseException:
        if own:
            conn.execute("ROLLBACK")
        raise
