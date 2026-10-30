"""The OpenAI pass-through (spec 6, 6.2): allowlisted paths and models, `store` forced false, debit-first
admission, SSE passed through byte for byte, settlement exactly once, quota headers on every answer.

Order for a known path: authenticate -> per-minute rate -> path -> body size -> body JSON and model -> admit
-> forward -> settle. Every refusal after authentication is counted for the device and carries the
`X-MyGuide-Free-Left` / `X-MyGuide-Credits` headers.

Nothing personal leaves this module: no body, prompt, token or IP is stored or logged. One info line per
admitted call: call id, kind, model (an allowlisted name), status, latency, kept, and an error type if any.
"""
from __future__ import annotations

import asyncio
import json
import logging
import math
from collections.abc import AsyncIterator, Awaitable, Callable
from typing import Any

import anyio
import httpx
from starlette.requests import Request
from starlette.responses import Response, StreamingResponse
from starlette.routing import Route
from starlette.types import Receive, Scope, Send

from . import db, retention
from .app import HTTPError, authenticate, read_body
from .config import KINDS, Settings
from .limits import Admission, admit, allowance, count_refused, settle, utc_day
from .pricing import Usage, usage_from_json
from .sse import CompletedWatcher
from .state import State

log = logging.getLogger(__name__)

UPSTREAM_BASE = "https://api.openai.com/v1/"
USER_AGENT = "MyGuide-guide-server"
ROUTES = {"responses": "story", "audio/speech": "speech", "images/generations": "image"}

# Upstream failures that answer 502 `upstream_unreachable`. RequestError covers every TransportError
# (timeouts, refused connections, protocol errors) plus a body that cannot be decoded; TimeoutError is
# the whole-call deadline (UPSTREAM_TIMEOUT_SECONDS) from anyio.
_UNREACHABLE = (httpx.RequestError, TimeoutError)


def allowance_headers(free_left: dict[str, int], credits: int) -> dict[str, str]:
    return {
        "X-MyGuide-Free-Left": ",".join(f"{kind}={free_left[kind]}" for kind in KINDS),
        "X-MyGuide-Credits": str(credits),
    }


def _refuse(state: State, settings: Settings, device_id: int, status: int, code: str) -> HTTPError:
    """Count a refusal before admission and build its error with the allowance headers."""
    conn = db.connect(state.db_path)
    try:
        free_left, credits = count_refused(conn, settings, device_id, state.clock())
    finally:
        conn.close()
    return HTTPError(status, code, headers=allowance_headers(free_left, credits))


def _no_constants(name: str) -> Any:
    raise ValueError(f"{name} is not JSON")


def _parse(raw: bytes, kind: str, settings: Settings) -> tuple[dict, str, bytes] | str:
    """(body, model, payload to forward) or the refusal code. The body is re-serialized, so upstream gets
    exactly the object that was checked (a duplicate `model` key cannot smuggle a second model)."""
    try:
        body = json.loads(raw, parse_constant=_no_constants)
    except (ValueError, RecursionError):  # JSONDecodeError and UnicodeDecodeError are ValueErrors
        return "bad_request"
    if not isinstance(body, dict):
        return "bad_request"
    model = body.get("model")
    if not isinstance(model, str):
        return "bad_request"
    if model not in settings.models(kind):
        return "model_not_allowed"
    if kind in ("speech", "image") and body.get("stream") not in (None, False):
        return "bad_request"  # a streamed image or speech answer is not metered by this server
    if kind == "story" and (body.get("tools") not in (None, []) or body.get("background") not in (None, False)):
        return "bad_request"  # tools bill outside `usage`; a background call outlives its settlement
    if kind == "story":
        body["store"] = False
    try:
        payload = json.dumps(body, separators=(",", ":"), ensure_ascii=False).encode()
    except (ValueError, RecursionError):  # a lone surrogate cannot be encoded as UTF-8
        return "bad_request"
    return body, model, payload


def _usage(kind: str, body: dict, content: bytes, kept: bool) -> Usage:
    if kind == "speech":
        text = body.get("input")
        # Speech is priced per input character; a refused or failed call read nothing aloud.
        return Usage(speech_chars=len(text)) if kept and isinstance(text, str) else Usage()
    try:
        obj = json.loads(content)
    except (ValueError, RecursionError):
        return Usage()
    return usage_from_json(obj) if isinstance(obj, dict) else Usage()


def _response_headers(upstream: httpx.Response, allowance_h: dict[str, str]) -> dict[str, str]:
    """Only the upstream Content-Type goes back, plus our two headers: no cookies, ids or `openai-*`."""
    headers = dict(allowance_h)
    content_type = upstream.headers.get("content-type")
    if content_type is not None:
        headers["Content-Type"] = content_type
    return headers


