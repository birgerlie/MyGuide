#!/usr/bin/env bash
set -euo pipefail
# Run locally. Copies server/ to the VPS and runs the idempotent installer there.
# Refuses to do anything until the owner says go: MYGUIDE_DEPLOY_GO=1 ./deploy.sh
if [ "${MYGUIDE_DEPLOY_GO:-}" != "1" ]; then
    echo "Refusing to deploy: set MYGUIDE_DEPLOY_GO=1 to confirm." >&2
    exit 1
fi
HOST=root@204.168.153.170
cd "$(dirname "${BASH_SOURCE[0]}")/.."
rsync -a --delete --rsync-path='mkdir -p /opt/myguide && rsync' --exclude .venv --exclude tests --exclude __pycache__ server/ "$HOST:/opt/myguide/src/"
ssh "$HOST" 'bash /opt/myguide/src/deploy/install.sh'
