#!/usr/bin/env bash
set -euo pipefail

memworld_root="/home/evophys/code/MemWorld-direct-dmd1000"
conda_bin="${CONDA_BIN:-/home/evophys/miniconda3/bin/conda}"
model_dir="${MEMWORLD_MODEL_DIR:-${memworld_root}/models/Wan2.2-TI2V-5B}"
checkpoint="${MEMWORLD_CHECKPOINT:-${memworld_root}/models/object_interaction_step1335/formal_repaired_direct_dmd_outer1335_dfa2a44f98e7e20/dit_step1335.safetensors}"
worker_host="${MEMWORLD_WORKER_HOST:-127.0.0.1}"
worker_port="${MEMWORLD_WORKER_PORT:-8765}"
warmup_initial_rgb="${MEMWORLD_INITIAL_RGB:-${memworld_root}/anchor.jpg}"
warmup_static_memory="${MEMWORLD_STATIC_MEMORY:-${warmup_initial_rgb}}"
warmup_runs="${MEMWORLD_WARMUP_RUNS:-2}"
num_inference_steps="${MEMWORLD_NUM_INFERENCE_STEPS:-4}"
cfg_scale="${MEMWORLD_CFG_SCALE:-1.0}"

cd "${memworld_root}"

exec "${conda_bin}" run --no-capture-output -n memworld-egoquest python deploy/egoquest_ws/server.py \
  --project-root "${memworld_root}" \
  --model-dir "${model_dir}" \
  --checkpoint "${checkpoint}" \
  --host "${worker_host}" \
  --port "${worker_port}" \
  --warmup-initial-rgb "${warmup_initial_rgb}" \
  --warmup-static-memory "${warmup_static_memory}" \
  --warmup-runs "${warmup_runs}" \
  --warmup-num-inference-steps "${num_inference_steps}" \
  --warmup-cfg-scale "${cfg_scale}" \
  --no-cpu-offload
