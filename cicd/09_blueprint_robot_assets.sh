#!/usr/bin/env bash
# Download/import a real host MuJoCo G1 on a headset, never an APK model.
# PYTHON=/path/to/python bash cicd/09_blueprint_robot_assets.sh \
#   --model /path/to/g1_29dof.xml --serial SERIAL [--platform pico] [--skip-build]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL=""
SERIAL=""
PLATFORM=pico
SKIP_BUILD=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) MODEL="$2"; shift 2 ;;
        --serial) SERIAL="$2"; shift 2 ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=(--skip-build); shift ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ -n "$MODEL" && -f "$MODEL" && -n "$SERIAL" ]] || { echo "--model and --serial are required" >&2; exit 2; }
TEST_DIR="$(mktemp -d -t operator-robot-assets.XXXXXX)"
ASSET_PORT=""
REVERSE_CREATED=0
PYTHON="${PYTHON:-python3}"
PYTHONPATH="$ROOT/python${PYTHONPATH:+:$PYTHONPATH}" "$PYTHON" "$ROOT/examples/whole-body-control/serve_asset_test.py" \
    --model "$MODEL" --config "$TEST_DIR/config.json" > "$TEST_DIR/server.log" 2>&1 &
ASSET_PID=$!
cleanup() {
    if [[ "$REVERSE_CREATED" -eq 1 ]]; then adb -s "$SERIAL" reverse --remove "tcp:$ASSET_PORT" >/dev/null 2>&1 || true; fi
    kill "$ASSET_PID" 2>/dev/null || true
    wait "$ASSET_PID" 2>/dev/null || true
    echo "Asset test diagnostics: $TEST_DIR"
}
trap cleanup EXIT
for _attempt in $(seq 1 30); do
    [[ -f "$TEST_DIR/config.json" ]] && break
    kill -0 "$ASSET_PID" 2>/dev/null || { cat "$TEST_DIR/server.log"; exit 1; }
    sleep 1
done
[[ -f "$TEST_DIR/config.json" ]] || { echo "Asset server startup timed out" >&2; exit 1; }
ASSET_PORT="$(jq -r '.properties.asset_port' "$TEST_DIR/config.json")"
adb -s "$SERIAL" reverse --no-rebind "tcp:$ASSET_PORT" "tcp:$ASSET_PORT"
REVERSE_CREATED=1
adb -s "$SERIAL" push "$TEST_DIR/config.json" /sdcard/Android/data/com.lovemoon.operator/files/robot_asset_test.json
bash "$ROOT/cicd/xr_module_harness.sh" --platform "$PLATFORM" --serial "$SERIAL" \
    --suite blueprint.robot --timeout 180 "${SKIP_BUILD[@]}"
