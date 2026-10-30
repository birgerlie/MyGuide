import sqlite3
import threading
from datetime import datetime, timezone

import pytest

from myguide import ledger
from myguide.db import connect, create_device, rekey_device, device_by_token_hash

NOW = datetime(2026, 10, 30, 12, 0, tzinfo=timezone.utc)


@pytest.fixture
def conn(tmp_path):
    c = connect(tmp_path / "g.db")
    yield c
    c.close()


def wallet(conn, n=1):
    did = create_device(conn, f"key{n}", f"tok{n}", NOW)
    return conn.execute("SELECT wallet_id FROM devices WHERE id=?", (did,)).fetchone()[0]


def test_new_device_has_empty_wallet(conn):
    assert ledger.balance(conn, wallet(conn)) == 0


def test_connect_is_idempotent(tmp_path):
    connect(tmp_path / "g.db").close()
    c = connect(tmp_path / "g.db")
    assert c.execute("PRAGMA foreign_keys").fetchone()[0] == 1
    assert c.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
    c.close()


def test_grant_then_balance(conn):
    w = wallet(conn)
    assert ledger.grant(conn, w, 3, "tester", NOW) is True
    assert ledger.balance(conn, w) == 3
    rows = ledger.entries(conn, w)
    assert len(rows) == 1 and rows[0]["reason"] == "grant" and rows[0]["delta"] == 3


def test_reference_counted_once(conn):
    w = wallet(conn)
    assert ledger.add_entry(conn, w, 5, "purchase", "tx1", NOW) is True
    assert ledger.add_entry(conn, w, 5, "purchase", "tx1", NOW) is False
    assert ledger.balance(conn, w) == 5


def test_same_reference_other_reason_allowed(conn):
    w = wallet(conn)
    assert ledger.add_entry(conn, w, 5, "purchase", "x", NOW)
    assert ledger.add_entry(conn, w, 1, "grant", "x", NOW)
    assert ledger.balance(conn, w) == 6


def test_unknown_reason_rejected(conn):
    w = wallet(conn)
    with pytest.raises(ValueError):
        ledger.add_entry(conn, w, 1, "gift", "r", NOW)


def test_debit_and_refund_same_reference(conn):
    w = wallet(conn)
    ledger.grant(conn, w, 3, "n", NOW)
    conn.execute("BEGIN IMMEDIATE")
    assert ledger.try_debit(conn, w, 1, "c1", NOW) is True
    conn.execute("COMMIT")
    assert ledger.balance(conn, w) == 2
    assert ledger.refund(conn, w, 1, "c1", NOW) is True
    assert ledger.balance(conn, w) == 3
    assert ledger.refund(conn, w, 1, "c1", NOW) is False
    assert ledger.balance(conn, w) == 3
    assert [r["reason"] for r in ledger.entries(conn, w)] == ["grant", "debit", "refund"]


def test_refund_without_debit_refused(conn):
    w = wallet(conn)
    assert ledger.refund(conn, w, 1, "c9", NOW) is False
    assert ledger.balance(conn, w) == 0


def test_refund_inside_open_transaction(conn):
    w = wallet(conn)
    ledger.grant(conn, w, 2, "n", NOW)
    conn.execute("BEGIN IMMEDIATE")
    assert ledger.try_debit(conn, w, 2, "c2", NOW)
    assert ledger.refund(conn, w, 2, "c2", NOW) is True
    assert conn.in_transaction
    conn.execute("COMMIT")
    assert ledger.balance(conn, w) == 2


def test_refund_only_for_own_wallet(conn):
    w1, w2 = wallet(conn, 1), wallet(conn, 2)
    ledger.grant(conn, w1, 1, "n", NOW)
    conn.execute("BEGIN IMMEDIATE")
    ledger.try_debit(conn, w1, 1, "c1", NOW)
    conn.execute("COMMIT")
    assert ledger.refund(conn, w2, 1, "c1", NOW) is False


def test_debit_never_below_zero(conn):
    w = wallet(conn)
    ledger.grant(conn, w, 1, "n", NOW)
    conn.execute("BEGIN IMMEDIATE")
    assert ledger.try_debit(conn, w, 2, "c1", NOW) is False
    conn.execute("COMMIT")
    assert ledger.balance(conn, w) == 1


