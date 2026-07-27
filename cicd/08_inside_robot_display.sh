#!/usr/bin/env bash
# Inside Robot display gate: every robot this build ships must start and
# materialise its embodiment on a real headset.
#
# One app launch per robot, which is how an operator uses Teleop — the in-app
# harness case (teleop.inside) can only cover one robot per run, because
# instantiating several robots inside a single frame loads tens of MB of meshes
# at once and kills the renderer.
#
# Requires an installed test//release APK and a connected device.
#
# Usage:
#   bash cicd/08_inside_robot_display.sh [--serial <adb_serial>]
#       [--backend native|remote] [--settle <seconds>] [--screenshots <dir>]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="com.lovemoon.operator"
ACTIVITY="com.godot.game.GodotApp"
PROFILE_DIR="$ROOT/xr/assets/robot_profiles"

SERIAL=""
BACKEND="native"
SETTLE_S=25
SHOT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial) SERIAL="$2"; shift 2 ;;
    --backend) BACKEND="$2"; shift 2 ;;
    --settle) SETTLE_S="$2"; shift 2 ;;
    --screenshots) SHOT_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

ADB=(adb)
if [[ -n "$SERIAL" ]]; then ADB=(adb -s "$SERIAL"); fi

if ! "${ADB[@]}" get-state >/dev/null 2>&1; then
  echo "ERROR: no adb device available (real Android XR device required)" >&2
  exit 1
fi

mapfile -t PROFILES < <(ls "$PROFILE_DIR"/*.json | xargs -n1 basename | sed 's/\.json$//' | sort)
if [[ ${#PROFILES[@]} -eq 0 ]]; then
  echo "ERROR: no robot profiles in $PROFILE_DIR" >&2
  exit 1
fi

echo "== inside robot display: ${#PROFILES[@]} profiles, backend=$BACKEND"
[[ -n "$SHOT_DIR" ]] && mkdir -p "$SHOT_DIR"

FAILED=()
SKIPPED=()

for profile in "${PROFILES[@]}"; do
  printf '%-14s ' "$profile"
  attempt=0
  while :; do
  attempt=$(( attempt + 1 ))
  "${ADB[@]}" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
  # Let the OS reclaim the previous robot's meshes; launching back-to-back
  # pushed the headset into memory pressure and killed the next launch.
  sleep 3
  "${ADB[@]}" logcat -c >/dev/null 2>&1 || true
  "${ADB[@]}" shell am start -n "$PACKAGE/$ACTIVITY" \
    --es operator.mode teleop \
    --es operator.teleop.scope inside \
    --es operator.teleop.profile "$profile" \
    --es operator.teleop.backend "$BACKEND" >/dev/null 2>&1 || true

  # Poll for an outcome instead of judging after a fixed sleep: a robot that
  # loads slowly is not a failure, and a crash should be reported at once.
  verdict=""
  detail=""
  deadline=$(( SECONDS + SETTLE_S ))
  while [[ $SECONDS -lt $deadline ]]; do
    sleep 3
    log="$("${ADB[@]}" logcat -d 2>/dev/null || true)"
    # Scope strictly to the MuJoCo lib: an incremental `adb install -r -d` over
    # the same versionCode can leave it at the wrong offset ("bad ELF magic:
    # 504b0304"), which breaks every simulated robot. The optional pinocchio
    # stub also fails to load, harmlessly, so it must not be matched here.
    if grep -aqE "godot_mujoco.*bad ELF magic|Can't open (dynamic library: addons/godot_mujoco|GDExtension dynamic library: 'res://addons/godot_mujoco)" <<<"$log"; then
      verdict="FAIL"; detail="corrupt MuJoCo lib — uninstall and reinstall the APK"; break
    fi
    if grep -aqE "overlay_unusable|overlay_missing|native_retargeting_(unavailable|contract_missing)" <<<"$log"; then
      verdict="FAIL"; detail="embodiment could not load"; break
    fi
    if grep -aq "unknown_profile" <<<"$log"; then
      verdict="SKIP"; detail="not offered by this build"; break
    fi
    if grep -aqE "Fatal signal|has died: fg" <<<"$log"; then
      verdict="FAIL"; detail="native crash"; break
    fi
    if grep -aq "Inside Robot ready" <<<"$log"; then
      verdict="ok"
      detail="$(grep -aoE "\[[A-Za-z0-9]+Overlay\] ready: [0-9]+ link|MujocoMeshView\] bound [0-9]+|Model loaded [a-z0-9_]+ backend=native_mujoco" <<<"$log" | tail -1)"
      break
    fi
  done

  if [[ -z "$verdict" ]]; then
    verdict="FAIL"; detail="never reached READY within ${SETTLE_S}s"
  fi
  # One retry: a heavy robot launched right after another can lose the race
  # with the OS reclaiming the previous process, which is a device condition
  # rather than a fault of this robot.
  if [[ "$verdict" == "FAIL" && $attempt -lt 2 ]]; then
    sleep 10
    continue
  fi
  break
  done
  if [[ "$verdict" == "ok" && -z "$("${ADB[@]}" shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r' || true)" ]]; then
    verdict="FAIL"; detail="process died after start"
  fi

  case "$verdict" in
    ok)   echo "ok ${detail:-(simulation view)}" ;;
    SKIP) echo "SKIP ($detail)"; SKIPPED+=("$profile") ;;
    *)    echo "FAIL ($detail)"; FAILED+=("$profile: $detail") ;;
  esac

  if [[ -n "$SHOT_DIR" && "$verdict" == "ok" ]]; then
    # READY fires before the embodiment is placed in front of the operator;
    # capturing immediately photographs an empty room.
    sleep 6
    "${ADB[@]}" exec-out screencap -p > "$SHOT_DIR/$profile.png" 2>/dev/null || true
  fi
done

echo
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo "skipped: ${SKIPPED[*]}"
fi
if [[ ${#FAILED[@]} -gt 0 ]]; then
  printf 'FAILED:\n'
  printf '  %s\n' "${FAILED[@]}"
  exit 1
fi
echo "== all offered robots start and display"
