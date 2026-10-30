"""Shared state of the running service: settings (replaceable by a reload), in-memory windows and challenges,
the App Attest root and the upstream HTTP client (spec 5, 6.1; Ruling 4)."""
from __future__ import annotations

import logging
import time
from http.cookiejar import CookieJar, DefaultCookiePolicy
from collections.abc import Callable
from datetime import datetime, timezone
from pathlib import Path

import httpx
from cryptography import x509

from .attest import Challenges, apple_root
from .config import ConfigError, Settings, load_settings
from .limits import RateWindow

log = logging.getLogger(__name__)

def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def upstream_client(transport: httpx.AsyncBaseTransport | None = None) -> httpx.AsyncClient:
    """The client for OpenAI: no client-wide timeout (the proxy passes UPSTREAM_TIMEOUT_SECONDS per
    request, so a reload applies), no redirects, and a cookie jar that accepts nothing, so a `Set-Cookie`
    from upstream (e.g. Cloudflare's __cf_bm) is never stored or sent back on a later call."""
    jar = CookieJar(policy=DefaultCookiePolicy(allowed_domains=[]))
    return httpx.AsyncClient(timeout=None, follow_redirects=False, cookies=jar, transport=transport)


class State:
    """Everything the request handlers share. Windows and challenges read their limits from `self.settings`
    on every use, so a reload applies at once without dropping calls in progress."""

    def __init__(
        self,
        settings: Settings,
        db_path: str | Path,
        *,
        root: x509.Certificate | None = None,
        upstream: httpx.AsyncClient | None = None,
        clock: Callable[[], datetime] = _utc_now,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self.settings = settings
        self.db_path = Path(db_path)
        self.clock = clock
        self.monotonic = monotonic
        self.root = root if root is not None else apple_root()
        self.upstream = upstream if upstream is not None else upstream_client()
        self.challenges = Challenges(lambda: self.settings.challenge_ttl_seconds,
                                     max_outstanding=lambda: self.settings.challenges_max_outstanding)
        # The per-IP windows are keyed by app.rate_key(client_ip): IPv6 per /64. Keys live in memory only.
        self.attest_window = RateWindow(lambda: self.settings.attests_per_ip_per_hour, 3600)
        self.challenge_window = RateWindow(lambda: self.settings.challenges_per_ip_per_hour, 3600)
        self.rate_window = RateWindow(lambda: self.settings.rate_per_minute, 60)
        self.last_pruned_day: str | None = None  # UTC day of the last log pruning (retention.py)

    def reload(self, path: str | Path) -> None:
        """Read the env file again; replace `settings` only when the whole file is valid."""
        try:
            new = load_settings(Path(path))
        except ConfigError as e:
            log.error("reload refused, settings unchanged: %s", e)
            return
        if new.listen_port != self.settings.listen_port:
            log.warning("reload: LISTEN_PORT changed to %d; it takes effect only after a restart", new.listen_port)
        self.settings = new
        log.info("settings reloaded")

    async def aclose(self) -> None:
        await self.upstream.aclose()
