#!/usr/bin/env bash
# One-shot setup: create the shared venv at ../../python/.venv and install
# operator_xr plus every controller dependency of this example.
# GPU hosts get onnxruntime-gpu; CPU-only hosts get onnxruntime
# (never both). Force CPU with: FORCE_CPU=1 ./setup.sh
set -euo pipefail
EXAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYOPERATOR_DIR="$EXAMPLE_DIR/../../python"
VENV="$PYOPERATOR_DIR/.venv"

if [ ! -x "$VENV/bin/python" ]; then
    python3 -m venv "$VENV"
fi

"$VENV/bin/pip" install -U pip
"$VENV/bin/pip" install -e "$PYOPERATOR_DIR" \
    -r "$EXAMPLE_DIR/requirements-scalebfm.txt"

if [ "${FORCE_CPU:-0}" = "1" ]; then
    SONIC_REQ="$EXAMPLE_DIR/requirements-sonic.txt"
elif command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    SONIC_REQ="$EXAMPLE_DIR/requirements-sonic-gpu.txt"
else
    SONIC_REQ="$EXAMPLE_DIR/requirements-sonic.txt"
fi
"$VENV/bin/pip" install -r "$SONIC_REQ"

"$VENV/bin/python" - <<'EOF'
import mujoco, numpy, onnxruntime, pinocchio, operator_xr, scipy, torch
print("torch cuda:", torch.cuda.is_available())
print("ort providers:", onnxruntime.get_available_providers())
EOF