class _Call:
    """One admitted call: settles exactly once, with the settings snapshot taken at admission."""

    def __init__(self, state: State, settings: Settings, admission: Admission, model: str) -> None:
        self.state = state
        self.settings = settings
        self.admission = admission
        self.model = model
        self.start = state.monotonic()
        self.settled = False

    def settle(self, *, kept: bool, status: int, usage: Usage, error: str | None = None) -> None:
        """Record the outcome; later calls are no-ops. Never raises: a failure is logged by type only."""
        if self.settled:
            return
        self.settled = True
        latency_ms = max(0, int((self.state.monotonic() - self.start) * 1000))
        try:
            conn = db.connect(self.state.db_path)
            try:
                settle(conn, self.settings, self.admission, kept=kept, status=status, model=self.model,
                       usage=usage, latency_ms=latency_ms, now=self.state.clock())
            finally:
                conn.close()
        except Exception as e:  # the client may already have bytes; only the type is safe to log
            log.error("call %s: settle failed: %s", self.admission.call_id, type(e).__name__)
        log.info("call %s kind=%s model=%s status=%d latency_ms=%d kept=%d%s", self.admission.call_id,
                 self.admission.kind, self.model, status, latency_ms, 1 if kept else 0,
                 f" error={error}" if error else "")

    def headers_after_settle(self) -> dict[str, str]:
        """The allowance now (after settle); admission's values if the database cannot be read."""
        a = self.admission
        try:
            conn = db.connect(self.state.db_path)
            try:
                free_left, credits = allowance(conn, self.settings, a.device_id, a.wallet_id,
                                               utc_day(self.state.clock()))
            finally:
                conn.close()
        except Exception as e:  # never turn a billed answer into a 500; only the type is logged
            log.error("call %s: allowance failed: %s", a.call_id, type(e).__name__)
            free_left, credits = a.free_left, a.credits
        return allowance_headers(free_left, credits)

    def unreachable(self, error: BaseException) -> HTTPError:
        self.settle(kept=False, status=502, usage=Usage(), error=type(error).__name__)
        return HTTPError(502, "upstream_unreachable", headers=self.headers_after_settle())


class _SettlingStreamingResponse(StreamingResponse):
    """A StreamingResponse whose `on_close` always runs once the response is over, however it ends.

    Starlette leaves the body generator suspended when the client goes away (ASGI 2.4: `send` raises
    OSError), cancels it (ASGI 2.3: `http.disconnect`), or never starts it when the head cannot be sent.
    `on_close` tells the upstream pump whether the client got the whole stream.
    """

    def __init__(self, content: AsyncIterator[bytes], *, on_close: Callable[[], Awaitable[None]],
                 status_code: int, headers: dict[str, str]) -> None:
        super().__init__(content, status_code=status_code, headers=headers)
        self._on_close = on_close

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        try:
            await super().__call__(scope, receive, send)
        finally:
            with anyio.CancelScope(shield=True):
                await self._on_close()


async def _close_quietly(closer: Callable[[], Awaitable[None]]) -> None:
    with anyio.CancelScope(shield=True):
        try:
            await closer()
        except Exception as e:
            log.debug("close failed: %s", type(e).__name__)


# Upstream pumps outlive their request when the client goes away; strong references keep them alive.
_pumps: set[asyncio.Task[None]] = set()


def _upstream_request(settings: Settings, url: str, payload: bytes, *, stream: bool) -> httpx.Request:
    """Exactly these headers go upstream (plus Host and Content-Length, which httpx derives from the
    request): built directly, not via `client.build_request`, so no client default and no cookie is added."""
    headers = {
        "Authorization": f"Bearer {settings.openai_api_key}",
        "Content-Type": "application/json",
        "User-Agent": USER_AGENT,
        # identity: the bytes passed on are the bytes OpenAI sent (aiter_bytes still decodes if it compresses)
        "Accept-Encoding": "identity",
    }
    if stream:
        headers["Accept"] = "text/event-stream"
    timeout = httpx.Timeout(settings.upstream_timeout_seconds)
    return httpx.Request("POST", url, content=payload, headers=headers, extensions={"timeout": timeout.as_dict()})


async def _forward_plain(state: State, call: _Call, kind: str, url: str, body: dict, payload: bytes) -> Response:
    timeout = call.settings.upstream_timeout_seconds
    request = _upstream_request(call.settings, url, payload, stream=False)
    try:
        with anyio.fail_after(timeout):
            upstream = await state.upstream.send(request)
    except _UNREACHABLE as e:
        raise call.unreachable(e) from None
    except BaseException as e:  # cancelled or unexpected: the unit must not stay reserved
        call.settle(kept=False, status=502, usage=Usage(), error=type(e).__name__)
        raise
    kept = 200 <= upstream.status_code < 300
    content = upstream.content
    call.settle(kept=kept, status=upstream.status_code, usage=_usage(kind, body, content, kept))
    return Response(content, status_code=upstream.status_code,
                    headers=_response_headers(upstream, call.headers_after_settle()))


