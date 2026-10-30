"""Shared fixtures for the service tests: settings from the env template, a State with injected clocks and
the test App Attest root, and a TestClient whose peer is 127.0.0.1 (as behind Caddy)."""
from __future__ import annotations

from pathlib import Path

import httpx
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from starlette.testclient import TestClient

from myguide.app import create_app
from myguide.config import parse_settings
from myguide.state import State
from tests.attest_fixtures import NOW, make_attestation

TEMPLATE = Path(__file__).parent.parent / "env.template"


def env_dict(**overrides: str) -> dict[str, str]:
    """The env template as a dict, with a test OpenAI key and `overrides` applied."""
    env: dict[str, str] = {}
    for line in TEMPLATE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        k, _, v = line.partition("=")
        env[k] = v
    env["OPENAI_API_KEY"] = "sk-test"
    env.update(overrides)
    return env


def write_env(path: Path, **overrides: str) -> Path:
    path.write_text("".join(f"{k}={v}\n" for k, v in env_dict(**overrides).items()), encoding="utf-8")
    return path


class FakeMonotonic:
    def __init__(self, start: float = 1000.0) -> None:
        self.t = start

    def __call__(self) -> float:
        return self.t

    def advance(self, seconds: float) -> None:
        self.t += seconds


@pytest.fixture(scope="session")
def root_key() -> ec.EllipticCurvePrivateKey:
    """One root key for the whole run: every attestation chains to the same test root."""
    return ec.generate_private_key(ec.SECP384R1())


@pytest.fixture(scope="session")
def test_root(root_key):
    _, _, root = make_attestation(app_id="x", challenge=b"x" * 32, root_key=root_key)
    return root


@pytest.fixture
def mono() -> FakeMonotonic:
    return FakeMonotonic()


@pytest.fixture
def make_state(tmp_path, test_root, mono):
    """make_state(**env_overrides) -> State on a fresh DB in tmp_path, clock fixed at NOW."""
    def factory(**overrides: str) -> State:
        return State(
            parse_settings(env_dict(**overrides)), tmp_path / "guide.db",
            root=test_root, clock=lambda: NOW, monotonic=mono,
        )
    return factory


@pytest.fixture
def state(make_state) -> State:
    return make_state()


@pytest.fixture
def client(state):
    with TestClient(create_app(state), client=("127.0.0.1", 50000)) as c:
        yield c


@pytest.fixture(autouse=True)
def no_real_network(monkeypatch):
    """Any send to a non-loopback host through a real httpx transport fails the test: upstream doubles use
    httpx.MockTransport. Loopback stays open for the test that starts the service itself."""
    def check(request) -> None:
        if request.url.host not in ("127.0.0.1", "localhost", "::1"):
            raise AssertionError(f"test tried to reach the network: {request.url}")

    real_async, real_sync = httpx.AsyncHTTPTransport.handle_async_request, httpx.HTTPTransport.handle_request

    async def guarded_async(self, request):
        check(request)
        return await real_async(self, request)

    def guarded_sync(self, request):
        check(request)
        return real_sync(self, request)

    monkeypatch.setattr(httpx.AsyncHTTPTransport, "handle_async_request", guarded_async)
    monkeypatch.setattr(httpx.HTTPTransport, "handle_request", guarded_sync)
