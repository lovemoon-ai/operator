#!/usr/bin/env bash
# Update an existing operator deployment on the volc box.
#
# Pulls the latest code, rebuilds, restarts the service. Safe to run
# on every push.
#
# Run as root on the volc box:
#   bash /opt/conductor/operator/web/deploy/deploy.sh

set -euo pipefail

REPO_DIR=${REPO_DIR:-/opt/conductor/operator}

log() { printf "\033[1;36m[deploy]\033[0m %s\n" "$*"; }

if [[ $EUID -ne 0 ]]; then
  echo "must run as root" >&2; exit 1
fi

cd "$REPO_DIR"
log "git pull"
git pull --ff-only

# shellcheck disable=SC1091
source /root/.nvm/nvm.sh
log "node $(node -v)"

cd web
log "npm install"
npm install

log "build:ingest"
npm run build:ingest

log "next build (atomic via .next.build → .next swap)"
rm -rf app/.next.build
(cd app && NEXT_DIST_DIR=.next.build npx next build)
if [[ ! -f app/.next.build/BUILD_ID ]]; then
  echo "build produced no BUILD_ID; aborting" >&2
  rm -rf app/.next.build
  exit 1
fi
rm -rf app/.next.old
[[ -d app/.next ]] && mv app/.next app/.next.old
mv app/.next.build app/.next
rm -rf app/.next.old

log "restarting operator-web"
systemctl restart operator-web

log "waiting for /api/ingest-read/sessions to answer 401 (auth-gated)"
for i in $(seq 1 30); do
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:6153/api/ingest-read/sessions || echo 000)
  if [[ "$code" == "401" || "$code" == "200" ]]; then
    log "service up (status $code)"
    exit 0
  fi
  sleep 1
done

echo "service didn't come up cleanly within 30s; check: journalctl -u operator-web -n 80" >&2
exit 1
