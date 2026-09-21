#!/usr/bin/env bash
# One-shot setup: create examples/light-o1/.venv with pyoperator (editable,
# built from ../../python) and the Sonic G1 host dependencies.
#   VENV=/other/path PYTHON_VERSION=3.11 ./setup.sh
set -euo pipefail
EXAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$EXAMPLE_DIR/../.." && pwd)"
VENV="${VENV:-$EXAMPLE_DIR/.venv}"
PYTHON_VERSION="${PYTHON_VERSION:-3.11}"
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

command -v uv >/dev/null || { echo "install uv first: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2; exit 1; }
command -v cargo >/dev/null || {
    echo "pyoperator's native module is built with maturin and needs Rust:" >&2
    echo "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal" >&2
    exit 1
}

uv venv "$VENV" --python "$PYTHON_VERSION" --seed
uv pip install --python "$VENV/bin/python" -r "$EXAMPLE_DIR/requirements.txt" "pytest>=8"
uv pip install --python "$VENV/bin/python" -e "$REPO/python"
"$VENV/bin/python" - <<'PY'
import mujoco, numpy, onnxruntime, pyoperator
from pyoperator import XrSession  # fails if the native module did not build
print("pyoperator native OK; mujoco", mujoco.__version__, "onnxruntime", onnxruntime.__version__,
      "numpy", numpy.__version__)
PY
echo "ready: $VENV/bin/python $EXAMPLE_DIR/main.py --help"