def test_debit_exact_balance_allowed(conn):
    w = wallet(conn)
    ledger.grant(conn, w, 2, "n", NOW)
    conn.execute("BEGIN IMMEDIATE")
    assert ledger.try_debit(conn, w, 2, "c1", NOW) is True
    conn.execute("COMMIT")
    assert ledger.balance(conn, w) == 0


def test_debit_must_be_positive(conn):
    w = wallet(conn)
    conn.execute("BEGIN IMMEDIATE")
    with pytest.raises(ValueError):
        ledger.try_debit(conn, w, 0, "c1", NOW)
    conn.execute("ROLLBACK")


def test_debit_same_reference_not_twice(conn):
    w = wallet(conn)
    ledger.grant(conn, w, 5, "n", NOW)
    conn.execute("BEGIN IMMEDIATE")
    assert ledger.try_debit(conn, w, 1, "c1", NOW) is True
    assert ledger.try_debit(conn, w, 1, "c1", NOW) is False
    conn.execute("COMMIT")
    assert ledger.balance(conn, w) == 4


def test_concurrent_debits_one_wallet(tmp_path):
    path = tmp_path / "g.db"
    c0 = connect(path)
    w = wallet(c0)
    ledger.grant(c0, w, 1, "n", NOW)
    barrier = threading.Barrier(2)
    results = []

    def worker(i):
        c = connect(path)
        barrier.wait()
        c.execute("BEGIN IMMEDIATE")
        ok = ledger.try_debit(c, w, 1, f"ref{i}", NOW)
        c.execute("COMMIT")
        results.append(ok)
        c.close()

    ts = [threading.Thread(target=worker, args=(i,)) for i in range(2)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert sorted(results) == [False, True]
    assert ledger.balance(c0, w) == 0
    c0.close()


def test_ledger_rows_never_updated(conn):
    w = wallet(conn)
    ledger.grant(conn, w, 3, "n", NOW)
    with pytest.raises(sqlite3.DatabaseError):
        conn.execute("UPDATE ledger SET delta=99")
    with pytest.raises(sqlite3.DatabaseError):
        conn.execute("DELETE FROM ledger")
    assert ledger.balance(conn, w) == 3


def test_grant_must_be_positive(conn):
    with pytest.raises(ValueError):
        ledger.grant(conn, wallet(conn), 0, "n", NOW)


def test_rekey_keeps_wallet(conn):
    did = create_device(conn, "k", "old", NOW)
    before = device_by_token_hash(conn, "old")
    rekey_device(conn, did, "k2", "new")
    assert device_by_token_hash(conn, "old") is None
    after = device_by_token_hash(conn, "new")
    assert after["wallet_id"] == before["wallet_id"] and after["key_id"] == "k2"


def test_set_blocked(conn):
    from myguide.db import set_blocked
    did = create_device(conn, "k", "t", NOW)
    set_blocked(conn, did, True)
    assert device_by_token_hash(conn, "t")["blocked"] == 1
    set_blocked(conn, did, False)
    assert device_by_token_hash(conn, "t")["blocked"] == 0


def test_duplicate_key_id_rejected(conn):
    create_device(conn, "k", "t1", NOW)
    with pytest.raises(sqlite3.IntegrityError):
        create_device(conn, "k", "t2", NOW)
    assert conn.execute("SELECT count(*) FROM wallets").fetchone()[0] == 1
    assert not conn.in_transaction


def test_insert_or_replace_refused(conn):
    w = wallet(conn)
    ledger.add_entry(conn, w, 1, "purchase", "tx", NOW)
    with pytest.raises(sqlite3.DatabaseError):
        conn.execute(
            "INSERT OR REPLACE INTO ledger (wallet_id, delta, reason, reference, created_at) "
            "VALUES (?, 99, 'purchase', 'tx', 'x')", (w,))
    assert ledger.balance(conn, w) == 1
    assert ledger.entries(conn, w)[0]["delta"] == 1


def test_refund_amount_must_equal_debit(conn):
    w = wallet(conn)
    ledger.grant(conn, w, 5, "n", NOW)
    conn.execute("BEGIN IMMEDIATE")
    ledger.try_debit(conn, w, 1, "c1", NOW)
    conn.execute("COMMIT")
    with pytest.raises(ValueError):
        ledger.refund(conn, w, 100, "c1", NOW)
    assert not conn.in_transaction
    assert ledger.balance(conn, w) == 4
    assert ledger.refund(conn, w, 1, "c1", NOW) is True
