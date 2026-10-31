"""The OpenAI pass-through: allowlists, store:false, streaming, quota headers, settlement (spec 6, 6.2).

The upstream is an `httpx.MockTransport` that records every request it sees.
"""
from __future__ import annotations

import gzip
import hashlib
import json
import logging
import sqlite3
from collections.abc import AsyncIterator, Callable

import anyio
import httpx
import pytest
from starlette.requests import ClientDisconnect
from starlette.testclient import TestClient

from myguide import db, ledger
from myguide.app import create_app
from myguide.config import parse_settings
from myguide.state import State, upstream_client
from tests.attest_fixtures import NOW
from tests.conftest import env_dict

TOKEN = "tok-device-1"
DAY = "2026-10-30"  # UTC date of NOW
STORY = "gpt-5-mini"
SPEECH = "gpt-4o-mini-tts"
IMAGE = "gpt-image-2.5-flare"
USAGE = {"input_tokens": 1000, "input_tokens_details": {"cached_tokens": 200}, "output_tokens": 500}
# Story cost with USAGE at PRICE_GPT_5_MINI=0.25,0.025,2.00 (USD per million = µUSD per token):
# (1000-200)*0.25 + 200*0.025 + 500*2.00 = 200 + 5 + 1000 = 1205 µUSD
STORY_COST = 1205
# The same usage at a reloaded price of 1.00,1.00,1.00: 800 + 200 + 500 = 1500 µUSD (must NOT be used).
FREE_80 = "story=80,speech=80,image=4"
FREE_79 = "story=79,speech=80,image=4"


