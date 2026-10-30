#!/usr/bin/env bash
set -euo pipefail
# Run as root on the server, from the rsynced copy in /opt/myguide/src. Idempotent.
# Layout: /opt/myguide/src (code, WorkingDirectory), /opt/myguide/venv, /etc/myguide/env (settings and key),
# /srv/myguide (SQLite), /srv/www/myguide (website), /etc/caddy/sites/myguide.caddy.

if [ "$(id -u)" -ne 0 ]; then
    echo "install.sh must run as root." >&2
    exit 1
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPT=/opt/myguide
ENV_FILE=/etc/myguide/env
DATA=/srv/myguide
WWW=/srv/www/myguide

export DEBIAN_FRONTEND=noninteractive

# Packages
need=()
command -v caddy >/dev/null 2>&1 || need+=(caddy)
command -v ufw >/dev/null 2>&1 || need+=(ufw)
command -v rsync >/dev/null 2>&1 || need+=(rsync)
command -v python3.14 >/dev/null 2>&1 || need+=(python3.14)
if [ "${#need[@]}" -gt 0 ]; then
    apt-get update
    apt-get install -y "${need[@]}"
fi
if ! python3.14 -c 'import ensurepip, venv' >/dev/null 2>&1; then
    apt-get update
    apt-get install -y python3.14-venv
fi

# User and directories
if ! id myguide >/dev/null 2>&1; then
    useradd --system --user-group --home-dir "$DATA" --no-create-home --shell /usr/sbin/nologin myguide
fi
install -d -o root -g root -m 0755 "$OPT"
install -d -o myguide -g myguide -m 0750 "$DATA"
install -d -o root -g myguide -m 0750 /etc/myguide
# The service reads the code as myguide and the wrapper as root: root-owned, world-readable, never writable.
chown -R root:root "$OPT/src"
chmod -R go+rX,go-w "$OPT/src"

# Settings: create from the template once; afterwards only add settings that are new in the template.
if [ ! -f "$ENV_FILE" ]; then
    install -o root -g myguide -m 0640 "$SRC/env.template" "$ENV_FILE"
    echo "Created $ENV_FILE from env.template."
else
    added=()
    while IFS= read -r line; do
        case "$line" in
            ''|'#'*) continue ;;
            *=*) ;;
            *) continue ;;
        esac
        name="${line%%=*}"
        if ! grep -q "^${name}=" "$ENV_FILE"; then
            if [ -s "$ENV_FILE" ] && [ -n "$(tail -c 1 "$ENV_FILE")" ]; then
                echo >> "$ENV_FILE"
            fi
            echo "$line" >> "$ENV_FILE"
            added+=("$name")
        fi
    done < "$SRC/env.template"
    if [ "${#added[@]}" -gt 0 ]; then
        echo "Added to $ENV_FILE with the template default: ${added[*]}"
    fi
    chown root:myguide "$ENV_FILE"
    chmod 0640 "$ENV_FILE"
fi
key_set=0
if grep -Eq '^OPENAI_API_KEY=.+' "$ENV_FILE"; then
    key_set=1
else
    echo "OPENAI_API_KEY in $ENV_FILE is empty: fill it in, then run: systemctl restart myguide"
fi

# Python environment
if [ ! -x "$OPT/venv/bin/python" ]; then
    python3.14 -m venv "$OPT/venv"
fi
"$OPT/venv/bin/pip" install --quiet -r "$SRC/requirements.txt"

# systemd unit, limits and admin tool
install -d -m 0755 /etc/systemd/system/myguide.service.d
install -m 0644 "$SRC/deploy/myguide.service" /etc/systemd/system/myguide.service
install -m 0644 "$SRC/deploy/limits.conf" /etc/systemd/system/myguide.service.d/limits.conf
install -m 0755 "$SRC/bin/myguide-admin" /usr/local/bin/myguide-admin

# Caddy: our site file, and the website directory (never overwriting the owner's own site)
install -d -m 0755 /etc/caddy/sites /srv/www "$WWW"
install -m 0644 "$SRC/deploy/myguide.caddy" /etc/caddy/sites/myguide.caddy
if [ -z "$(ls -A "$WWW")" ]; then
    cp -R "$SRC/www/." "$WWW/"
    chmod -R go+rX "$WWW"
fi
CADDYFILE=/etc/caddy/Caddyfile
if [ ! -s "$CADDYFILE" ] || grep -q 'root \* /usr/share/caddy' "$CADDYFILE"; then
    install -m 0644 "$SRC/deploy/Caddyfile.main" "$CADDYFILE"
elif ! grep -Eq '^[[:space:]]*import[[:space:]]+sites/\*\.caddy' "$CADDYFILE"; then
    echo "$CADDYFILE has other content and does not import our site. Add this line to it, then re-run install.sh:" >&2
    echo "import sites/*.caddy" >&2
    exit 1
fi
caddy validate --config "$CADDYFILE" --adapter caddyfile
systemctl enable caddy
systemctl reload-or-restart caddy

# Firewall: ssh first, so it is never cut. Outbound traffic is left alone.
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

systemctl daemon-reload
systemctl enable myguide
if [ "$key_set" -eq 1 ]; then
    systemctl restart myguide
    echo "myguide restarted."
else
    echo "myguide enabled but not started (no OpenAI key yet)."
fi
