#!/usr/bin/env bash
set -euo pipefail

operator_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
public_host="${1:-10.10.99.72}"
local_worker_port="${MEMWORLD_LOCAL_WORKER_PORT:-18768}"

if [[ -z "${MEMWORLD_INITIAL_RGB:-}" || ! -f "$MEMWORLD_INITIAL_RGB" ]]; then
  echo "MEMWORLD_INITIAL_RGB must point to an existing local initialization image" >&2
  exit 2
fi

export MEMWORLD_WORKER_URL="tcp://127.0.0.1:${local_worker_port}"
exec "$operator_root/run_quest_memworld.sh" "$public_host"
