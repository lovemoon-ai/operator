#!/usr/bin/env bash
set -euo pipefail

operator_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
public_host="${1:-10.10.99.72}"
gateway_port="${MEMWORLD_GATEWAY_PORT:-63920}"
dashboard_port="${MEMWORLD_DASHBOARD_PORT:-63921}"
worker_url="${MEMWORLD_WORKER_URL:-ws://127.0.0.1:8765}"
num_inference_steps="${MEMWORLD_NUM_INFERENCE_STEPS:-4}"
cfg_scale="${MEMWORLD_CFG_SCALE:-1.0}"
initial_rgb="${MEMWORLD_INITIAL_RGB:-/home/evophys/code/MemWorld-direct-dmd1000/anchor.jpg}"
static_memory="${MEMWORLD_STATIC_MEMORY:-${initial_rgb}}"
ffmpeg_bin="${MEMWORLD_FFMPEG_BIN:-/home/evophys/miniconda3/envs/memworld-egoquest/bin/ffmpeg}"
capture_hz="${MEMWORLD_CAPTURE_HZ:-20}"
worker_session_chunks="${MEMWORLD_WORKER_SESSION_CHUNKS:-0}"

cd "$operator_root"
exec server/.venv/bin/python -m server.memworld_gateway \
  --host 0.0.0.0 \
  --port "$gateway_port" \
  --dashboard-port "$dashboard_port" \
  --public-host "$public_host" \
  --worker-url "$worker_url" \
  --num-inference-steps "$num_inference_steps" \
  --cfg-scale "$cfg_scale" \
  --initial-rgb "$initial_rgb" \
  --static-memory "$static_memory" \
  --ffmpeg-bin "$ffmpeg_bin" \
  --capture-hz "$capture_hz" \
  --worker-session-chunks "$worker_session_chunks"
