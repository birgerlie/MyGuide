# MyGuide guide server

A small Python 3.14 service (Starlette, uvicorn) that sits between the app and OpenAI. It checks the device with
Apple App Attest, counts free calls and credits, and passes the call on with the owner's OpenAI key. The design is in
`docs/superpowers/specs/2026-10-30-guide-server-design.md`.

## What runs where

On the VPS, behind Caddy, on `myguide.itsalie.xyz`:

| Path | What |
| --- | --- |
| `/opt/myguide/src` | the code (this directory, rsynced), the service's working directory |
| `/opt/myguide/venv` | Python virtualenv with `requirements.txt` |
| `/etc/myguide/env` | settings and the OpenAI key, `root:myguide` `0640` |
| `/srv/myguide/guide.db` | SQLite, owned by `myguide` |
| `/srv/www/myguide` | the static website, served for everything except `/v1/*` and `/health` |
| `/etc/caddy/sites/myguide.caddy` | the Caddy site file (TLS, proxy to `127.0.0.1:8710`, no access log) |
| `myguide.service` | systemd unit, limits (`MemoryMax=200M`, `CPUWeight=50`) in `myguide.service.d/limits.conf` |

ufw allows 22, 80 and 443 in; outbound traffic is not restricted.

## First install

1. DNS: an `A` record for `myguide.itsalie.xyz` pointing at the VPS.
2. From the repo root: `MYGUIDE_DEPLOY_GO=1 server/deploy.sh` (rsync, then `install.sh` on the server).
3. On the server, put the OpenAI key in `/etc/myguide/env` (`OPENAI_API_KEY=...`) and check the `PRICE_*` lines
   against openai.com/api/pricing.
4. `systemctl restart myguide`, then `curl https://myguide.itsalie.xyz/health`.

`install.sh` is idempotent. It never overwrites an existing `/etc/myguide/env`; it only appends settings that are new
in `env.template` (with the template default) and prints their names. It does not overwrite the website if
`/srv/www/myguide` already has files, and it stops and prints the line to add if `/etc/caddy/Caddyfile` has other
content without `import sites/*.caddy`.

After editing `/etc/myguide/env`, `myguide-admin reload` re-reads it without a restart (SIGHUP).

## myguide-admin

Run as root on the server (`/usr/local/bin/myguide-admin`). Everything except `reload` runs as the `myguide` user.
Run it without arguments for the command list: devices and balances, today's cost, granting credits, blocking
devices, `reload`.

## After a deploy: check the other product's timers

`systemctl list-timers 'kunngjoring-*'` should list the same timers as before the deploy.

## Tests

`cd server && python3.14 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt && .venv/bin/pytest -q`