def sha(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


# --- upstream double ---------------------------------------------------------------------------------------

class Upstream:
    """Records requests; `respond(request)` builds the answer (may raise an httpx error, may be async)."""

    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.bodies: list[bytes] = []
        self.respond: Callable = lambda request: httpx.Response(200, json=story_ok())

    async def handler(self, request: httpx.Request) -> httpx.Response:
        self.bodies.append(await request.aread())
        self.requests.append(request)
        result = self.respond(request)
        if hasattr(result, "__await__"):
            result = await result
        return result

    def json_body(self, i: int = -1) -> dict:
        return json.loads(self.bodies[i])


def story_ok(usage=USAGE, text="Once upon a time") -> dict:
    return {"id": "resp_1", "model": "gpt-5-mini-2026-08-07", "output_text": text, "usage": usage}


def sse_event(name: str, obj: dict) -> bytes:
    return f"event: {name}\ndata: {json.dumps(obj)}\n\n".encode()


def sse_delta(text: str) -> bytes:
    return sse_event("response.output_text.delta", {"type": "response.output_text.delta", "delta": text})


def sse_completed(usage=USAGE) -> bytes:
    return sse_event("response.completed", {"type": "response.completed", "response": {"id": "r", "usage": usage}})


async def chunks_of(parts: list[bytes]) -> AsyncIterator[bytes]:
    for p in parts:
        yield p


def sse_response(parts: list[bytes], status: int = 200) -> httpx.Response:
    return httpx.Response(status, headers={"content-type": "text/event-stream"}, content=chunks_of(parts))


# --- fixtures ----------------------------------------------------------------------------------------------

@pytest.fixture
def upstream() -> Upstream:
    return Upstream()


@pytest.fixture
def make_proxy(tmp_path, test_root, mono, upstream):
    """make_proxy(**env_overrides) -> State with the mock upstream and one device whose token is TOKEN."""
    def factory(**overrides: str) -> State:
        st = State(
            parse_settings(env_dict(**overrides)), tmp_path / "guide.db", root=test_root,
            upstream=upstream_client(httpx.MockTransport(upstream.handler)),
            clock=lambda: NOW, monotonic=mono,
        )
        conn = db.connect(st.db_path)
        try:
            if db.device_by_token_hash(conn, sha(TOKEN)) is None:
                db.create_device(conn, "key-1", sha(TOKEN), NOW)
        finally:
            conn.close()
        return st
    return factory


@pytest.fixture
def state(make_proxy) -> State:
    return make_proxy()


@pytest.fixture
def client(state):
    with TestClient(create_app(state), client=("127.0.0.1", 50000)) as c:
        yield c


def auth(token: str = TOKEN, **extra: str) -> dict:
    return {"Authorization": f"Bearer {token}", **extra}


def story_body(**extra) -> dict:
    return {"model": STORY, "input": "Fortell om stedet", **extra}


def query(state: State, sql: str, args=()) -> list[sqlite3.Row]:
    conn = db.connect(state.db_path)
    try:
        return conn.execute(sql, args).fetchall()
    finally:
        conn.close()


def calls(state: State) -> list[sqlite3.Row]:
    return query(state, "SELECT * FROM calls ORDER BY id")


def today(state: State) -> sqlite3.Row:
    return query(state, "SELECT * FROM device_days WHERE device_id=1 AND day=?", (DAY,))[0]


def error_of(response) -> str:
    body = response.json()
    assert set(body) == {"error"} and set(body["error"]) == {"code", "message"}
    assert isinstance(body["error"]["message"], str) and body["error"]["message"]
    return body["error"]["code"]


def assert_allowance(response, free_left: str, credits: int = 0) -> None:
    assert response.headers["x-myguide-free-left"] == free_left
    assert response.headers["x-myguide-credits"] == str(credits)


# --- authentication ----------------------------------------------------------------------------------------

@pytest.mark.parametrize("headers", [{}, auth("made-up-token"), {"Authorization": "Basic abc"}])
def test_no_or_unknown_token_401_and_upstream_sees_nothing(client, upstream, headers):
    r = client.post("/v1/responses", json=story_body(), headers=headers)
    assert r.status_code == 401
    assert error_of(r) == "attest_required"
    assert upstream.requests == []
    assert "x-myguide-free-left" not in r.headers


def test_blocked_device_403_and_upstream_sees_nothing(client, state, upstream):
    conn = db.connect(state.db_path)
    db.set_blocked(conn, 1, True)
    conn.close()
    r = client.post("/v1/responses", json=story_body(), headers=auth())
    assert r.status_code == 403
    assert error_of(r) == "blocked"
    assert upstream.requests == []
    assert calls(state) == []
    # The device is known, so the refusal is counted for it: one request, one refused.
    row = today(state)
    assert (row["requests"], row["refused"]) == (1, 1)
    r = client.post("/v1/models", json={}, headers=auth())  # blocked wins over an unknown path
    assert r.status_code == 403 and error_of(r) == "blocked"
    row = today(state)
    assert (row["requests"], row["refused"]) == (2, 2)
    assert state.inflight.count(1) == 0


# --- allowlists and body checks ----------------------------------------------------------------------------

def test_unknown_path_and_model_refused_and_counted(client, state, upstream):
    r = client.post("/v1/models", json={}, headers=auth())
    assert r.status_code == 404
    assert error_of(r) == "not_found"
    assert_allowance(r, FREE_80)

    r = client.post("/v1/responses", json=story_body(model="gpt-4o"), headers=auth())
    assert r.status_code == 400
    assert error_of(r) == "model_not_allowed"
    assert_allowance(r, FREE_80)

    assert upstream.requests == []
    row = today(state)
    assert row["refused"] == 2 and row["requests"] == 2
    assert calls(state) == []


@pytest.mark.parametrize("path", ["responses/../models", "chat/completions", "audio/speech/x", "Responses"])
def test_paths_off_the_list_404(client, upstream, path):
    r = client.post(f"/v1/{path}", json=story_body(), headers=auth())
    assert r.status_code == 404
    assert error_of(r) == "not_found"
    assert upstream.requests == []


def test_a_model_of_another_kind_is_not_allowed(client, upstream):
    r = client.post("/v1/responses", json=story_body(model=SPEECH), headers=auth())
    assert r.status_code == 400 and error_of(r) == "model_not_allowed"
    r = client.post("/v1/audio/speech", json={"model": STORY, "input": "x"}, headers=auth())
    assert r.status_code == 400 and error_of(r) == "model_not_allowed"
    assert upstream.requests == []


@pytest.mark.parametrize("raw", [
    b"not json",
    b"[1,2]",
    b'"gpt-5-mini"',
    b"{}",
    b'{"model": 5}',
    b'{"model": null}',
    b'{"model": "gpt-5-mini", "input": NaN}',
    b'{"model": "gpt-5-mini", "input": "\\ud800"}',  # lone surrogate: cannot be sent on as UTF-8
    b"\xff\xfe\x00garbage",
    b"[" * 100_000,  # nesting too deep for the parser
])
def test_bad_bodies_400(client, state, upstream, raw):
    r = client.post("/v1/responses", content=raw, headers=auth(**{"Content-Type": "application/json"}))
    assert r.status_code == 400
    assert error_of(r) == "bad_request"
    assert_allowance(r, FREE_80)
    assert upstream.requests == []
    assert today(state)["refused"] == 1


def test_duplicate_model_key_cannot_smuggle_a_model(client, upstream):
    # json.loads keeps the last key; the body is re-serialized, so upstream sees exactly the checked model.
    raw = b'{"model": "gpt-4o", "model": "gpt-5-mini", "input": "x"}'
    r = client.post("/v1/responses", content=raw, headers=auth())
    assert r.status_code == 200
    assert upstream.bodies[0].count(b'"model"') == 1
    assert upstream.json_body()["model"] == STORY


def test_body_over_max_413(make_proxy, upstream):
    state = make_proxy(MAX_BODY_BYTES="1000")
    with TestClient(create_app(state), client=("127.0.0.1", 50000)) as c:
        big = story_body(input="x" * 1000)
        r = c.post("/v1/responses", json=big, headers=auth())
        assert r.status_code == 413
        assert error_of(r) == "body_too_large"
        assert_allowance(r, FREE_80)

        def chunked():  # no Content-Length: the limit holds on the bytes read
            yield b'{"model":"gpt-5-mini","input":"'
            yield b"y" * 2000
            yield b'"}'
        r = c.post("/v1/responses", content=chunked(), headers=auth())
        assert r.status_code == 413
        assert error_of(r) == "body_too_large"

        ok = story_body(input="x" * 900)
        assert len(json.dumps(ok)) <= 1000
        assert c.post("/v1/responses", json=ok, headers=auth()).status_code == 200
    assert len(upstream.requests) == 1
    assert today(state)["refused"] == 2


def test_get_on_a_known_path_405(client, upstream):
    r = client.get("/v1/responses", headers=auth())
    assert r.status_code == 405
    assert error_of(r) == "bad_request"
    assert upstream.requests == []
    # Task 5 routes keep their own answers.
    assert client.get("/v1/attest").status_code == 405
    assert client.get("/health").json() == {"ok": True}


# --- the forwarded request ---------------------------------------------------------------------------------

def test_story_store_forced_false_rest_unchanged_and_only_server_headers(client, upstream):
    sent = story_body(store=True, temperature=0.5, metadata={"a": "b"}, input=[{"role": "user", "content": "på"}])
    r = client.post(
        "/v1/responses?debug=1", json=sent,
        headers=auth(**{"X-Forwarded-For": "203.0.113.7", "User-Agent": "MyGuide/1.0", "Cookie": "c=1",
                        "OpenAI-Organization": "org-x", "X-Custom": "v"}),
    )
    assert r.status_code == 200
    req = upstream.requests[0]
    assert req.method == "POST"
    assert str(req.url) == "https://api.openai.com/v1/responses"  # no query string passed on
    got = upstream.json_body()
    assert got["store"] is False
    assert {k: v for k, v in got.items() if k != "store"} == {k: v for k, v in sent.items() if k != "store"}
    assert req.headers["authorization"] == "Bearer sk-test"
    assert req.headers["content-type"] == "application/json"
    for name in ("x-forwarded-for", "cookie", "openai-organization", "x-custom"):
        assert name not in req.headers
    assert dict(req.headers) == {
        "host": "api.openai.com",
        "content-length": str(len(upstream.bodies[0])),
        "authorization": "Bearer sk-test",
        "content-type": "application/json",
        "user-agent": "MyGuide-guide-server",
        "accept-encoding": "identity",
    }
    # The request has a timeout of UPSTREAM_TIMEOUT_SECONDS (template: 120).
    assert req.extensions["timeout"] == {"connect": 120, "read": 120, "write": 120, "pool": 120}


def test_story_without_store_gets_store_false(client, upstream):
    client.post("/v1/responses", json=story_body(), headers=auth())
    assert upstream.json_body()["store"] is False


def test_speech_body_passes_untouched_no_store_added(client, upstream):
    upstream.respond = lambda req: httpx.Response(200, headers={"content-type": "audio/mpeg"}, content=b"ID3")
    sent = {"model": SPEECH, "input": "Hei", "voice": "alloy", "stream": False}
    client.post("/v1/audio/speech", json=sent, headers=auth())
    assert upstream.json_body() == sent
    assert "accept" not in upstream.requests[0].headers
    assert str(upstream.requests[0].url) == "https://api.openai.com/v1/audio/speech"


@pytest.mark.parametrize("path,body", [
    ("audio/speech", {"model": SPEECH, "input": "Hei", "stream": True}),
    ("audio/speech", {"model": SPEECH, "input": "Hei", "stream": "true"}),
    ("images/generations", {"model": IMAGE, "prompt": "x", "stream": True}),
    ("images/generations", {"model": IMAGE, "prompt": "x", "stream": 1}),
    ("responses", story_body(tools=[{"type": "web_search"}])),
    ("responses", story_body(tools={"type": "web_search"})),
    ("responses", story_body(background=True)),
    ("responses", story_body(background="yes")),
])
def test_unmetered_features_refused_400(client, state, upstream, path, body):
    r = client.post(f"/v1/{path}", json=body, headers=auth())
    assert r.status_code == 400
    assert error_of(r) == "bad_request"
    assert_allowance(r, FREE_80)
    assert upstream.requests == []
    assert today(state)["refused"] == 1
    assert calls(state) == []


@pytest.mark.parametrize("path,body", [
    ("images/generations", {"model": IMAGE, "prompt": "x", "stream": False}),
    ("audio/speech", {"model": SPEECH, "input": "Hei", "stream": None}),
    ("responses", story_body(tools=[])),
    ("responses", story_body(tools=None, background=False)),
])
def test_harmless_values_of_those_fields_pass(client, upstream, path, body):
    upstream.respond = lambda req: httpx.Response(200, json={})
    r = client.post(f"/v1/{path}", json=body, headers=auth())
    assert r.status_code == 200
    assert len(upstream.requests) == 1


@pytest.mark.parametrize("path,body", [
    ("images/generations", {"model": IMAGE, "prompt": "x", "n": 2}),
    ("images/generations", {"model": IMAGE, "prompt": "x", "n": 10}),
    ("images/generations", {"model": IMAGE, "prompt": "x", "n": 0}),
    ("images/generations", {"model": IMAGE, "prompt": "x", "n": True}),  # True == 1 in Python: still refused
    ("images/generations", {"model": IMAGE, "prompt": "x", "n": 1.0}),
    ("images/generations", {"model": IMAGE, "prompt": "x", "n": "1"}),
    ("images/generations", {"model": IMAGE, "prompt": "x", "n": None}),
    ("responses", story_body(service_tier="priority")),
    ("responses", story_body(service_tier="flex")),
    ("responses", story_body(service_tier=None)),
    ("responses", story_body(service_tier=1)),
    ("audio/speech", {"model": SPEECH, "input": "Hei", "service_tier": "priority"}),
    ("images/generations", {"model": IMAGE, "prompt": "x", "service_tier": "scale"}),
    ("responses", story_body(max_output_tokens=16001)),  # MAX_OUTPUT_TOKENS_STORY=16000 + 1
    ("responses", story_body(max_output_tokens=10**12)),
    ("responses", story_body(max_output_tokens=1e9)),
    ("responses", story_body(max_output_tokens=100.5)),
    ("responses", story_body(max_output_tokens="100")),
    ("responses", story_body(max_output_tokens=True)),
])
def test_costly_options_refused_400(client, state, upstream, path, body):
    r = client.post(f"/v1/{path}", json=body, headers=auth())
    assert r.status_code == 400
    assert error_of(r) == "bad_request"
    assert_allowance(r, FREE_80)
    assert upstream.requests == []
    assert today(state)["refused"] == 1 and today(state)["requests"] == 1
    assert calls(state) == []


@pytest.mark.parametrize("path,body", [
    ("images/generations", {"model": IMAGE, "prompt": "x", "n": 1}),
    ("responses", story_body(service_tier="auto")),
    ("responses", story_body(service_tier="default")),
    ("audio/speech", {"model": SPEECH, "input": "Hei", "service_tier": "default"}),
    ("images/generations", {"model": IMAGE, "prompt": "x", "service_tier": "auto"}),
    ("responses", story_body(max_output_tokens=16000)),  # exactly MAX_OUTPUT_TOKENS_STORY
    ("responses", story_body(max_output_tokens=1)),
    ("responses", story_body(max_output_tokens=None)),
])
def test_allowed_values_of_costly_options_pass(client, upstream, path, body):
    upstream.respond = lambda req: httpx.Response(200, json={})
    r = client.post(f"/v1/{path}", json=body, headers=auth())
    assert r.status_code == 200
    assert upstream.json_body() == ({**body, "store": False} if path == "responses" else body)


def test_max_output_tokens_limit_is_the_setting(make_proxy, upstream):
    state = make_proxy(MAX_OUTPUT_TOKENS_STORY="500")
    with TestClient(create_app(state), client=("127.0.0.1", 50000)) as c:
        assert c.post("/v1/responses", json=story_body(max_output_tokens=500), headers=auth()).status_code == 200
        r = c.post("/v1/responses", json=story_body(max_output_tokens=501), headers=auth())
    assert r.status_code == 400 and error_of(r) == "bad_request"
    assert len(upstream.requests) == 1


def test_upstream_cookie_never_stored_or_sent_back(client, state, upstream):
    upstream.respond = lambda req: httpx.Response(
        200, json=story_ok(),
        headers={"set-cookie": "__cf_bm=abc; Path=/; Domain=api.openai.com; Secure; HttpOnly"})
    client.post("/v1/responses", json=story_body(), headers=auth())
    client.post("/v1/responses", json=story_body(stream=False), headers=auth())
    upstream.respond = lambda req: sse_response(STREAM_PARTS)
    client.post("/v1/responses", json=story_body(stream=True), headers=auth())
    assert len(upstream.requests) == 3
    for req in upstream.requests:
        assert "cookie" not in req.headers
    assert len(state.upstream.cookies.jar) == 0


def test_default_upstream_client_keeps_no_cookies():
    import asyncio

    seen: list[httpx.Request] = []

    def handler(req):
        seen.append(req)
        return httpx.Response(200, headers={"set-cookie": "__cf_bm=abc; Path=/"})

    async def run():
        client = upstream_client(httpx.MockTransport(handler))
        await client.get("https://api.openai.com/v1/x")
        await client.get("https://api.openai.com/v1/x")  # even through build_request, nothing to send
        await client.aclose()
        return client
    client = asyncio.run(run())
    assert "cookie" not in seen[1].headers
    assert len(client.cookies.jar) == 0


# --- non-streaming answers ---------------------------------------------------------------------------------

def test_story_200_kept_cost_and_headers(client, state, upstream):
    upstream.respond = lambda req: httpx.Response(
        200, json=story_ok(),
        headers={"set-cookie": "s=1", "openai-organization": "org-1", "x-request-id": "req_1",
                 "openai-processing-ms": "5"},
    )
    r = client.post("/v1/responses", json=story_body(), headers=auth())
    assert r.status_code == 200
    assert r.json() == story_ok()
    assert r.headers["content-type"] == "application/json"
    assert_allowance(r, FREE_79)
    for name in ("set-cookie", "openai-organization", "x-request-id", "openai-processing-ms"):
        assert name not in r.headers
    [row] = calls(state)
    assert row["kept"] == 1 and row["status"] == 200 and row["kind"] == "story"
    assert row["model"] == STORY  # the requested model, not upstream's dated id
    assert (row["tokens_in"], row["tokens_cached"], row["tokens_out"]) == (1000, 200, 500)
    assert row["cost_micro"] == STORY_COST
    assert row["paid_with"] == "free"
    assert today(state)["used_story"] == 1


def test_image_200_cost(client, state, upstream):
    usage = {"input_tokens": 100, "output_tokens": 200}
    upstream.respond = lambda req: httpx.Response(200, json={"data": [{"b64_json": "AAAA"}], "usage": usage})
    r = client.post("/v1/images/generations", json={"model": IMAGE, "prompt": "x"}, headers=auth())
    assert r.status_code == 200
    assert_allowance(r, "story=80,speech=80,image=3")
    [row] = calls(state)
    # PRICE_GPT_IMAGE_2_5_FLARE=5.00,1.25,40.00: 100*5.00 + 200*40.00 = 500 + 8000 = 8500 µUSD
    assert row["cost_micro"] == 8500 and row["kept"] == 1 and row["kind"] == "image"


def test_speech_200_counts_characters(client, state, upstream):
    upstream.respond = lambda req: httpx.Response(200, headers={"content-type": "audio/mpeg"}, content=b"\x00mp3")
    r = client.post("/v1/audio/speech", json={"model": SPEECH, "input": "Hei på deg", "voice": "alloy"},
                    headers=auth())
    assert r.status_code == 200
    assert r.content == b"\x00mp3"
    assert r.headers["content-type"] == "audio/mpeg"
    assert_allowance(r, "story=80,speech=79,image=4")
    [row] = calls(state)
    # len("Hei på deg") = 10 characters (å is one); PRICE_SPEECH_GPT_4O_MINI_TTS=15.00: 10*15.00 = 150 µUSD
    assert row["speech_chars"] == 10
    assert row["cost_micro"] == 150
    assert today(state)["speech_chars"] == 10


def test_speech_input_not_a_string_counts_zero(client, state, upstream):
    upstream.respond = lambda req: httpx.Response(400, json={"error": {"message": "bad input"}})
    r = client.post("/v1/audio/speech", json={"model": SPEECH, "input": ["x"]}, headers=auth())
    assert r.status_code == 400
    [row] = calls(state)
    assert row["speech_chars"] == 0 and row["kept"] == 0


@pytest.mark.parametrize("status", [500, 503, 400, 404, 409, 422])
def test_upstream_error_passed_on_unit_returned(client, state, upstream, status):
    body = {"error": {"message": f"upstream said {status}"}}
    upstream.respond = lambda req: httpx.Response(status, json=body)
    r = client.post("/v1/responses", json=story_body(), headers=auth())
    assert r.status_code == status
    assert r.json() == body
    assert_allowance(r, FREE_80)
    [row] = calls(state)
    assert row["kept"] == 0 and row["status"] == status
    assert today(state)["used_story"] == 0


UPSTREAM_SECRET = "sk-proj-upstream-detail-xyz"  # stands for whatever text OpenAI puts in its error


def upstream_error(status: int, code: str | None = None, type_: str | None = None) -> httpx.Response:
    error = {"message": f"Incorrect API key provided: {UPSTREAM_SECRET}", "code": code, "type": type_}
    return httpx.Response(status, json={"error": error}, headers={"x-request-id": "req_upstream"})


ERROR_MAPPINGS = [
    # (upstream status, error code, error type) -> (our status, our code)
    ((401, "invalid_api_key", "invalid_request_error"), (502, "upstream_unreachable")),
    ((403, "unsupported_country_region_territory", "request_forbidden"), (502, "upstream_unreachable")),
    ((429, "insufficient_quota", "insufficient_quota"), (503, "server_budget")),
    ((429, "insufficient_quota", None), (503, "server_budget")),
    ((429, None, "insufficient_quota"), (503, "server_budget")),
    ((429, "rate_limit_exceeded", "requests"), (429, "rate_limited")),
    ((429, None, None), (429, "rate_limited")),
]


@pytest.mark.parametrize("stream", [False, True])
@pytest.mark.parametrize("upstream_answer,ours", ERROR_MAPPINGS)
def test_upstream_auth_and_429_errors_mapped_to_our_codes(client, state, upstream, stream, upstream_answer, ours):
    status, code, type_ = upstream_answer
    upstream.respond = lambda req: upstream_error(status, code, type_)
    r = client.post("/v1/responses", json=story_body(stream=stream), headers=auth())
    assert r.status_code == ours[0]
    assert error_of(r) == ours[1]
    assert UPSTREAM_SECRET not in r.text and "Incorrect API key" not in r.text
    assert "x-request-id" not in r.headers
    assert r.headers["content-type"] == "application/json"
    assert_allowance(r, FREE_80)  # the unit went back
    [row] = calls(state)
    assert row["kept"] == 0 and row["status"] == status  # the real upstream status is logged
    assert today(state)["used_story"] == 0


def test_upstream_429_with_a_body_that_is_not_json_is_rate_limited(client, state, upstream):
    upstream.respond = lambda req: httpx.Response(429, content=b"<html>Too Many " + UPSTREAM_SECRET.encode())
    r = client.post("/v1/responses", json=story_body(), headers=auth())
    assert r.status_code == 429 and error_of(r) == "rate_limited"
    assert UPSTREAM_SECRET not in r.text
    [row] = calls(state)
    assert row["kept"] == 0 and row["status"] == 429


@pytest.mark.parametrize("path,body", [
    ("audio/speech", {"model": SPEECH, "input": "Hei"}),
    ("images/generations", {"model": IMAGE, "prompt": "x"}),
])
def test_upstream_401_on_speech_and_image_mapped(client, state, upstream, path, body):
    upstream.respond = lambda req: upstream_error(401, "invalid_api_key")
    r = client.post(f"/v1/{path}", json=body, headers=auth())
    assert r.status_code == 502 and error_of(r) == "upstream_unreachable"
    assert UPSTREAM_SECRET not in r.text
    [row] = calls(state)
    assert row["kept"] == 0 and row["status"] == 401


def test_upstream_error_returns_credits(make_proxy, upstream):
    state = make_proxy(QUOTA_STORY_PER_DAY="0")
    conn = db.connect(state.db_path)
    ledger.grant(conn, 1, 3, "test", NOW)
    conn.close()
    upstream.respond = lambda req: httpx.Response(500, json={})
    with TestClient(create_app(state), client=("127.0.0.1", 50000)) as c:
        r = c.post("/v1/responses", json=story_body(), headers=auth())
    assert r.status_code == 500
    assert_allowance(r, "story=0,speech=80,image=4", credits=3)
    reasons = [e["reason"] for e in query(state, "SELECT reason FROM ledger ORDER BY id")]
    assert reasons == ["grant", "debit", "refund"]


@pytest.mark.parametrize("exc", [
    httpx.ConnectTimeout("t"), httpx.ConnectError("refused"), httpx.ReadTimeout("t"), httpx.RemoteProtocolError("x"),
])
def test_upstream_unreachable_502_unit_returned(client, state, upstream, exc):
    def boom(req):
        raise exc
    upstream.respond = boom
    r = client.post("/v1/responses", json=story_body(), headers=auth())
    assert r.status_code == 502
    assert error_of(r) == "upstream_unreachable"
    assert_allowance(r, FREE_80)
    [row] = calls(state)
    assert row["kept"] == 0 and row["status"] == 502
    assert today(state)["used_story"] == 0


def test_upstream_unreachable_on_stream_502(client, state, upstream):
    def boom(req):
        raise httpx.ConnectTimeout("t")
    upstream.respond = boom
    r = client.post("/v1/responses", json=story_body(stream=True), headers=auth())
    assert r.status_code == 502 and error_of(r) == "upstream_unreachable"
    assert_allowance(r, FREE_80)
    [row] = calls(state)
    assert row["kept"] == 0 and row["status"] == 502


def test_upstream_total_timeout_502(make_proxy, upstream):
    state = make_proxy(UPSTREAM_TIMEOUT_SECONDS="1")

    async def stall(req):
        await anyio.sleep(30)
    upstream.respond = stall
    with TestClient(create_app(state), client=("127.0.0.1", 50000)) as c:
        r = c.post("/v1/responses", json=story_body(), headers=auth())
    assert r.status_code == 502 and error_of(r) == "upstream_unreachable"
    [row] = calls(state)
    assert row["kept"] == 0 and row["status"] == 502


def test_reload_between_admit_and_settle_uses_the_admit_snapshot(client, state, upstream):
    def reload_mid_call(req):
        state.settings = parse_settings(env_dict(PRICE_GPT_5_MINI="1.00,1.00,1.00", QUOTA_STORY_PER_DAY="10"))
        return httpx.Response(200, json=story_ok())
    upstream.respond = reload_mid_call
    r = client.post("/v1/responses", json=story_body(), headers=auth())
    assert r.status_code == 200
    [row] = calls(state)
    assert row["cost_micro"] == STORY_COST  # not 1500 from the reloaded price


# --- streaming ---------------------------------------------------------------------------------------------

STREAM_PARTS = [sse_delta("Det "), sse_delta("var "), sse_delta("en gang"), sse_completed()]


def test_stream_with_final_event_bytes_identical_and_kept(client, state, upstream):
    upstream.respond = lambda req: sse_response(STREAM_PARTS)
    r = client.post("/v1/responses", json=story_body(stream=True), headers=auth())
    assert r.status_code == 200
    assert r.content == b"".join(STREAM_PARTS)
    assert r.headers["content-type"].startswith("text/event-stream")
    assert_allowance(r, FREE_79)  # admit's values: the headers leave before the body
    assert upstream.requests[0].headers["accept"] == "text/event-stream"
    assert set(upstream.requests[0].headers.keys()) == {
        "host", "content-length", "authorization", "content-type", "user-agent", "accept-encoding", "accept"}
    assert upstream.json_body()["stream"] is True and upstream.json_body()["store"] is False
    [row] = calls(state)
    assert row["kept"] == 1 and row["status"] == 200
    assert row["cost_micro"] == STORY_COST
    assert (row["tokens_in"], row["tokens_cached"], row["tokens_out"]) == (1000, 200, 500)
    assert today(state)["used_story"] == 1


def test_stream_completed_event_split_across_chunks(client, state, upstream):
    whole = b"".join(STREAM_PARTS).replace(b"\n", b"\r\n")
    parts = [whole[i:i + 17] for i in range(0, len(whole), 17)]
    upstream.respond = lambda req: sse_response(parts)
    r = client.post("/v1/responses", json=story_body(stream=True), headers=auth())
    assert r.content == whole
    [row] = calls(state)
    assert row["kept"] == 1 and row["cost_micro"] == STORY_COST


def test_stream_without_final_event_unit_returned(client, state, upstream):
    parts = STREAM_PARTS[:-1]
    upstream.respond = lambda req: sse_response(parts)
    r = client.post("/v1/responses", json=story_body(stream=True), headers=auth())
    assert r.status_code == 200
    assert r.content == b"".join(parts)
    [row] = calls(state)
    assert row["kept"] == 0
    assert today(state)["used_story"] == 0


@pytest.mark.parametrize("name", ["response.failed", "response.incomplete"])
def test_stream_with_failed_event_unit_returned(client, state, upstream, name):
    final = sse_event(name, {"type": name, "response": {"usage": USAGE}})
    upstream.respond = lambda req: sse_response([sse_delta("a"), final])
    r = client.post("/v1/responses", json=story_body(stream=True), headers=auth())
    assert r.status_code == 200
    [row] = calls(state)
    assert row["kept"] == 0
    assert today(state)["used_story"] == 0
    # The tokens were spent even though the story failed / was cut off, so they are recorded:
    # (1000-200)*0.25 + 200*0.025 + 500*2.00 = 200 + 5 + 1000 = 1205 µUSD
    assert (row["tokens_in"], row["tokens_cached"], row["tokens_out"]) == (1000, 200, 500)
    assert row["cost_micro"] == STORY_COST
    day = today(state)
    assert (day["tokens_in"], day["tokens_out"], day["cost_micro"]) == (1000, 500, STORY_COST)
    assert query(state, "SELECT cost_micro FROM server_days WHERE day=?", (DAY,))[0][0] == STORY_COST


def test_stream_upstream_breaks_mid_stream_unit_returned_once(client, state, upstream):
    async def broken():
        yield sse_delta("Det ")
        raise httpx.ReadError("connection reset")
    upstream.respond = lambda req: httpx.Response(200, headers={"content-type": "text/event-stream"},
                                                  content=broken())
    r = client.post("/v1/responses", json=story_body(stream=True), headers=auth())
    assert r.status_code == 200
    assert r.content == sse_delta("Det ")
    [row] = calls(state)
    assert row["kept"] == 0
    assert today(state)["used_story"] == 0


def test_stream_upstream_non_2xx_answered_like_non_streaming(client, state, upstream):
    body = {"error": {"message": "bad request upstream"}}
    upstream.respond = lambda req: httpx.Response(400, json=body)
    r = client.post("/v1/responses", json=story_body(stream=True), headers=auth())
    assert r.status_code == 400
    assert r.json() == body
    assert r.headers["content-type"] == "application/json"
    assert_allowance(r, FREE_80)
    [row] = calls(state)
    assert row["kept"] == 0 and row["status"] == 400


def test_stream_gzip_from_upstream_reaches_client_decoded(client, state, upstream):
    whole = b"".join(STREAM_PARTS)
    upstream.respond = lambda req: httpx.Response(
        200, headers={"content-type": "text/event-stream", "content-encoding": "gzip"},
        content=chunks_of([gzip.compress(whole)]))
    r = client.post("/v1/responses", json=story_body(stream=True), headers=auth())
    assert r.content == whole
    assert "content-encoding" not in r.headers
    [row] = calls(state)
    assert row["kept"] == 1


def test_stream_total_timeout_ends_stream_unit_returned(make_proxy, upstream):
    state = make_proxy(UPSTREAM_TIMEOUT_SECONDS="1")

    async def stalled():
        yield sse_delta("Det ")
        await anyio.sleep(30)
        yield sse_completed()
    upstream.respond = lambda req: httpx.Response(200, headers={"content-type": "text/event-stream"},
                                                  content=stalled())
    with TestClient(create_app(state), client=("127.0.0.1", 50000)) as c:
        r = c.post("/v1/responses", json=story_body(stream=True), headers=auth())
    assert r.content == sse_delta("Det ")
    [row] = calls(state)
    assert row["kept"] == 0
    assert today(state)["used_story"] == 0


def test_stream_false_is_not_streamed(client, upstream):
    client.post("/v1/responses", json=story_body(stream=False), headers=auth())
    assert "text/event-stream" not in upstream.requests[0].headers.get("accept", "")


# --- client disconnect mid-stream (Review Focus 1) ---------------------------------------------------------

async def _drive_disconnect(state: State, mode: str) -> tuple[list[dict], list[sqlite3.Row]]:
    """Run one streamed story through the ASGI app; the client goes away early. Modes:
    "2.4": the client takes the first body chunk, the next `send` raises OSError;
    "2.3": the client takes the first body chunk, then `receive` answers http.disconnect (uvicorn);
    "start": the client is gone before the head: `send` of http.response.start raises OSError.
    Returns what was sent and the calls rows once one exists (the pump settles in the background).
    """
    app = create_app(state)
    body = json.dumps(story_body(stream=True)).encode()
    pending = [{"type": "http.request", "body": body, "more_body": False}]
    got_chunk = anyio.Event()
    sent: list[dict] = []

    async def receive():
        if pending:
            return pending.pop(0)
        await got_chunk.wait()
        return {"type": "http.disconnect"}

    async def send(message):
        if mode == "start" or (mode == "2.4" and message["type"] == "http.response.body" and got_chunk.is_set()):
            raise OSError("client went away")
        sent.append(message)
        if message["type"] == "http.response.body" and message.get("body"):
            got_chunk.set()

    scope = {
        "type": "http", "asgi": {"version": "3.0", "spec_version": "2.4" if mode == "2.4" else "2.3"},
        "http_version": "1.1", "method": "POST", "scheme": "http", "path": "/v1/responses",
        "raw_path": b"/v1/responses", "query_string": b"", "root_path": "", "client": ("127.0.0.1", 50000),
        "server": ("testserver", 80),
        "headers": [(b"host", b"testserver"), (b"authorization", f"Bearer {TOKEN}".encode()),
                    (b"content-type", b"application/json"), (b"content-length", str(len(body)).encode())],
        "state": {},
    }
    with anyio.fail_after(5):
        try:
            await app(scope, receive, send)
        except (ClientDisconnect, OSError):
            pass
        while not (settled := calls(state)):
            await anyio.sleep(0.01)
    await anyio.sleep(0.1)  # a second settlement, if there were one, would land now
    assert len(calls(state)) == 1
    await state.aclose()
    return sent, settled


def _rest_after_disconnect(req):
    """Two deltas, then (after the client left) the final event with USAGE."""
    async def parts():
        yield sse_delta("Det ")
        await anyio.sleep(0.05)
        yield sse_delta("var ")
        await anyio.sleep(0.05)
        yield sse_completed()
    return httpx.Response(200, headers={"content-type": "text/event-stream"}, content=parts())


def _ends_without_final_event(req):
    """Two deltas, then (after the client left) the stream ends with no terminal event."""
    async def parts():
        yield sse_delta("Det ")
        await anyio.sleep(0.05)
        yield sse_delta("var ")
        await anyio.sleep(0.05)
    return httpx.Response(200, headers={"content-type": "text/event-stream"}, content=parts())


def _stalling_stream(req):
    async def parts():
        yield sse_delta("Det ")
        yield sse_delta("var ")
        await anyio.sleep_forever()
        yield sse_completed()
    return httpx.Response(200, headers={"content-type": "text/event-stream"}, content=parts())


@pytest.mark.parametrize("mode", ["2.4", "2.3", "start"])
def test_stream_client_disconnect_upstream_completes_unit_kept_once(make_proxy, upstream, mode):
    state = make_proxy()
    upstream.respond = _rest_after_disconnect
    sent, settled = anyio.run(_drive_disconnect, state, mode)
    if mode != "start":
        assert sent[0]["type"] == "http.response.start" and sent[0]["status"] == 200
        assert sent[1]["body"] == sse_delta("Det ")
    [row] = settled
    # The pump read on to response.completed: OpenAI answered in full, so the unit is kept (spec 6: the unit
    # is returned only for a stream that ends without its final event), settled exactly once.
    assert row["kept"] == 1
    assert today(state)["used_story"] == 1
    # (1000-200)*0.25 + 200*0.025 + 500*2.00 = 200 + 5 + 1000 = 1205 µUSD
    assert (row["tokens_in"], row["tokens_cached"], row["tokens_out"]) == (1000, 200, 500)
    assert row["cost_micro"] == STORY_COST
    day = today(state)
    assert (day["tokens_in"], day["tokens_out"], day["cost_micro"]) == (1000, 500, STORY_COST)
    assert query(state, "SELECT cost_micro FROM server_days WHERE day=?", (DAY,))[0][0] == STORY_COST


@pytest.mark.parametrize("mode", ["2.4", "2.3", "start"])
def test_stream_client_disconnect_before_completed_returns_unit_once(make_proxy, upstream, mode):
    state = make_proxy()
    upstream.respond = _ends_without_final_event
    _, settled = anyio.run(_drive_disconnect, state, mode)
    [row] = settled
    # No response.completed ever came: the unit goes back exactly once, never below 0.
    assert row["kept"] == 0 and row["cost_micro"] == 0
    assert today(state)["used_story"] == 0


def test_client_leaves_right_after_receiving_completed_keeps_the_unit(make_proxy, upstream):
    """The client takes the whole stream (completed included), then goes away before the stream's end."""
    state = make_proxy()

    def completed_then_more(req):
        async def parts():
            for p in STREAM_PARTS:
                yield p
            await anyio.sleep(0.05)  # the client is gone by now: it left after completed arrived
            yield b": trailing comment\n\n"
            await anyio.sleep(0.05)  # the send of the trailing chunk fails meanwhile: the client is gone
        return httpx.Response(200, headers={"content-type": "text/event-stream"}, content=parts())
    upstream.respond = completed_then_more

    async def run():
        app = create_app(state)
        body = json.dumps(story_body(stream=True)).encode()
        pending = [{"type": "http.request", "body": body, "more_body": False}]
        received = bytearray()

        async def receive():
            if pending:
                return pending.pop(0)
            await anyio.sleep_forever()

        async def send(message):
            if message["type"] == "http.response.body":
                if b"response.completed" in bytes(received):
                    raise OSError("client went away")  # everything up to completed arrived; then it left
                received.extend(message.get("body", b""))

        scope = {
            "type": "http", "asgi": {"version": "3.0", "spec_version": "2.4"}, "http_version": "1.1",
            "method": "POST", "scheme": "http", "path": "/v1/responses", "raw_path": b"/v1/responses",
            "query_string": b"", "root_path": "", "client": ("127.0.0.1", 50000), "server": ("testserver", 80),
            "headers": [(b"host", b"testserver"), (b"authorization", f"Bearer {TOKEN}".encode()),
                        (b"content-type", b"application/json"), (b"content-length", str(len(body)).encode())],
            "state": {},
        }
        with anyio.fail_after(5):
            try:
                await app(scope, receive, send)
            except (ClientDisconnect, OSError):
                pass
            while not calls(state):
                await anyio.sleep(0.01)
        await anyio.sleep(0.1)
        await state.aclose()
        return bytes(received)

    received = anyio.run(run)
    assert received == b"".join(STREAM_PARTS)
    [row] = calls(state)
    assert row["kept"] == 1 and row["cost_micro"] == STORY_COST
    assert today(state)["used_story"] == 1


@pytest.mark.parametrize("mode", ["2.4", "2.3"])
def test_stream_client_disconnect_drain_bounded_by_the_deadline(make_proxy, upstream, mode):
    state = make_proxy(UPSTREAM_TIMEOUT_SECONDS="1")
    upstream.respond = _stalling_stream
    _, settled = anyio.run(_drive_disconnect, state, mode)
    [row] = settled
    assert row["kept"] == 0 and row["cost_micro"] == 0
    assert today(state)["used_story"] == 0


@pytest.mark.parametrize("mode", ["2.4", "2.3"])
def test_stream_client_disconnect_refunds_credits_once(make_proxy, upstream, mode):
    state = make_proxy(QUOTA_STORY_PER_DAY="0")
    conn = db.connect(state.db_path)
    ledger.grant(conn, 1, 2, "test", NOW)
    conn.close()
    upstream.respond = _ends_without_final_event
    _, settled = anyio.run(_drive_disconnect, state, mode)
    [row] = settled
    assert row["kept"] == 0 and row["paid_with"] == "credits"
    reasons = [e["reason"] for e in query(state, "SELECT reason FROM ledger ORDER BY id")]
    assert reasons == ["grant", "debit", "refund"]
    conn = db.connect(state.db_path)
    assert ledger.balance(conn, 1) == 2
    conn.close()


@pytest.mark.parametrize("mode", ["2.4", "2.3"])
def test_stream_client_disconnect_upstream_completes_credits_kept(make_proxy, upstream, mode):
    state = make_proxy(QUOTA_STORY_PER_DAY="0")
    conn = db.connect(state.db_path)
    ledger.grant(conn, 1, 2, "test", NOW)
    conn.close()
    upstream.respond = _rest_after_disconnect
    _, settled = anyio.run(_drive_disconnect, state, mode)
    [row] = settled
    assert row["kept"] == 1 and row["paid_with"] == "credits"
    reasons = [e["reason"] for e in query(state, "SELECT reason FROM ledger ORDER BY id")]
    assert reasons == ["grant", "debit"]
    conn = db.connect(state.db_path)
    # 2 granted - 1 debited (CREDITS_PER_STORY=1), no refund = 1
    assert ledger.balance(conn, 1) == 1
    conn.close()


# --- quota, caps, rate (acceptance 3, 5) -------------------------------------------------------------------

def test_81st_story_429_daily_quota(client, state, upstream, mono):
    for i in range(80):
        mono.advance(5)  # 12 per minute stays under RATE_PER_MINUTE=15
        r = client.post("/v1/responses", json=story_body(), headers=auth())
        assert r.status_code == 200, (i, r.text)
    assert_allowance(r, "story=0,speech=80,image=4")
    mono.advance(5)
    r = client.post("/v1/responses", json=story_body(), headers=auth())
    assert r.status_code == 429
    assert error_of(r) == "daily_quota"
    assert_allowance(r, "story=0,speech=80,image=4")
    assert len(upstream.requests) == 80
    assert len(calls(state)) == 80


def test_server_spend_cap_503(make_proxy, upstream):
    # DAILY_SPEND_CAP_USD=0.001205 is 1205 µUSD, the cost of one story with USAGE: after it, 1205 >= 1205.
    state = make_proxy(DAILY_SPEND_CAP_USD="0.001205")
    with TestClient(create_app(state), client=("127.0.0.1", 50000)) as c:
        assert c.post("/v1/responses", json=story_body(), headers=auth()).status_code == 200
        r = c.post("/v1/responses", json=story_body(), headers=auth())
    assert r.status_code == 503
    assert error_of(r) == "server_budget"
    assert_allowance(r, FREE_79)
    assert len(upstream.requests) == 1


def test_16th_request_in_a_minute_429_rate_limited(client, state, upstream, mono):
    for _ in range(15):
        assert client.post("/v1/responses", json=story_body(), headers=auth()).status_code == 200
    r = client.post("/v1/responses", json=story_body(), headers=auth())
    assert r.status_code == 429
    assert error_of(r) == "rate_limited"
    assert_allowance(r, "story=65,speech=80,image=4")
    assert len(upstream.requests) == 15
    assert today(state)["refused"] == 1
    mono.advance(61)
    assert client.post("/v1/responses", json=story_body(), headers=auth()).status_code == 200


def test_404s_count_toward_the_rate(client, upstream):
    for _ in range(15):
        assert client.post("/v1/models", json={}, headers=auth()).status_code == 404
    r = client.post("/v1/responses", json=story_body(), headers=auth())
    assert r.status_code == 429 and error_of(r) == "rate_limited"
    assert upstream.requests == []


# --- calls in flight per device (MAX_INFLIGHT_PER_DEVICE) -------------------------------------------------

async def _concurrent_calls(state: State, upstream: Upstream, body: dict) -> dict:
    """Hold 3 upstream calls open, send a 4th, then let the 3 finish and send a 5th."""
    release = anyio.Event()
    started = anyio.Event()

    async def held(req):
        if len(upstream.requests) == 3:
            started.set()
        await release.wait()
        return httpx.Response(200, json=story_ok()) if not body.get("stream") else sse_response(STREAM_PARTS)
    upstream.respond = held
    app = create_app(state)
    results: dict = {"first": []}
    transport = httpx.ASGITransport(app=app, client=("127.0.0.1", 50000))
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as c:
        async def one():
            r = await c.post("/v1/responses", json=body, headers=auth())
            results["first"].append(r.status_code)
        with anyio.fail_after(5):
            async with anyio.create_task_group() as tg:
                for _ in range(3):
                    tg.start_soon(one)
                await started.wait()
                results["in_flight"] = state.inflight.count(1)
                results["fourth"] = await c.post("/v1/responses", json=body, headers=auth())
                release.set()
            while state.inflight.count(1):  # a streamed call settles in its pump, just after the body
                await anyio.sleep(0.01)
            results["after"] = state.inflight.count(1)
            results["fifth"] = await c.post("/v1/responses", json=body, headers=auth())
            while state.inflight.count(1):
                await anyio.sleep(0.01)
    await state.aclose()
    return results


@pytest.mark.parametrize("stream", [False, True])
def test_fourth_concurrent_call_refused_and_slot_freed_after_settle(make_proxy, upstream, stream):
    state = make_proxy()
    res = anyio.run(_concurrent_calls, state, upstream, story_body(stream=stream))
    assert res["in_flight"] == 3
    r = res["fourth"]
    assert r.status_code == 429 and error_of(r) == "rate_limited"
    assert_allowance(r, "story=77,speech=80,image=4")  # 80 free - 3 reserved by the calls in flight
    assert sorted(res["first"]) == [200, 200, 200]
    assert res["after"] == 0
    assert res["fifth"].status_code == 200
    assert state.inflight.count(1) == 0
    assert len(upstream.requests) == 4  # 3 + the 5th; the 4th never went upstream
    day = today(state)
    # requests: 3 + refused 4th + 5th = 5; refused: the 4th only
    assert (day["requests"], day["refused"], day["used_story"]) == (5, 1, 4)


def test_inflight_limit_one_is_a_setting(make_proxy, upstream):
    state = make_proxy(MAX_INFLIGHT_PER_DEVICE="1")
    state.inflight.acquire(1, 1)  # a call of this device is in flight
    with TestClient(create_app(state), client=("127.0.0.1", 50000)) as c:
        r = c.post("/v1/responses", json=story_body(), headers=auth())
    assert r.status_code == 429 and error_of(r) == "rate_limited"
    assert upstream.requests == [] and calls(state) == []
    assert today(state)["refused"] == 1


def test_slot_freed_after_refusals_and_failures_after_admit(make_proxy, upstream):
    state = make_proxy(QUOTA_STORY_PER_DAY="0")  # no free stories, no credits: admit refuses daily_quota
    with TestClient(create_app(state), client=("127.0.0.1", 50000)) as c:
        for _ in range(5):  # more than MAX_INFLIGHT_PER_DEVICE=3: a leaked slot would show as rate_limited
            r = c.post("/v1/responses", json=story_body(), headers=auth())
            assert r.status_code == 429 and error_of(r) == "daily_quota"
    assert state.inflight.count(1) == 0

    state = make_proxy()
    outcomes = [
        lambda req: (_ for _ in ()).throw(httpx.ConnectError("refused")),  # 502 unreachable
        lambda req: httpx.Response(500, json={}),
        lambda req: upstream_error(401, "invalid_api_key"),
        lambda req: httpx.Response(200, json=story_ok()),
        lambda req: sse_response(STREAM_PARTS[:-1]),  # stream without its final event
        lambda req: sse_response(STREAM_PARTS),
    ]
    with TestClient(create_app(state), client=("127.0.0.1", 50000)) as c:
        for i, answer in enumerate(outcomes):
            upstream.respond = answer
            c.post("/v1/responses", json=story_body(stream=i >= 4), headers=auth())
            assert state.inflight.count(1) == 0, i
    assert len(calls(state)) == len(outcomes)


@pytest.mark.parametrize("mode", ["2.4", "2.3", "start"])
def test_slot_freed_after_client_disconnect(make_proxy, upstream, mode):
    state = make_proxy()
    upstream.respond = _rest_after_disconnect
    anyio.run(_drive_disconnect, state, mode)
    assert state.inflight.count(1) == 0


# --- logging and privacy (acceptance 7) --------------------------------------------------------------------

@pytest.mark.parametrize("stream", [False, True])
def test_one_log_line_per_call(client, state, upstream, caplog, stream):
    caplog.set_level(logging.INFO)  # root: every logger that would print at the service's INFO level
    if stream:
        upstream.respond = lambda req: sse_response(STREAM_PARTS)
    caplog.clear()
    r = client.post("/v1/responses", json=story_body(stream=stream), headers=auth())
    assert r.status_code == 200
    lines = [rec for rec in caplog.records if rec.levelno >= logging.INFO]
    assert len(lines) == 1, [(rec.name, rec.getMessage()) for rec in lines]
    assert lines[0].name == "myguide.proxy"
    msg = lines[0].getMessage()
    [row] = calls(state)
    for part in (row["call_id"], "kind=story", f"model={STORY}", "status=200", "kept=1", "latency_ms="):
        assert part in msg


SECRETS = ("Colosseum", "41.8902", "12.4922", "/9j/4AAQSkZJRgABAQAAAQABAAD", "203.0.113.7", TOKEN, "sk-test")


def test_nothing_personal_stored(client, state, upstream, caplog):
    caplog.set_level(logging.DEBUG)
    image = "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD" + "A" * 200
    body = story_body(input=[{"role": "user", "content": [
        {"type": "input_text", "text": "Tell me about the Colosseum near 41.8902, 12.4922"},
        {"type": "input_image", "image_url": image},
    ]}])
    headers = auth(**{"X-Forwarded-For": "203.0.113.7"})
    echo = story_ok(text="The Colosseum at 41.8902, 12.4922 ...")
    answers = [
        lambda req: httpx.Response(200, json=echo),
        lambda req: sse_response([sse_delta("The Colosseum at 41.8902"), sse_completed()]),
        lambda req: sse_response([sse_delta("The Colosseum at 41.8902")]),
        lambda req: httpx.Response(500, json={"error": {"message": "Colosseum 41.8902 failed"}}),
        lambda req: httpx.Response(400, json={"error": {"message": "bad image /9j/4AAQSkZJRgABAQAAAQABAAD"}}),
    ]
    for i, answer in enumerate(answers):
        upstream.respond = answer
        sent = dict(body, stream=i in (1, 2))
        client.post("/v1/responses", json=sent, headers=headers)
    upstream.respond = lambda req: (_ for _ in ()).throw(httpx.ConnectError("Colosseum 41.8902"))
    client.post("/v1/responses", json=body, headers=headers)
    client.post("/v1/responses", json=dict(body, model="gpt-4o"), headers=headers)
    client.post("/v1/audio/speech", json={"model": SPEECH, "input": "Colosseum 41.8902"}, headers=headers)
    assert len(calls(state)) == 7

    conn = sqlite3.connect(str(state.db_path))
    try:
        tables = [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")]
        assert {"calls", "device_days", "devices", "ledger", "server_days", "wallets"} <= set(tables)
        for table in tables:
            for row in conn.execute(f'SELECT * FROM "{table}"'):
                for value in row:
                    text = value.decode("utf-8", "replace") if isinstance(value, bytes) else str(value)
                    for secret in SECRETS:
                        assert secret not in text, (table, secret)
    finally:
        conn.close()
    assert caplog.records, "logging was not captured"
    for record in caplog.records:
        text = record.getMessage() + " " + repr(record.args) + " " + (record.exc_text or "")
        for secret in SECRETS:
            assert secret not in text, (record.name, secret)
