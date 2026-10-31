#!/usr/bin/env bash
set -euo pipefail
# Run as root on the server, from the rsynced copy in /opt/myguide/src. Idempotent.
# Layout: /opt/myguide/src (code, WorkingDirectory), /opt/myguide/venv, /etc/myguide/env (settings and key),
# /srv/myguide (SQLite), /var/www/myguide (website, the owner's own), /etc/caddy/sites/myguide.caddy.
# The functions below take their paths from variables so tests can source this file and run them in a temp dir.

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# MYGUIDE_TEST_* overrides exist for the tests that source this file; main() refuses to run when any is set,
# so they can never redirect a real install.
OPT="${MYGUIDE_TEST_OPT:-/opt/myguide}"
ENV_FILE="${MYGUIDE_TEST_ENV_FILE:-/etc/myguide/env}"
CADDY_DIR="${MYGUIDE_TEST_CADDY_DIR:-/etc/caddy}"
DATA="${MYGUIDE_TEST_DATA:-/srv/myguide}"
WWW="${MYGUIDE_TEST_WWW:-/var/www/myguide}"

file_md5() {
    if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | awk '{print $1}'; else md5 -q "$1"; fi
}

# md5 of the Caddyfile the caddy package ships. MYGUIDE_TEST_PACKAGED_MD5 (even empty) overrides the dpkg lookup.
packaged_caddyfile_md5() {
    if [ -n "${MYGUIDE_TEST_PACKAGED_MD5+x}" ]; then
        printf '%s\n' "$MYGUIDE_TEST_PACKAGED_MD5"
        return 0
    fi
    dpkg-query -W -f='${Conffiles}\n' caddy 2>/dev/null | awk '$1 == "/etc/caddy/Caddyfile" {print $2}' || true
}

# Create ENV_FILE from the template, or append settings that are new in the template. Existing lines are never
# changed and no value is printed. Ownership and mode are set by the caller.
sync_env() {
    local template="$1" line name
    local added=()
    if [ ! -f "$ENV_FILE" ]; then
        (umask 027; cp "$template" "$ENV_FILE")
        echo "Created $ENV_FILE from env.template."
        return 0
    fi
    while IFS= read -r line || [ -n "$line" ]; do
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
    done < "$template"
    if [ "${#added[@]}" -gt 0 ]; then
        echo "Added to $ENV_FILE with the template default: ${added[*]}"
    fi
}

# Prints "install" (write our main Caddyfile) or "keep" (the existing one already imports our site) and returns 0;
# returns 1 with a message on stderr when the Caddyfile has someone else's content.
caddy_main_action() {
    local main="$CADDY_DIR/Caddyfile" packaged
    if [ ! -s "$main" ]; then
        echo install
        return 0
    fi
    packaged="$(packaged_caddyfile_md5)"
    if [ -n "$packaged" ] && [ "$(file_md5 "$main")" = "$packaged" ]; then
        echo install
        return 0
    fi
    if grep -Eq '^[[:space:]]*import[[:space:]]+sites/\*\.caddy' "$main"; then
        echo keep
        return 0
    fi
    {
        echo "$main has other content and does not import our site. Add this line to it, then re-run install.sh:"
        echo "import sites/*.caddy"
        echo "and the global options block with the log filter from $SRC/deploy/Caddyfile.main (see README)."
    } >&2
    return 1
}

# Stage the would-be Caddy config, validate it, and only then copy it into CADDY_DIR. On any failure nothing under
# CADDY_DIR changes.
install_caddy_config() {
    local rc=0
    CADDY_STAGE="$(mktemp -d)"
    trap 'rm -rf "$CADDY_STAGE"' EXIT INT TERM
    stage_and_apply_caddy "$CADDY_STAGE" || rc=$?
    rm -rf "$CADDY_STAGE"
    trap - EXIT INT TERM
    return "$rc"
}

stage_and_apply_caddy() {
    local stage="$1" action
    action="$(caddy_main_action)" || return 1
    mkdir "$stage/sites"
    if [ -d "$CADDY_DIR/sites" ]; then
        find "$CADDY_DIR/sites" -maxdepth 1 -name '*.caddy' -exec cp {} "$stage/sites/" \;
    fi
    cp "$SRC/deploy/myguide.caddy" "$stage/sites/myguide.caddy"
    if [ "$action" = install ]; then
        cp "$SRC/deploy/Caddyfile.main" "$stage/Caddyfile"
    else
        cp "$CADDY_DIR/Caddyfile" "$stage/Caddyfile"
    fi
    if ! caddy validate --config "$stage/Caddyfile" --adapter caddyfile; then
        echo "The staged Caddy config is invalid; nothing under $CADDY_DIR was changed." >&2
        return 1
    fi
    install -d -m 0755 "$CADDY_DIR" "$CADDY_DIR/sites"
    install -m 0644 "$SRC/deploy/myguide.caddy" "$CADDY_DIR/sites/myguide.caddy"
    if [ "$action" = install ]; then
        install -m 0644 "$SRC/deploy/Caddyfile.main" "$CADDY_DIR/Caddyfile"
    fi
}

main() {
    if [ -n "$(compgen -A variable MYGUIDE_TEST_)" ]; then
        echo "Refusing to run: a MYGUIDE_TEST_* variable is set." >&2
        exit 1
    fi
    if [ "$(id -u)" -ne 0 ]; then
        echo "install.sh must run as root." >&2
        exit 1
    fi
    # Never let apt restart services that belong to something else on this machine.
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 NEEDRESTART_MODE=l

    local need=() key_set=0
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

    if ! id myguide >/dev/null 2>&1; then
        useradd --system --user-group --home-dir "$DATA" --no-create-home --shell /usr/sbin/nologin myguide
    fi
    install -d -o root -g root -m 0755 "$OPT"
    install -d -o myguide -g myguide -m 0750 "$DATA"
    install -d -o root -g myguide -m 0750 "$(dirname "$ENV_FILE")"
    # The service reads the code as myguide and the wrapper as root: root-owned, world-readable, never writable.
    chown -R root:root "$SRC"
    chmod -R go+rX,go-w "$SRC"

    sync_env "$SRC/env.template"
    chown root:myguide "$ENV_FILE"
    chmod 0640 "$ENV_FILE"
    if grep -Eq '^OPENAI_API_KEY=.+' "$ENV_FILE"; then
        key_set=1
    else
        echo "OPENAI_API_KEY in $ENV_FILE is empty: fill it in, then run: systemctl restart myguide"
    fi

    if [ ! -x "$OPT/venv/bin/python" ]; then
        python3.14 -m venv "$OPT/venv"
    fi
    "$OPT/venv/bin/pip" install --quiet -r "$SRC/requirements.txt"

    install -d -m 0755 /etc/systemd/system/myguide.service.d
    install -m 0644 "$SRC/deploy/myguide.service" /etc/systemd/system/myguide.service
    install -m 0644 "$SRC/deploy/limits.conf" /etc/systemd/system/myguide.service.d/limits.conf
    install -m 0755 "$SRC/bin/myguide-admin" /usr/local/bin/myguide-admin

    # Website directory: never overwrite the owner's own site.
    install -d -m 0755 "$WWW"
    if [ -z "$(ls -A "$WWW")" ]; then
        cp -R "$SRC/www/." "$WWW/"
        chmod -R go+rX "$WWW"
    fi
    install_caddy_config
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
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
