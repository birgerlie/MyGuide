#!/usr/bin/env bash
set -euo pipefail
# Run locally. Ships the git-tracked files of server/ to the VPS and runs the idempotent installer there.
# Refuses to do anything until the owner says go: MYGUIDE_DEPLOY_GO=1 ./deploy.sh
if [ "${MYGUIDE_DEPLOY_GO:-}" != "1" ]; then
    echo "Refusing to deploy: set MYGUIDE_DEPLOY_GO=1 to confirm." >&2
    exit 1
fi
HOST=root@204.168.153.170
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -n "$(git -C "$repo" status --porcelain server)" ]; then
    echo "Refusing to deploy: uncommitted changes under server/." >&2
    exit 1
fi
# Stage the tracked files only (no .venv, no untracked or ignored files), then mirror the stage into src.
# --delete is scoped to /opt/myguide/src: the venv lives beside it and is never touched.
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
git -C "$repo/server" ls-files -z . | rsync -a --from0 --files-from=- "$repo/server/" "$stage/"
rsync -a --delete --chown=root:root --rsync-path='mkdir -p /opt/myguide && rsync' "$stage/" "$HOST:/opt/myguide/src/"
ssh "$HOST" 'bash /opt/myguide/src/deploy/install.sh'
