#!/usr/bin/env bash
set -euo pipefail

repo_dir="${REPO_DIR:-/home/evophys/code/operator-github}"
data_dir="${DATA_DIR:-/home/evophys/operator-data}"
port="${PORT:-6153}"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/operator-station"
env_file="$config_dir/station.env"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
lan_ip="$(hostname -I | awk '{print $1}')"

if [[ -z "$lan_ip" ]]; then
  lan_ip="127.0.0.1"
fi

mkdir -p "$data_dir/sessions" "$data_dir/collector-previews" "$config_dir" "$unit_dir"

if [[ ! -f "$env_file" ]]; then
  session_secret="$(openssl rand -hex 32)"
  install -m 0600 /dev/null "$env_file"
  {
    echo "NODE_ENV=production"
    echo "PORT=$port"
    echo "DATA_ROOT=$data_dir"
    echo "AUTH_BASE_URL=http://$lan_ip:$port"
    echo "AUTH_SESSION_SECRET=$session_secret"
    echo "AUTH_COOKIE_SECURE=0"
    echo "AUTH_BYPASS=1"
    echo "RERUN_DISABLED=1"
  } >"$env_file"
fi
if ! grep -q '^OPERATOR_MODELSCOPE_TOKEN=' "$env_file"; then
  printf '%s\n' 'OPERATOR_MODELSCOPE_TOKEN=' >>"$env_file"
fi
chmod 0600 "$env_file"

cd "$repo_dir/web"
npm ci
npm run build

install -m 0644 \
  "$repo_dir/web/deploy/station/operator-web-station.service" \
  "$unit_dir/operator-web-station.service"
install -m 0644 \
  "$repo_dir/web/deploy/station/operator-web-healthcheck.service" \
  "$unit_dir/operator-web-healthcheck.service"
install -m 0644 \
  "$repo_dir/web/deploy/station/operator-web-healthcheck.timer" \
  "$unit_dir/operator-web-healthcheck.timer"
systemctl --user daemon-reload
systemctl --user enable --now operator-web-station.service
systemctl --user restart operator-web-station.service
systemctl --user enable --now operator-web-healthcheck.timer

printf '\nOperator Station is running.\n'
printf 'LAN:        http://%s:%s/collectors\n' "$lan_ip" "$port"
printf 'SSH tunnel: ssh -N -L %s:127.0.0.1:%s 4090station\n' "$port" "$port"
printf 'Then open:  http://127.0.0.1:%s/collectors\n\n' "$port"
printf 'Health:     http://127.0.0.1:%s/healthz\n' "$port"
printf 'For boot without an interactive login, an administrator must run once:\n'
printf '  sudo loginctl enable-linger %s\n' "$USER"
