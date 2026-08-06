#!/usr/bin/env bash
set -euo pipefail

lowlatency_root="${MEMWORLD_LOWLATENCY_ROOT:-/home/evophys/code/memworld-lowlatency-v1}"
gateway_entry="${lowlatency_root}/run_lowlatency_gateway.sh"
public_host="${1:-10.10.99.72}"

if [[ ! -x "$gateway_entry" ]]; then
  echo "MemWorld low-latency gateway entry is missing or not executable: $gateway_entry" >&2
  exit 2
fi

export MEMWORLD_PUBLIC_HOST="$public_host"
export MEMWORLD_GATEWAY_PORT="${MEMWORLD_GATEWAY_PORT:-63920}"
export MEMWORLD_DASHBOARD_PORT="${MEMWORLD_DASHBOARD_PORT:-63921}"
export MEMWORLD_LOCAL_WORKER_PORT="${MEMWORLD_LOCAL_WORKER_PORT:-18769}"
exec "$gateway_entry"
