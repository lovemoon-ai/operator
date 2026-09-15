#!/usr/bin/env bash
# XR module test harness device runner (WP7).
#
# Installs the test-harness APK (export preset "Meta Quest Test", or "Pico
# Test" with --platform pico; both set operator_feature_test_harness=true),
# launches the in-app test runner via intent extras, watches logcat for
# OPERATOR_TEST_* markers, and pulls the JSON results from the device's
# external files dir.
#
# Hard rules honored: APK build runs in the background (>10 min first
# build); never uses `godot --headless` to run the XR project; requires a
# real Android XR device.
#
# Usage:
#   tests/xr_module_harness.sh --suite capture.pipeline [--case <case_id>]
#       [--platform quest|pico] [--serial <adb_serial>]
#       [--skip-build] [--skip-install] [--timeout <seconds>]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XR_DIR="$ROOT/xr"
PACKAGE="com.lovemoon.operator"
ACTIVITY="com.godot.game.GodotApp"
RESULTS_REMOTE="/sdcard/Android/data/$PACKAGE/files/test_results"
RESULTS_LOCAL="$ROOT/tests/results/xr_module_harness"

SUITE="all"
CASE_ID=""
PLATFORM="quest"
SERIAL=""
SKIP_BUILD=0
SKIP_INSTALL=0
TIMEOUT_S=180

while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite) SUITE="$2"; shift 2 ;;
    --case) CASE_ID="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --serial) SERIAL="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    --timeout) TIMEOUT_S="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$PLATFORM" in
  quest) BUILD_TARGET="build-quest-test"; APK="$XR_DIR/build/quest_test/Operator.apk" ;;
  pico)  BUILD_TARGET="build-pico-test";  APK="$XR_DIR/build/pico_test/Operator.apk" ;;
  *) echo "unknown platform: $PLATFORM (quest|pico)" >&2; exit 2 ;;
esac
BUILD_LOG="$XR_DIR/build/${PLATFORM}_test_build.log"

# Resolve adb the way xr/Makefile does, preferring the SDK's platform-tools.
# This install needs --no-incremental, which only platform-tools >= 30 parses;
# an older distro adb forwards the flag to the device's package manager, which
# aborts with "Unknown option --no-incremental".
ADB_BIN="${ADB:-}"
if [[ -z "$ADB_BIN" ]]; then
  for candidate in "$HOME/Library/Android/sdk/platform-tools/adb" \
                   "$HOME/Android/Sdk/platform-tools/adb"; do
    if [[ -x "$candidate" ]]; then ADB_BIN="$candidate"; break; fi
  done
fi
ADB_BIN="${ADB_BIN:-adb}"
ADB=("$ADB_BIN")
if [[ -n "$SERIAL" ]]; then ADB=("$ADB_BIN" -s "$SERIAL"); fi

echo "== xr_module_harness: suite=$SUITE case=${CASE_ID:-<all>} platform=$PLATFORM"

if ! "${ADB[@]}" get-state >/dev/null 2>&1; then
  echo "ERROR: no adb device available (real Android XR device required)" >&2
  exit 1
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  echo "== building test APK (background, log: $BUILD_LOG)"
  mkdir -p "$XR_DIR/build"
  ( cd "$XR_DIR" && make "$BUILD_TARGET" ) >"$BUILD_LOG" 2>&1 &
  BUILD_PID=$!
  while kill -0 "$BUILD_PID" 2>/dev/null; do
    sleep 10
    echo "   ... build running (pid $BUILD_PID)"
  done
  wait "$BUILD_PID" || { echo "ERROR: test APK build failed; see $BUILD_LOG" >&2; exit 1; }
fi

if [[ ! -f "$APK" ]]; then
  echo "ERROR: test APK not found: $APK (run without --skip-build)" >&2
  exit 1
fi

if [[ "$SKIP_INSTALL" -eq 0 ]]; then
  echo "== installing $APK"
  # --no-incremental: the APK's native libs are Stored (extractNativeLibs=false)
  # and mmap'd from the APK; adb's default incremental install can leave them at
  # a stale offset on reinstall, so MuJoCo fails to load with "bad ELF magic".
  "${ADB[@]}" install --no-incremental -r -d "$APK"
fi

echo "== launching test runner"
"${ADB[@]}" shell am force-stop "$PACKAGE"
"${ADB[@]}" logcat -c
LAUNCH=( shell am start -n "$PACKAGE/$ACTIVITY" --es operator_test_suite "$SUITE" )
if [[ -n "$CASE_ID" ]]; then LAUNCH+=( --es operator_test_case "$CASE_ID" ); fi
"${ADB[@]}" "${LAUNCH[@]}"

echo "== waiting for OPERATOR_TEST_SUITE_DONE (timeout ${TIMEOUT_S}s)"
LOG_FILE="$(mktemp)"
trap 'rm -f "$LOG_FILE"' EXIT
DEADLINE=$(( $(date +%s) + TIMEOUT_S ))
DONE_LINE=""
while [[ $(date +%s) -lt $DEADLINE ]]; do
  "${ADB[@]}" logcat -d > "$LOG_FILE" 2>/dev/null || true
  DONE_LINE="$(grep -a "OPERATOR_TEST_SUITE_DONE suite=$SUITE" "$LOG_FILE" | tail -n 1 || true)"
  if [[ -n "$DONE_LINE" ]]; then break; fi
  sleep 2
done

echo "== test markers:"
grep -a -E "OPERATOR_TEST_(START|PASS|FAIL|SKIP|SUITE_DONE)" "$LOG_FILE" || true

if [[ -z "$DONE_LINE" ]]; then
  echo "ERROR: test runner did not finish within ${TIMEOUT_S}s" >&2
  exit 1
fi

echo "== pulling JSON results"
mkdir -p "$RESULTS_LOCAL"
"${ADB[@]}" pull "$RESULTS_REMOTE" "$RESULTS_LOCAL" >/dev/null 2>&1 \
  || echo "   (no pullable results dir at $RESULTS_REMOTE)"
ls -la "$RESULTS_LOCAL" 2>/dev/null || true

PASS_COUNT="$(sed -E 's/.*pass=([0-9]+).*/\1/' <<<"$DONE_LINE")"
FAIL_COUNT="$(sed -E 's/.*fail=([0-9]+).*/\1/' <<<"$DONE_LINE")"
echo "== done: pass=$PASS_COUNT fail=$FAIL_COUNT"
if [[ "$FAIL_COUNT" != "0" ]]; then
  exit 1
fi
