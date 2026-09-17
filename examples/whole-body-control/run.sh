#!/usr/bin/env bash
set -euo pipefail
EXAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SONIC_SITE="$EXAMPLE_DIR/../../python/.venv/lib/python3.10/site-packages"
export LD_LIBRARY_PATH="$SONIC_SITE/onnxruntime/capi:$SONIC_SITE/nvidia/cudnn/lib:$SONIC_SITE/nvidia/cublas/lib:$SONIC_SITE/nvidia/cuda_runtime/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
PYTHON="$EXAMPLE_DIR/../../python/.venv/bin/python"

run_sonic () {
    $PYTHON $EXAMPLE_DIR/main.py \
      --controller sonic \
      --upstream /home/duino/ws/GR00T-WholeBodyControl \
      --checkpoint /home/duino/ws/GR00T-WholeBodyControl/gear_sonic_deploy/policy/sonic_v1_1 \
      --device cuda
}

run_scalebfm () {
    SCALEBFM_CACHE=/home/duino/.cache/operator
    $PYTHON $EXAMPLE_DIR/main.py \
      --controller scalebfm \
      --backend torchscript \
      --device cpu \
      --tracking local \
      --checkpoint "$SCALEBFM_CACHE/models/scalebfm/model_22200_torchscript_cpu.pt" \
      --model "$SCALEBFM_CACHE/scalebfm/ScaleBFM/ScaleBridge/scalebridge/data/robot/g1_29dof/g1_29dof.xml"
      # --checkpoint "$SCALEBFM_CACHE/models/scalebfm/model_22200_torchscript_cpu.pt" \
      # --checkpoint "$SCALEBFM_CACHE/models/scalebfm/model_22200_torchscript_cuda.pt" \
}
