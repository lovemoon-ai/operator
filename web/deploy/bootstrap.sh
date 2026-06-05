#!/usr/bin/env bash
# One-time provisioning on the volc box for operator.conductor-ai.top.
#
# Idempotent — re-running is safe; it only mutates state that hasn't
# been set up yet.
#
# Run as root on the volc box (already cloned to /opt/conductor/operator):
#   bash web/deploy/bootstrap.sh
#
# What it does:
#   1. apt-installs ffmpeg + sqlite3 + build-essential (if missing)
#   2. creates /opt/operator-data + symlinks it as web/app/data
#   3. npm install + builds the workspace
#   4. drops a starter .env.production (you fill in the secrets after)
#   5. installs the systemd unit (does NOT start — see below)
#   6. installs the nginx site (HTTP-only until DNS+certbot land)
#
# Does NOT do:
#   - DNS (set the A record at your DNS provider)
#   - certbot (run AFTER DNS resolves; one-line command printed at end)
#   - Start the service (start it after you've edited .env.production)

set -euo pipefail

REPO_DIR=${REPO_DIR:-/opt/conductor/operator}
DATA_DIR=${DATA_DIR:-/opt/operator-data}
DOMAIN=${DOMAIN:-operator.conductor-ai.top}
PORT=${PORT:-6153}

log() { printf "\033[1;36m[bootstrap]\033[0m %s\n" "$*"; }

if [[ $EUID -ne 0 ]]; then
  echo "must run as root" >&2; exit 1
fi

# -- 1. OS deps -------------------------------------------------------------
log "checking apt packages"
NEED_APT=()
command -v ffmpeg >/dev/null      || NEED_APT+=(ffmpeg)
command -v sqlite3 >/dev/null     || NEED_APT+=(sqlite3)
dpkg -s build-essential >/dev/null 2>&1 || NEED_APT+=(build-essential)
if (( ${#NEED_APT[@]} > 0 )); then
  log "installing: ${NEED_APT[*]}"
  apt-get update -y
  apt-get install -y "${NEED_APT[@]}"
fi

# -- 2. data directory + symlink -------------------------------------------
log "preparing data dir $DATA_DIR"
mkdir -p "$DATA_DIR/sessions" "$DATA_DIR/seed" "$DATA_DIR/backups"

# The app expects $REPO_DIR/web/app/data; we symlink to keep all on-disk
# state under one mount point (/opt/operator-data) so future moves are
# trivial.
APP_DATA_LINK="$REPO_DIR/web/app/data"
if [[ -L "$APP_DATA_LINK" ]]; then
  log "symlink $APP_DATA_LINK exists → $(readlink "$APP_DATA_LINK")"
elif [[ -e "$APP_DATA_LINK" ]]; then
  echo "$APP_DATA_LINK exists and is not a symlink; refusing to touch" >&2
  exit 1
else
  ln -sf "$DATA_DIR" "$APP_DATA_LINK"
  log "linked $APP_DATA_LINK -> $DATA_DIR"
fi

# -- 3. .env.production stub (write BEFORE build so next build can ----------
#       read AUTH_SESSION_SECRET during /_not-found prerender) -------------
ENV_FILE="$REPO_DIR/web/app/.env.production"
if [[ ! -f "$ENV_FILE" ]]; then
  log "writing starter $ENV_FILE — EDIT BEFORE STARTING SERVICE"
  cat > "$ENV_FILE" <<EOF
NODE_ENV=production
PORT=$PORT
DATA_ROOT=$DATA_DIR
MAX_BYTES=21474836480

AUTH_BASE_URL=https://$DOMAIN

# REPLACE THESE before \`systemctl start operator-web\`:
AUTH_SESSION_SECRET=$(openssl rand -hex 32)
INGEST_CONNECT_SECRET=$(openssl rand -hex 32)

# Until OIDC is configured, bypass mode lets you smoke-test as a fixed
# dev user. SWITCH OFF before exposing to real users.
AUTH_BYPASS=1

# Uncomment and fill in to use real OIDC:
# OIDC_ISSUER=https://accounts.google.com
# OIDC_CLIENT_ID=...apps.googleusercontent.com
# OIDC_CLIENT_SECRET=...

# Rerun worker requires SpatialMP4 SDK + uv + python 3.13; skip on
# first deploy and pre-bake .rrd into the seed data instead.
RERUN_DISABLED=1
EOF
  chmod 600 "$ENV_FILE"
else
  log "$ENV_FILE already exists; not overwriting"
fi

# -- 4. install + build -----------------------------------------------------
# shellcheck disable=SC1091
source /root/.nvm/nvm.sh
log "node $(node -v) npm $(npm -v)"

cd "$REPO_DIR/web"
log "npm install (this can take ~1m on first run; better-sqlite3 will native-compile)"
npm install

log "build:ingest"
npm run build:ingest

log "next build"
(cd app && npx next build)

# -- 5. systemd unit -------------------------------------------------------
log "installing systemd unit"
install -m 0644 "$REPO_DIR/web/deploy/operator-web.service" /etc/systemd/system/operator-web.service
systemctl daemon-reload

# -- 6. nginx site (HTTP-only stub until certbot runs) ---------------------
log "installing nginx site (HTTP-only until certbot adds TLS)"
# Pre-certbot we serve HTTP only — the file we ship has the 443 block
# present but with ssl_certificate lines commented out, which would
# fail `nginx -t`. Trim the 443 block off for the initial install and
# let certbot append it.
TMP=$(mktemp)
awk '
  /^server \{ *$/      { skip=0 }
  /listen 443 ssl/     { skip=1 }
  skip==0              { print }
' "$REPO_DIR/web/deploy/nginx.conf" > "$TMP"
# Also strip the redirect-to-https inside the :80 block so it serves
# directly until certbot rewrites the file.
sed -i 's|return 301 https://\$host\$request_uri;|proxy_pass http://127.0.0.1:'"$PORT"';|' "$TMP" || true

install -m 0644 "$TMP" /etc/nginx/sites-available/operator
rm -f "$TMP"
ln -sf /etc/nginx/sites-available/operator /etc/nginx/sites-enabled/operator

# Don't reload yet if config is bad — surface the error.
nginx -t

# -- next steps ------------------------------------------------------------
cat <<NEXT

\033[1;32m[bootstrap] done\033[0m

Next steps:

  1. Edit $ENV_FILE to set AUTH_BYPASS=0 + real OIDC_* values when ready.
  2. Start the service:
       systemctl enable --now operator-web
       journalctl -u operator-web -f
  3. Reload nginx:
       systemctl reload nginx
  4. Add DNS A record:
       $DOMAIN  A  115.190.243.112
     Confirm with: dig +short $DOMAIN
  5. Once DNS resolves, issue HTTPS cert:
       certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m <your-email>
       cp $REPO_DIR/web/deploy/nginx.conf /etc/nginx/sites-available/operator
       # uncomment the 4 ssl_* lines + remove their leading '# ',
       # then: nginx -t && systemctl reload nginx

NEXT
