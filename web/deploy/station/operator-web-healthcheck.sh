#!/usr/bin/env bash
set -euo pipefail

port="${PORT:-6153}"
url="http://127.0.0.1:${port}/healthz"

if /usr/bin/curl --fail --silent --show-error --max-time 8 "$url" >/dev/null; then
  exit 0
fi

printf 'Operator Station health check failed; restarting service.\n' >&2
/usr/bin/systemctl --user reset-failed operator-web-station.service
/usr/bin/systemctl --user restart operator-web-station.service

for _attempt in 1 2 3 4 5; do
  if /usr/bin/curl --fail --silent --show-error --max-time 4 "$url" >/dev/null; then
    printf 'Operator Station recovered successfully.\n'
    exit 0
  fi
  sleep 2
done

printf 'Operator Station did not recover after restart.\n' >&2
exit 1
