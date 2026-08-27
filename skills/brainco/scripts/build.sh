#!/usr/bin/env bash
# build.sh — compile the BrainCo tools against the bc-stark-sdk.
#
# Run this ON the robot (the SDK ships prebuilt .so per arch; there is no
# cross-compile path). Copy the scripts over first:
#   scp scripts/*.cpp unitree@<robot>:~/brainco_tools/
#
# Usage:
#   ./build.sh                      # auto-locate the SDK, build everything
#   SDK=/path/to/brainco_hand_service ./build.sh
#   ./build.sh detect_hand          # just one target
set -euo pipefail
cd "$(dirname "$0")"

# The SDK lives inside Unitree's brainco_hand_service checkout, not in a system
# prefix. Take the first one that has both a header and a lib for this arch.
if [[ -z "${SDK:-}" ]]; then
  for c in "$HOME"/workspace/*/brainco_hand_service; do
    [[ -f "$c/include/stark-sdk.h" ]] && SDK="$c" && break
  done
fi
[[ -n "${SDK:-}" && -f "$SDK/include/stark-sdk.h" ]] || {
  echo "stark-sdk.h not found. Set SDK=/path/to/brainco_hand_service" >&2
  echo "  try: find ~ -name stark-sdk.h 2>/dev/null" >&2; exit 1; }

LIB="$SDK/lib/$(uname -m)"
[[ -f "$LIB/libbc_stark_sdk.so" ]] || { echo "no libbc_stark_sdk.so in $LIB" >&2; exit 1; }
echo "SDK: $SDK  ($(uname -m))"

# -Wl,-rpath so the binary finds the .so without LD_LIBRARY_PATH every run.
targets=("$@")
[[ ${#targets[@]} -eq 0 ]] && targets=(detect_hand grasp_log)
for t in "${targets[@]}"; do
  [[ -f "$t.cpp" ]] || { echo "skip $t (no $t.cpp here)"; continue; }
  g++ -std=c++17 -O2 -o "$t" "$t.cpp" \
      -I"$SDK/include" -L"$LIB" -lbc_stark_sdk -Wl,-rpath,"$LIB" -lpthread
  echo "built ./$t"
done
