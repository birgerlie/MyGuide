#!/usr/bin/env bash
set -euo pipefail
# Run locally. Ships the git-tracked files of server/ to the VPS and runs the idempotent installer there.
# Refuses to do anything until the owner says go: MYGUIDE_DEPLOY_GO=1 ./deploy.sh

# build_stage REPO STAGE: copy the git-tracked files of REPO/server into STAGE (an existing empty directory).
# Uses git and tar only, so it works with the openrsync that macOS ships. Fails if the result lacks the installer.
build_stage() {
    local repo="$1" stage="$2"
    chmod 0755 "$stage"
    git -C "$repo/server" ls-files -z . | tar -cf - -C "$repo/server" --null -T - | tar -xf - -C "$stage"
    if [ ! -f "$stage/deploy/install.sh" ]; then
        echo "Refusing to deploy: the staged tree has no deploy/install.sh." >&2
        return 1
    fi
}

main() {
    if [ "${MYGUIDE_DEPLOY_GO:-}" != "1" ]; then
        echo "Refusing to deploy: set MYGUIDE_DEPLOY_GO=1 to confirm." >&2
        exit 1
    fi
    local host=root@204.168.153.170 repo stage
    repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if [ -n "$(git -C "$repo" status --porcelain server)" ]; then
        echo "Refusing to deploy: uncommitted changes under server/." >&2
        exit 1
    fi
    stage="$(mktemp -d)"
    # Expanded now: $stage is local and gone by the time the EXIT trap runs under set -u.
    trap "rm -rf '$stage'" EXIT
    build_stage "$repo" "$stage"
    # -rlpt, not -a: no owner or group is sent (install.sh chowns to root). --delete is scoped to
    # /opt/myguide/src; the venv lives beside it and is never touched.
    rsync -rlpt --delete --rsync-path='mkdir -p /opt/myguide && rsync' "$stage/" "$host:/opt/myguide/src/"
    ssh "$host" 'bash /opt/myguide/src/deploy/install.sh'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
