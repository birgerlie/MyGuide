"""`python -m myguide --env /etc/myguide/env --db /srv/myguide/guide.db`: load settings, run the service on
127.0.0.1:<LISTEN_PORT> behind Caddy. SIGHUP reads the env file again (spec 6.1)."""
from __future__ import annotations

import argparse
import asyncio
import logging
import signal
import sys
from pathlib import Path

import uvicorn

from . import db
from .app import create_app, quiet_http_client_logs
from .config import ConfigError, load_settings
from .state import State


def main(argv: list[str] | None = None) -> int:
    # A reload (SIGHUP) that lands before the handler below is installed must not kill the service, which is
    # Python's default for SIGHUP: ignore it until then.
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    parser = argparse.ArgumentParser(prog="python -m myguide", description="MyGuide guide server")
    parser.add_argument("--env", required=True, type=Path, help="settings file, KEY=VALUE lines")
    parser.add_argument("--db", required=True, type=Path, help="SQLite database file")
    args = parser.parse_args(argv)

    try:
        settings = load_settings(args.env)
    except ConfigError as e:
        print(e, file=sys.stderr)
        return 1

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s", stream=sys.stderr)
    quiet_http_client_logs()
    db.connect(args.db).close()  # create the schema now, so a bad --db fails at start, not on the first call
    state = State(settings, args.db)
    server = uvicorn.Server(uvicorn.Config(
        create_app(state), host="127.0.0.1", port=settings.listen_port, access_log=False,
        proxy_headers=False, server_header=False, log_level="info",
    ))

    async def serve() -> None:
        # On the event loop, not a raw signal handler: reload (file read, logging) runs between tasks.
        asyncio.get_running_loop().add_signal_handler(signal.SIGHUP, state.reload, args.env)
        await server.serve()

    asyncio.run(serve())
    return 0


if __name__ == "__main__":
    sys.exit(main())
