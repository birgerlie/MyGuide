"""Service: health, attest challenge, attest -> bearer token, token authentication, reload, entry point (spec 5)."""
from __future__ import annotations

import base64
import hashlib
import logging
import os
import signal
import socket
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import httpx
import pytest
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route
from starlette.testclient import TestClient

from myguide import app as app_module
from myguide import db
from myguide.app import authenticate, client_ip, create_app, json_error, rate_key
from myguide.attest import Challenges
from myguide.config import ConfigError
from myguide.state import State
from tests.attest_fixtures import PROD_AAGUID, make_attestation
from tests.conftest import write_env

SERVER_DIR = Path(__file__).parent.parent
APP_ID = "MW432M4HL3.io.github.birgerlie.MyGuide"  # APPLE_TEAM_ID.APPLE_BUNDLE_ID from the template


# --- helpers -----------------------------------------------------------------------------------------------

def sha(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def error_of(response) -> str:
    body = response.json()
    assert set(body) == {"error"}
    assert set(body["error"]) == {"code", "message"}
    assert isinstance(body["error"]["message"], str) and body["error"]["message"]
    return body["error"]["code"]


def new_challenge(client, headers=None) -> str:
    r = client.post("/v1/attest/challenge", headers=headers)
    assert r.status_code == 200, r.text
    return r.json()["challenge"]


def attest_body(root_key, challenge_b64: str, **kw) -> dict:
    att, kid, _ = make_attestation(app_id=APP_ID, challenge=base64.b64decode(challenge_b64), root_key=root_key, **kw)
    return {"keyId": kid, "attestation": base64.b64encode(att).decode(), "challenge": challenge_b64}


def attest(client, root_key, *, previous: str | None = None, headers=None, **kw):
    body = attest_body(root_key, new_challenge(client, headers), **kw)
    if previous is not None:
        body["previousToken"] = previous
    return client.post("/v1/attest", json=body, headers=headers)


def token_of(response) -> str:
    assert response.status_code == 200, response.text
    return response.json()["token"]


def with_probe(state: State) -> TestClient:
    """The app plus a route that runs `authenticate`, as the Task 6 proxy routes will."""
    app = create_app(state)

    async def probe(request: Request):
        conn = db.connect(state.db_path)
        try:
            row = authenticate(request, conn)
        finally:
            conn.close()
        return JSONResponse({"device": row["id"], "wallet": row["wallet_id"]})

    app.router.routes.append(Route("/probe", probe, methods=["GET"]))
    return TestClient(app, client=("127.0.0.1", 50000))


def bearer(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def devices(state: State) -> list[sqlite3.Row]:
    conn = db.connect(state.db_path)
    try:
        return conn.execute("SELECT * FROM devices ORDER BY id").fetchall()
    finally:
        conn.close()


# --- health and challenge ----------------------------------------------------------------------------------

def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"ok": True}


def test_challenge_is_32_random_bytes(client):
    r = client.post("/v1/attest/challenge")
    assert r.status_code == 200
    assert r.headers["cache-control"] == "no-store"
    c1 = r.json()["challenge"]
    assert len(base64.b64decode(c1, validate=True)) == 32
    assert new_challenge(client) != c1


def test_unknown_route_answers_error_shape(client):
    r = client.get("/nope")
    assert r.status_code == 404
    assert error_of(r) == "not_found"


def test_challenge_get_not_allowed(client):
    r = client.get("/v1/attest/challenge")
    assert r.status_code == 405
    assert error_of(r) == "bad_request"


# --- attest ------------------------------------------------------------------------------------------------

def test_attest_valid_issues_token_and_stores_only_its_hash(client, state, root_key):
    body = attest_body(root_key, new_challenge(client))
    r = client.post("/v1/attest", json=body)
    token = token_of(r)
    assert r.headers["cache-control"] == "no-store"
    # 32 bytes base64url without padding: ceil(32 * 4 / 3) = 43 characters, no '='.
    assert len(token) == 43 and "=" not in token
    assert len(base64.urlsafe_b64decode(token + "=")) == 32

    rows = devices(state)
    assert len(rows) == 1
    assert rows[0]["token_hash"] == sha(token)
    assert rows[0]["key_id"] == body["keyId"]
    assert rows[0]["blocked"] == 0

    conn = sqlite3.connect(state.db_path)
    try:
        tables = [t for (t,) in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")]
        texts = [v for t in tables for row in conn.execute(f"SELECT * FROM {t}") for v in row if isinstance(v, str)]
    finally:
        conn.close()
    assert texts, "the scan found no text at all"
    assert not [v for v in texts if token in v]


def test_attest_reused_challenge_400(client, root_key):
    body = attest_body(root_key, new_challenge(client))
    token_of(client.post("/v1/attest", json=body))
    again = attest_body(root_key, body["challenge"])
    r = client.post("/v1/attest", json=again)
    assert r.status_code == 400
    assert error_of(r) == "bad_request"


def test_attest_unknown_challenge_400(client, root_key):
    unknown = base64.b64encode(os.urandom(32)).decode()
    r = client.post("/v1/attest", json=attest_body(root_key, unknown))
    assert r.status_code == 400
    assert error_of(r) == "bad_request"


def test_attest_expired_challenge_400(client, state, mono, root_key):
    challenge = new_challenge(client)
    mono.advance(state.settings.challenge_ttl_seconds + 1)
    r = client.post("/v1/attest", json=attest_body(root_key, challenge))
    assert r.status_code == 400
    assert error_of(r) == "bad_request"


def test_attest_bad_attestation_401_and_burns_challenge(client, state, root_key):
    challenge = new_challenge(client)
    bad = attest_body(root_key, challenge, nonce_override=b"\x00" * 32)
    r = client.post("/v1/attest", json=bad)
    assert r.status_code == 401
    assert error_of(r) == "attest_required"
    # The challenge was consumed before verification: a good attestation on it is now refused.
    r = client.post("/v1/attest", json=attest_body(root_key, challenge))
    assert r.status_code == 400
    assert devices(state) == []


def test_attest_garbage_attestation_401(client, root_key):
    body = attest_body(root_key, new_challenge(client))
    body["attestation"] = base64.b64encode(b"not cbor at all").decode()
    r = client.post("/v1/attest", json=body)
    assert r.status_code == 401
    assert error_of(r) == "attest_required"


def test_attest_development_aaguid_refused_when_not_allowed(make_state, root_key):
    state = make_state(ALLOW_DEVELOPMENT_ATTEST="0")
    with TestClient(create_app(state), client=("127.0.0.1", 50000)) as client:
        r = attest(client, root_key)  # default aaguid is appattestdevelop
        assert r.status_code == 401
        assert error_of(r) == "attest_required"
        # Positive control: production aaguid passes under the same settings.
        token_of(attest(client, root_key, aaguid=PROD_AAGUID))


def test_attest_verifier_crash_fails_closed_and_logs_only_type(client, state, root_key, monkeypatch, caplog):
    def boom(**kwargs):
        raise RuntimeError("secret-detail")

    monkeypatch.setattr(app_module, "verify_attestation", boom)
    caplog.set_level(logging.DEBUG)
    r = attest(client, root_key)
    assert r.status_code == 401
    assert error_of(r) == "attest_required"
    messages = [rec.getMessage() for rec in caplog.records]
    assert any("RuntimeError" in m for m in messages)
    assert not any("secret-detail" in m for m in messages)
    assert all(rec.exc_info is None for rec in caplog.records)
    assert devices(state) == []


def test_attest_key_id_already_on_other_device_401(client, state, root_key):
    body = attest_body(root_key, new_challenge(client))
    conn = db.connect(state.db_path)
    try:
        db.create_device(conn, body["keyId"], "0" * 64, state.clock())
    finally:
        conn.close()
    r = client.post("/v1/attest", json=body)
    assert r.status_code == 401
    assert error_of(r) == "attest_required"
    assert len(devices(state)) == 1


@pytest.mark.parametrize("raw", [
    b"not json",
    b"\xff\xfe",
    b"[]",
    b'"text"',
    b"{}",
])
def test_attest_body_not_an_object_400(client, raw):
    r = client.post("/v1/attest", content=raw, headers={"Content-Type": "application/json"})
    assert r.status_code == 400
    assert error_of(r) == "bad_request"


@pytest.mark.parametrize("mutate", [
    lambda b: b.pop("keyId"),
    lambda b: b.pop("attestation"),
    lambda b: b.pop("challenge"),
    lambda b: b.update(keyId=12),
    lambda b: b.update(attestation=None),
    lambda b: b.update(challenge=["x"]),
    lambda b: b.update(previousToken=5),
    lambda b: b.update(previousToken=None),
    lambda b: b.update(attestation="not base64!"),
], ids=["no-keyId", "no-attestation", "no-challenge", "keyId-int", "attestation-null", "challenge-list",
        "previousToken-int", "previousToken-null", "attestation-not-base64"])
def test_attest_bad_shape_400_keeps_challenge(client, root_key, mutate):
    body = attest_body(root_key, new_challenge(client))
    good = dict(body)
    mutate(body)
    r = client.post("/v1/attest", json=body)
    assert r.status_code == 400
    assert error_of(r) == "bad_request"
    # A shape error comes before the challenge is consumed, so the same challenge still works.
    token_of(client.post("/v1/attest", json=good))


def test_attest_body_limit_is_a_setting(make_state):
    state = make_state(ATTEST_MAX_BODY_BYTES="100")
    with TestClient(create_app(state), client=("127.0.0.1", 50000)) as client:
        assert client.post("/v1/attest", content=b" " * 100).status_code == 400  # at the limit: read
        r = client.post("/v1/attest", content=b" " * 101)
        assert r.status_code == 413
        assert error_of(r) == "body_too_large"


def test_attest_body_over_64k_413(client, root_key):
    body = attest_body(root_key, new_challenge(client))
    body["padding"] = "x" * (64 * 1024)
    r = client.post("/v1/attest", json=body)
    assert r.status_code == 413
    assert error_of(r) == "body_too_large"


def test_attest_chunked_body_over_64k_413(client):
    def chunks():
        for _ in range(17):
            yield b"x" * 4096  # 17 * 4096 = 69632 > 65536

    r = client.post("/v1/attest", content=chunks())
    assert r.status_code == 413
    assert error_of(r) == "body_too_large"


def test_attest_body_exactly_64k_is_read(client):
    # 65536 bytes is at the limit, not over it: refused for its shape (400), not its size.
    r = client.post("/v1/attest", content=b" " * (64 * 1024))
    assert r.status_code == 400
    r = client.post("/v1/attest", content=b" " * (64 * 1024 + 1))
    assert r.status_code == 413


# --- previousToken (Ruling 3) ------------------------------------------------------------------------------

def test_previous_token_rekeys_same_device(state, root_key):
    with with_probe(state) as client:
        old = token_of(attest(client, root_key))
        first = devices(state)[0]
        new = token_of(attest(client, root_key, previous=old))
        assert new != old
        rows = devices(state)
        assert len(rows) == 1
        assert rows[0]["id"] == first["id"] and rows[0]["wallet_id"] == first["wallet_id"]
        assert rows[0]["key_id"] != first["key_id"]
        r = client.get("/probe", headers=bearer(new))
        assert r.status_code == 200 and r.json()["device"] == first["id"]
        r = client.get("/probe", headers=bearer(old))
        assert r.status_code == 401
        assert error_of(r) == "attest_required"


def test_previous_token_of_blocked_device_403(client, state, root_key):
    old = token_of(attest(client, root_key))
    conn = db.connect(state.db_path)
    try:
        db.set_blocked(conn, devices(state)[0]["id"], True)
    finally:
        conn.close()
    r = attest(client, root_key, previous=old)
    assert r.status_code == 403
    assert error_of(r) == "blocked"
    assert len(devices(state)) == 1
    assert devices(state)[0]["token_hash"] == sha(old)


def test_unknown_previous_token_makes_new_device(client, state, root_key):
    token_of(attest(client, root_key))
    token_of(attest(client, root_key, previous="made-up-token"))
    rows = devices(state)
    assert len(rows) == 2
    assert rows[0]["wallet_id"] != rows[1]["wallet_id"]


# --- authenticate ------------------------------------------------------------------------------------------

@pytest.mark.parametrize("header", [None, "", "Bearer", "Bearer ", "Basic abc", "Bearer made-up-token"])
def test_authenticate_missing_or_unknown_401(state, header):
    with with_probe(state) as client:
        r = client.get("/probe", headers={} if header is None else {"Authorization": header})
        assert r.status_code == 401
        assert error_of(r) == "attest_required"


def test_authenticate_valid_and_blocked(state, root_key):
    with with_probe(state) as client:
        token = token_of(attest(client, root_key))
        r = client.get("/probe", headers={"Authorization": f"bearer {token}"})  # scheme is case-insensitive
        assert r.status_code == 200
        device_id = r.json()["device"]
        conn = db.connect(state.db_path)
        try:
            db.set_blocked(conn, device_id, True)
        finally:
            conn.close()
        r = client.get("/probe", headers=bearer(token))
        assert r.status_code == 403
        assert error_of(r) == "blocked"


def test_json_error_shape():
    r = json_error(429, "rate_limited", "Slow down.", headers={"Retry-After": "60"})
    assert r.status_code == 429
    assert r.headers["retry-after"] == "60"
    assert r.body == b'{"error":{"code":"rate_limited","message":"Slow down."}}'


# --- per-IP limits -----------------------------------------------------------------------------------------

def test_21st_attest_from_one_ip_429_other_ip_allowed(make_state, mono, root_key):
    state = make_state(ATTESTS_PER_IP_PER_HOUR="20")
    with TestClient(create_app(state), client=("127.0.0.1", 50000)) as client:
        ip_a = {"X-Forwarded-For": "198.51.100.7"}
        for i in range(20):
            token_of(attest(client, root_key, headers=ip_a))
        r = attest(client, root_key, headers=ip_a)
        assert r.status_code == 429
        assert error_of(r) == "rate_limited"
        token_of(attest(client, root_key, headers={"X-Forwarded-For": "198.51.100.8"}))
        # Sliding hour: the 21 hits are at t=1000; at t=1000+3600 they are out of the window (hit > now - 3600).
        mono.advance(3600)
        token_of(attest(client, root_key, headers=ip_a))


def test_attest_limit_zero_refuses_all(make_state, root_key):
    state = make_state(ATTESTS_PER_IP_PER_HOUR="0")
    with TestClient(create_app(state), client=("127.0.0.1", 50000)) as client:
        new_challenge(client)  # challenges have their own window (CHALLENGES_PER_IP_PER_HOUR >= 1)
        r = client.post("/v1/attest", json={})
        assert r.status_code == 429
        assert error_of(r) == "rate_limited"


def test_challenges_per_ip_limit_is_its_own_setting(make_state):
    # CHALLENGES_PER_IP_PER_HOUR=6 (ATTESTS_PER_IP_PER_HOUR=1 does not apply): six pass, the seventh is refused.
    state = make_state(CHALLENGES_PER_IP_PER_HOUR="6", ATTESTS_PER_IP_PER_HOUR="1")
    with TestClient(create_app(state), client=("127.0.0.1", 50000)) as client:
        ip = {"X-Forwarded-For": "203.0.113.1"}
        for _ in range(6):
            new_challenge(client, ip)
        r = client.post("/v1/attest/challenge", headers=ip)
        assert r.status_code == 429
        assert error_of(r) == "rate_limited"
        new_challenge(client, {"X-Forwarded-For": "203.0.113.2"})


def test_outstanding_challenge_cap(make_state, mono, tmp_path):
    state = make_state(CHALLENGES_MAX_OUTSTANDING="2")
    with TestClient(create_app(state), client=("127.0.0.1", 50000)) as client:
        new_challenge(client, {"X-Forwarded-For": "203.0.113.1"})
        new_challenge(client, {"X-Forwarded-For": "203.0.113.2"})
        r = client.post("/v1/attest/challenge", headers={"X-Forwarded-For": "203.0.113.3"})
        assert r.status_code == 429
        assert error_of(r) == "rate_limited"
        # Once the outstanding ones expire they no longer count.
        mono.advance(state.settings.challenge_ttl_seconds + 1)
        new_challenge(client, {"X-Forwarded-For": "203.0.113.3"})
        # A reload that raises the cap applies at once.
        new_challenge(client, {"X-Forwarded-For": "203.0.113.4"})
        assert client.post("/v1/attest/challenge", headers={"X-Forwarded-For": "203.0.113.5"}).status_code == 429
        state.reload(write_env(tmp_path / "env", CHALLENGES_MAX_OUTSTANDING="3"))
        new_challenge(client, {"X-Forwarded-For": "203.0.113.5"})


def test_challenges_cap_unit():
    c = Challenges(lambda: 10, max_outstanding=lambda: 2)
    a = c.issue(0.0)
    assert c.issue(0.0) is not None
    assert c.issue(1.0) is None
    assert c.consume(a, 2.0) is not None  # consuming frees a slot
    assert c.issue(2.0) is not None
    # At 11 with ttl 10: the one issued at 0 has expired (11-0=11 > 10), the one at 2 is alive (11-2=9 <= 10):
    # one outstanding, so a slot is free; after that two are outstanding and the next is refused.
    assert c.issue(11.0) is not None
    assert c.issue(11.0) is None


def _request(peer: str | None, xff: list[str] | None = None) -> Request:
    headers = [(b"x-forwarded-for", v.encode()) for v in (xff or [])]
    scope = {"type": "http", "method": "GET", "path": "/", "headers": headers,
             "client": (peer, 1234) if peer is not None else None}
    return Request(scope)


@pytest.mark.parametrize("peer,xff,expected", [
    ("127.0.0.1", ["198.51.100.7"], "198.51.100.7"),
    ("127.0.0.1", ["10.0.0.1, 198.51.100.7"], "198.51.100.7"),
    ("::1", ["10.0.0.1,2001:db8::5"], "2001:db8::5"),
    ("127.0.0.1", ["10.0.0.1", "198.51.100.9"], "198.51.100.9"),
    ("127.0.0.1", [], "127.0.0.1"),
    ("127.0.0.1", ["10.0.0.1, "], "127.0.0.1"),
    ("203.0.113.5", ["198.51.100.7"], "203.0.113.5"),
    (None, ["198.51.100.7"], "unknown"),
])
def test_client_ip(peer, xff, expected):
    assert client_ip(_request(peer, xff)) == expected


@pytest.mark.parametrize("ip,expected", [
    ("198.51.100.7", "198.51.100.7"),
    ("2001:db8:1:2:aaaa::1", "2001:db8:1:2::/64"),
    ("2001:db8:1:2:ffff:ffff:ffff:ffff", "2001:db8:1:2::/64"),
    ("2001:db8:1:3::1", "2001:db8:1:3::/64"),
    ("2001:DB8:1:2::9", "2001:db8:1:2::/64"),
    ("::ffff:198.51.100.7", "198.51.100.7"),
    ("::ffff:c633:6407", "198.51.100.7"),
    ("fe80::1%eth0", "fe80::/64"),
    ("::1", "::/64"),
    ("unknown", "unknown"),
    ("not an ip", "not an ip"),
    ("", ""),
])
def test_rate_key(ip, expected):
    assert rate_key(ip) == expected


def test_ipv6_same_64_shares_attest_limit(make_state, root_key):
    state = make_state(ATTESTS_PER_IP_PER_HOUR="1")
    with TestClient(create_app(state), client=("127.0.0.1", 50000)) as client:
        token_of(attest(client, root_key, headers={"X-Forwarded-For": "2001:db8:1:2::1"}))
        r = attest(client, root_key, headers={"X-Forwarded-For": "2001:db8:1:2:dead:beef:0:7"})
        assert r.status_code == 429
        assert error_of(r) == "rate_limited"
        token_of(attest(client, root_key, headers={"X-Forwarded-For": "2001:db8:1:3::1"}))  # another /64


def test_mapped_ipv4_shares_limit_with_plain_ipv4(make_state, root_key):
    state = make_state(ATTESTS_PER_IP_PER_HOUR="1")
    with TestClient(create_app(state), client=("127.0.0.1", 50000)) as client:
        token_of(attest(client, root_key, headers={"X-Forwarded-For": "198.51.100.7"}))
        r = attest(client, root_key, headers={"X-Forwarded-For": "::ffff:198.51.100.7"})
        assert r.status_code == 429


def test_ipv6_same_64_shares_challenge_limit(make_state):
    state = make_state(CHALLENGES_PER_IP_PER_HOUR="1")
    with TestClient(create_app(state), client=("127.0.0.1", 50000)) as client:
        new_challenge(client, {"X-Forwarded-For": "2001:db8:9:9::1"})
        r = client.post("/v1/attest/challenge", headers={"X-Forwarded-For": "2001:db8:9:9::2"})
        assert r.status_code == 429
        new_challenge(client, {"X-Forwarded-For": "2001:db8:9:a::1"})


def test_xff_ignored_from_non_loopback_peer(make_state, root_key):
    state = make_state(ATTESTS_PER_IP_PER_HOUR="1")
    with TestClient(create_app(state), client=("203.0.113.5", 50000)) as client:
        token_of(attest(client, root_key, headers={"X-Forwarded-For": "198.51.100.1"}))
        r = attest(client, root_key, headers={"X-Forwarded-For": "198.51.100.2"})
        assert r.status_code == 429


# --- nothing sensitive in logs -----------------------------------------------------------------------------

def test_logs_hold_no_token_ip_or_challenge(state, root_key, caplog):
    caplog.set_level(logging.DEBUG)
    ip = {"X-Forwarded-For": "198.51.100.77"}
    with with_probe(state) as client:
        challenge = new_challenge(client, ip)
        body = attest_body(root_key, challenge)
        token = token_of(client.post("/v1/attest", json=body, headers=ip))
        token2 = token_of(attest(client, root_key, previous=token, headers=ip))
        client.post("/v1/attest", json=body, headers=ip)  # reused challenge, refused
        client.get("/probe", headers=bearer(token))  # old token, refused
        attest(client, root_key, headers={"X-Forwarded-For": "2001:db8:77:77::5"})
    secrets_ = [token, token2, sha(token), challenge, body["keyId"], body["attestation"][:40], "198.51.100.77",
                "2001:db8:77:77", "2001:db8:77:77::/64"]
    messages = [rec.getMessage() for rec in caplog.records]
    assert messages, "expected some log lines"
    for m in messages:
        for s in secrets_:
            assert s not in m


# --- reload and entry point --------------------------------------------------------------------------------

def test_reload_changes_limit_without_restart(tmp_path, test_root, caplog):
    path = write_env(tmp_path / "env", QUOTA_STORY_PER_DAY="80")
    from myguide.config import load_settings
    state = State(load_settings(path), tmp_path / "guide.db", root=test_root)
    assert state.settings.quota_story_per_day == 80
    write_env(path, QUOTA_STORY_PER_DAY="5")
    state.reload(path)
    assert state.settings.quota_story_per_day == 5
    write_env(path, QUOTA_STORY_PER_DAY="abc")
    caplog.set_level(logging.INFO)
    state.reload(path)
    assert state.settings.quota_story_per_day == 5
    assert any("QUOTA_STORY_PER_DAY" in rec.getMessage() for rec in caplog.records)


def test_reload_applies_to_windows_at_once(tmp_path, test_root, mono):
    path = write_env(tmp_path / "env", ATTESTS_PER_IP_PER_HOUR="1")
    from myguide.config import load_settings
    state = State(load_settings(path), tmp_path / "guide.db", root=test_root, monotonic=mono)
    assert state.attest_window.hit("a", mono()) is True
    assert state.attest_window.hit("a", mono()) is False
    write_env(path, ATTESTS_PER_IP_PER_HOUR="5")
    state.reload(path)
    assert state.attest_window.hit("a", mono()) is True  # 3 hits <= 5


def test_main_refuses_bad_env(tmp_path):
    bad = write_env(tmp_path / "env", QUOTA_STORY_PER_DAY="abc")
    db_path = tmp_path / "guide.db"
    result = subprocess.run(
        [sys.executable, "-m", "myguide", "--env", str(bad), "--db", str(db_path)],
        cwd=SERVER_DIR, capture_output=True, text=True, timeout=30,
    )
    assert result.returncode == 1
    assert result.stderr.startswith("QUOTA_STORY_PER_DAY")
    assert not db_path.exists()


def test_main_ignores_sighup_from_its_first_line(tmp_path, monkeypatch):
    """Until the reload handler is installed on the event loop, a SIGHUP (a reload during start) must not kill
    the service: Python's default for SIGHUP is to terminate."""
    import myguide.__main__ as entry

    seen: list[object] = []

    def fake_load(path):
        seen.append(signal.getsignal(signal.SIGHUP))
        raise ConfigError("QUOTA_STORY_PER_DAY: test stop")

    previous = signal.signal(signal.SIGHUP, signal.SIG_DFL)
    try:
        monkeypatch.setattr(entry, "load_settings", fake_load)
        assert entry.main(["--env", str(tmp_path / "env"), "--db", str(tmp_path / "guide.db")]) == 1
        assert seen == [signal.SIG_IGN]
    finally:
        signal.signal(signal.SIGHUP, previous)


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _wait_for(predicate, timeout: float = 15.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.1)
    return False


def test_main_serves_health_and_reloads_on_sighup(tmp_path):
    port = _free_port()
    env = write_env(tmp_path / "env", LISTEN_PORT=str(port))
    db_path = tmp_path / "guide.db"
    log_path = tmp_path / "stderr.log"
    with open(log_path, "w") as log_file:
        proc = subprocess.Popen(
            [sys.executable, "-m", "myguide", "--env", str(env), "--db", str(db_path)],
            cwd=SERVER_DIR, stdout=subprocess.DEVNULL, stderr=log_file,
        )
        try:
            def healthy() -> bool:
                try:
                    return httpx.get(f"http://127.0.0.1:{port}/health", timeout=1).json() == {"ok": True}
                except httpx.HTTPError:
                    return False

            assert _wait_for(healthy), log_path.read_text()
            r = httpx.get(f"http://127.0.0.1:{port}/health")
            assert "server" not in r.headers
            assert db_path.exists()

            write_env(env, LISTEN_PORT=str(port), QUOTA_STORY_PER_DAY="5")
            proc.send_signal(signal.SIGHUP)
            assert _wait_for(lambda: "settings reloaded" in log_path.read_text()), log_path.read_text()
            write_env(env, LISTEN_PORT=str(port), QUOTA_STORY_PER_DAY="abc")
            proc.send_signal(signal.SIGHUP)
            assert _wait_for(lambda: "QUOTA_STORY_PER_DAY" in log_path.read_text()), log_path.read_text()
            assert proc.poll() is None, "SIGHUP must not stop the service"
            assert healthy()
        finally:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
    # uvicorn shuts down cleanly, then re-raises the captured SIGTERM, so the exit is -15 (systemd: success).
    assert proc.returncode in (0, -signal.SIGTERM), log_path.read_text()
    assert "Application shutdown complete" in log_path.read_text()
