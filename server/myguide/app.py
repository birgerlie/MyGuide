"""The guide service: health, App Attest challenge and attest -> bearer token, token authentication (spec 5).

The proxy routes (`proxy.py`, spec 6) are registered here and use `authenticate`, `read_body` and `HTTPError`.
Nothing here stores or logs a token, an IP address, a challenge or a request body.
"""
from __future__ import annotations

import base64
import binascii
import contextlib
import hashlib
import ipaddress
import json
import logging
import secrets
import sqlite3
from collections.abc import AsyncIterator

from starlette.applications import Starlette
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from . import db, retention
from .attest import AttestError, verify_attestation
from .state import State

log = logging.getLogger(__name__)

_LOOPBACK = ("127.0.0.1", "::1")
_NO_STORE = {"Cache-Control": "no-store"}

MESSAGES = {
    "attest_required": "Attest the app again.",
    "blocked": "This device is blocked.",
    "not_found": "Not found.",
    "model_not_allowed": "This model is not allowed.",
    "bad_request": "Bad request.",
    "body_too_large": "The request body is too large.",
    "rate_limited": "Too many requests. Try again later.",
    "daily_quota": "Today's free stories are used up. Try again tomorrow.",
    "server_budget": "The guide is taking a break right now. Try again later.",
    "upstream_unreachable": "OpenAI could not be reached.",
}


class HTTPError(Exception):
    """A refusal; the app's exception handler answers it with `json_error`."""

    def __init__(self, status: int, code: str, message: str | None = None,
                 headers: dict[str, str] | None = None) -> None:
        super().__init__(code)
        self.status = status
        self.code = code
        self.message = message if message is not None else MESSAGES.get(code, code)
        self.headers = headers


class Blocked(HTTPError):
    """403 `blocked` for a known device, which the proxy counts as a refusal of `device_id`."""

    def __init__(self, device_id: int) -> None:
        super().__init__(403, "blocked")
        self.device_id = device_id


def json_error(status: int, code: str, message: str, headers: dict[str, str] | None = None) -> JSONResponse:
    """`{"error":{"code":..., "message":...}}` with `status`."""
    return JSONResponse({"error": {"code": code, "message": message}}, status_code=status, headers=headers)


def quiet_http_client_logs() -> None:
    """httpx/httpcore log every request at INFO; the proxy writes its own single line per call."""
    for name in ("httpx", "httpcore"):
        logging.getLogger(name).setLevel(logging.WARNING)


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def client_ip(request: Request) -> str:
    """The client address for the per-IP windows: the last `X-Forwarded-For` entry when the peer is loopback
    (Caddy), else the peer. Only ever held in memory."""
    peer = request.client.host if request.client is not None else None
    if peer is None:
        return "unknown"
    if peer in _LOOPBACK:
        values = request.headers.getlist("x-forwarded-for")
        if values:
            last = values[-1].split(",")[-1].strip()
            if last:
                return last
    return peer


def rate_key(ip: str) -> str:
    """The per-IP window key for `ip`: IPv4 as is, IPv4-mapped IPv6 as its IPv4 address, other IPv6 as its /64
    (one subscriber usually holds a whole /64), anything unparsable as given. Held in memory only."""
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return ip
    if isinstance(addr, ipaddress.IPv6Address):
        if addr.ipv4_mapped is not None:
            return str(addr.ipv4_mapped)
        # From the integer, so a zone id (fe80::1%eth0) does not reach the network parser.
        return str(ipaddress.IPv6Network((int(addr) >> 64 << 64, 64)))
    return str(addr)


def authenticate(request: Request, conn: sqlite3.Connection) -> sqlite3.Row:
    """The device row for the request's bearer token. HTTPError 401 `attest_required` when the token is missing
    or unknown, `Blocked` (403 `blocked`) when the device is blocked."""
    header = request.headers.get("authorization", "")
    scheme, _, token = header.partition(" ")
    token = token.strip()
    if scheme.lower() != "bearer" or not token:
        raise HTTPError(401, "attest_required")
    row = db.device_by_token_hash(conn, token_hash(token))
    if row is None:
        raise HTTPError(401, "attest_required")
    if row["blocked"]:
        raise Blocked(row["id"])
    return row


async def read_body(request: Request, limit: int) -> bytes:
    """The request body, at most `limit` bytes; HTTPError 413 `body_too_large` beyond it (declared or sent)."""
    declared = request.headers.get("content-length")
    if declared is not None:
        if not (declared.isascii() and declared.isdigit()):
            raise HTTPError(400, "bad_request")
        if int(declared) > limit:
            raise HTTPError(413, "body_too_large")
    body = bytearray()
    async for chunk in request.stream():
        body += chunk
        if len(body) > limit:
            raise HTTPError(413, "body_too_large")
    return bytes(body)