async def _forward_stream(state: State, call: _Call, url: str, payload: bytes) -> Response:
    timeout = call.settings.upstream_timeout_seconds
    deadline = anyio.current_time() + timeout  # UPSTREAM_TIMEOUT_SECONDS bounds the whole call
    request = _upstream_request(call.settings, url, payload, stream=True)
    try:
        with anyio.fail_after(timeout):
            upstream = await state.upstream.send(request, stream=True)
    except _UNREACHABLE as e:
        raise call.unreachable(e) from None
    except BaseException as e:
        call.settle(kept=False, status=502, usage=Usage(), error=type(e).__name__)
        raise

    if not 200 <= upstream.status_code < 300:
        try:
            with anyio.CancelScope(deadline=deadline) as scope:
                content = await upstream.aread()
            if scope.cancelled_caught:
                raise TimeoutError
        except _UNREACHABLE as e:
            raise call.unreachable(e) from None
        except BaseException as e:
            call.settle(kept=False, status=502, usage=Usage(), error=type(e).__name__)
            raise
        finally:
            await _close_quietly(upstream.aclose)
        call.settle(kept=False, status=upstream.status_code, usage=_usage("story", {}, content, False))
        return Response(content, status_code=upstream.status_code,
                        headers=_response_headers(upstream, call.headers_after_settle()))

    # The upstream stream is read by its own task (the pump), not by the response: a client that goes away
    # cancels only the response, while the pump reads on to the end (or the deadline), so the usage of a
    # call the client abandoned is still counted. The pump alone settles, exactly once.
    watcher = CompletedWatcher()
    to_client, from_pump = anyio.create_memory_object_stream[bytes](max_buffer_size=math.inf)
    client_gone = False
    delivered_all = False

    async def pump() -> None:
        nonlocal client_gone
        error: str | None = None
        try:
            with anyio.CancelScope(deadline=deadline) as scope:
                # aiter_bytes: the raw bytes, decoded only if upstream compressed them anyway (then the
                # client gets them decoded, as Content-Encoding is not passed on, and the watcher can read them).
                async for chunk in upstream.aiter_bytes():
                    watcher.feed(chunk)
                    if not client_gone:
                        try:
                            to_client.send_nowait(chunk)
                        except (anyio.BrokenResourceError, anyio.ClosedResourceError):
                            client_gone = True
                watcher.close()
            if scope.cancelled_caught:
                error = "deadline"
        except Exception as e:  # upstream broke mid-stream (or worse): the stream ends, the unit goes back.
            error = type(e).__name__  # handled here, so no task traceback (which could quote data) is logged
        except BaseException as e:  # cancelled at shutdown: settle below, then let the cancellation go on
            error = type(e).__name__
            raise
        finally:
            # Settle before the client's stream is closed, so the call is recorded when the client has it all.
            kept = watcher.completed and not client_gone
            call.settle(kept=kept, status=upstream.status_code, usage=watcher.usage,
                        error=error or ("client_gone" if client_gone else None))
            to_client.close()
            await _close_quietly(upstream.aclose)

    task = asyncio.get_running_loop().create_task(pump())
    _pumps.add(task)
    task.add_done_callback(_pumps.discard)

    async def body() -> AsyncIterator[bytes]:
        nonlocal delivered_all
        async with from_pump:
            async for chunk in from_pump:
                yield chunk
        delivered_all = True

    stream = body()

    async def on_close() -> None:
        nonlocal client_gone
        await _close_quietly(stream.aclose)
        if not delivered_all:
            client_gone = True  # the pump drains on, without sending, and settles kept=False
        from_pump.close()

    a = call.admission
    return _SettlingStreamingResponse(
        stream, on_close=on_close, status_code=upstream.status_code,
        headers=_response_headers(upstream, allowance_headers(a.free_left, a.credits)),
    )


def routes(state: State) -> list[Route]:
    async def proxy(request: Request) -> Response:
        settings = state.settings  # one snapshot for admission and settlement, whatever a reload does
        retention.prune_if_new_day(state)  # no transaction is open here
        conn = db.connect(state.db_path)
        try:
            device = authenticate(request, conn)
        finally:
            conn.close()
        device_id = device["id"]
        if not state.rate_window.hit(device_id, state.monotonic()):
            raise _refuse(state, settings, device_id, 429, "rate_limited")
        path = request.path_params["path"]
        kind = ROUTES.get(path)
        if kind is None:
            raise _refuse(state, settings, device_id, 404, "not_found")
        try:
            raw = await read_body(request, settings.max_body_bytes)
        except HTTPError as e:
            raise _refuse(state, settings, device_id, e.status, e.code) from None
        parsed = _parse(raw, kind, settings)
        if isinstance(parsed, str):
            raise _refuse(state, settings, device_id, 400, parsed)
        body, model, payload = parsed

        conn = db.connect(state.db_path)
        try:
            admission = admit(conn, settings, device, kind, state.clock())
        finally:
            conn.close()
        if not admission.allowed:
            assert admission.code is not None
            raise HTTPError(admission.status, admission.code,
                            headers=allowance_headers(admission.free_left, admission.credits))

        call = _Call(state, settings, admission, model)
        url = UPSTREAM_BASE + path
        if kind == "story" and body.get("stream") is True:
            return await _forward_stream(state, call, url, payload)
        return await _forward_plain(state, call, kind, url, body, payload)

    return [Route("/v1/{path:path}", proxy, methods=["POST"])]
