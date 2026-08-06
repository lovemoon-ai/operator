#!/usr/bin/env bash
set -euo pipefail

lowlatency_root="${MEMWORLD_LOWLATENCY_ROOT:-/home/evophys/code/memworld-lowlatency-v1}"
tunnel_entry="${lowlatency_root}/start_nv_tunnel.sh"

if [[ ! -x "$tunnel_entry" ]]; then
  echo "MemWorld low-latency tunnel entry is missing or not executable: $tunnel_entry" >&2
  exit 2
fi

local_worker_port="${MEMWORLD_LOCAL_WORKER_PORT:-18768}"
remote_worker_port="${MEMWORLD_REMOTE_WORKER_PORT:-${MEMWORLD_NV_WORKER_PORT:-18768}}"

export MEMWORLD_LOCAL_WORKER_PORT="$local_worker_port"
export MEMWORLD_REMOTE_WORKER_PORT="$remote_worker_port"
exec "$tunnel_entry"