def _parse_attest(raw: bytes) -> tuple[str, bytes, str, str | None]:
    """(keyId, attestation bytes, challenge, previousToken) or HTTPError 400 `bad_request`."""
    try:
        body = json.loads(raw)
    except (ValueError, UnicodeDecodeError):  # JSONDecodeError is a ValueError
        raise HTTPError(400, "bad_request") from None
    if not isinstance(body, dict):
        raise HTTPError(400, "bad_request")
    key_id, attestation, challenge = body.get("keyId"), body.get("attestation"), body.get("challenge")
    if not all(isinstance(v, str) for v in (key_id, attestation, challenge)):
        raise HTTPError(400, "bad_request")
    previous = body.get("previousToken") if "previousToken" in body else None
    if "previousToken" in body and not isinstance(previous, str):
        raise HTTPError(400, "bad_request")
    try:
        attestation_bytes = base64.b64decode(attestation, validate=True)
    except (binascii.Error, ValueError):
        raise HTTPError(400, "bad_request") from None
    return key_id, attestation_bytes, challenge, previous


def create_app(state: State) -> Starlette:
    quiet_http_client_logs()

    async def health(request: Request) -> Response:
        return JSONResponse({"ok": True})

    async def challenge(request: Request) -> Response:
        now = state.monotonic()
        if not state.challenge_window.hit(rate_key(client_ip(request)), now):
            raise HTTPError(429, "rate_limited")
        issued = state.challenges.issue(now)
        if issued is None:
            log.warning("attest challenge refused: outstanding challenges at the cap")
            raise HTTPError(429, "rate_limited")
        return JSONResponse({"challenge": issued}, headers=_NO_STORE)

    async def attest(request: Request) -> Response:
        settings = state.settings  # one snapshot for the whole attest
        if not state.attest_window.hit(rate_key(client_ip(request)), state.monotonic()):
            raise HTTPError(429, "rate_limited")
        key_id, attestation, challenge_b64, previous = _parse_attest(
            await read_body(request, settings.attest_max_body_bytes))
        challenge_raw = state.challenges.consume(challenge_b64, state.monotonic())
        if challenge_raw is None:
            log.info("attest refused: unknown, expired or used challenge")
            raise HTTPError(400, "bad_request")
        try:
            verify_attestation(
                attestation=attestation, key_id_b64=key_id, challenge=challenge_raw, app_id=settings.app_id,
                allow_development=settings.allow_development_attest, root=state.root, now=state.clock(),
            )
        except AttestError as e:
            log.info("attest refused: %s", e.reason)
            raise HTTPError(401, "attest_required") from None
        except Exception as e:  # fail closed; the message may hold attestation details, so only the type
            log.error("attest verification failed unexpectedly: %s", type(e).__name__)
            raise HTTPError(401, "attest_required") from None

        token = secrets.token_urlsafe(32)
        hashed = token_hash(token)
        conn = db.connect(state.db_path)
        try:
            device = db.device_by_token_hash(conn, token_hash(previous)) if previous else None
            if device is not None and device["blocked"]:
                log.info("attest refused: device %d is blocked", device["id"])
                raise HTTPError(403, "blocked")
            try:
                if device is not None:
                    db.rekey_device(conn, device["id"], key_id, hashed)
                    log.info("attest: device %d re-keyed", device["id"])
                else:
                    device_id = db.create_device(conn, key_id, hashed, state.clock())
                    log.info("attest: new device %d", device_id)
            except sqlite3.IntegrityError:
                log.warning("attest refused: key id already belongs to another device")
                raise HTTPError(401, "attest_required") from None
        finally:
            conn.close()
        return JSONResponse({"token": token}, headers=_NO_STORE)

    async def on_http_error(request: Request, exc: Exception) -> Response:
        assert isinstance(exc, HTTPError)
        return json_error(exc.status, exc.code, exc.message, exc.headers)

    async def on_starlette_error(request: Request, exc: Exception) -> Response:
        assert isinstance(exc, StarletteHTTPException)
        code = "not_found" if exc.status_code == 404 else "bad_request"
        return json_error(exc.status_code, code, MESSAGES[code], dict(exc.headers) if exc.headers else None)

    @contextlib.asynccontextmanager
    async def lifespan(app: Starlette) -> AsyncIterator[None]:
        retention.prune_if_new_day(state)
        try:
            yield
        finally:
            await state.aclose()

    from . import proxy  # here, not at the top: proxy imports this module

    return Starlette(
        routes=[
            Route("/health", health, methods=["GET"]),
            Route("/v1/attest/challenge", challenge, methods=["POST"]),
            Route("/v1/attest", attest, methods=["POST"]),
            *proxy.routes(state),  # after the attest routes: they match first
        ],
        exception_handlers={HTTPError: on_http_error, StarletteHTTPException: on_starlette_error},
        lifespan=lifespan,
    )
