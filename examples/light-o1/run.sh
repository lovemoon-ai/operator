#!/usr/bin/env bash
# Run the Light-O1 G1 host against a Light-O1 control server. Defaults match
# the apex layout (~/ws/light-o1); override with environment variables:
#   LIGHT_O1_ROOT=/path/to/Light-O1 SONIC_CHECKPOINT=/path/to/low_latency \
#   LIGHT_O1_URL=http://127.0.0.1:8090 HEADSET_IP=192.168.1.50 ./run.sh [extra args]
set -euo pipefail
EXAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="${VENV:-$EXAMPLE_DIR/.venv}"
export LIGHT_O1_ROOT="${LIGHT_O1_ROOT:-$HOME/ws/light-o1/Light-O1}"
export SONIC_CHECKPOINT="${SONIC_CHECKPOINT:-$HOME/ws/light-o1/models/GEAR-SONIC/low_latency}"
export MUJOCO_GL="${MUJOCO_GL:-egl}"
ARGS=(--url "${LIGHT_O1_URL:-http://127.0.0.1:8090}")
if [ -n "${HEADSET_IP:-}" ]; then ARGS+=(--headset-ip "$HEADSET_IP"); fi
exec "$VENV/bin/python" "$EXAMPLE_DIR/main.py" "${ARGS[@]}" "$@"
