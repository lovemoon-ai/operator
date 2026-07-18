#!/usr/bin/env bash
# Make the SO-101 LeRobot teleop environment READY, deterministically.
#
# The device tests 06_so101_lerobot_device.sh and 07_so101_synthetic_teleop.sh
# (and the manual example examples/quest_so101_teleop_manual.sh) drive a real
# SO-101 through LeRobot's `lerobot-teleoperate` + the out-of-tree `vr_operator`
# plugin. That needs three things in place before the test can run:
#
#   1. a Python env with `lerobot[kinematics]` and the `vr_operator` plugin,
#   2. the serial port the arm is actually plugged into,
#   3. the SO-101 URDF (LeRobot does not vendor it).
#
# Historically the operator had to hand-build a venv, remember to `pip install -e`
# the plugin, and pass SO101_PORT / SO101_URDF by hand. This script removes all
# of that: it owns a uv-managed venv, auto-detects the port, and locates the URDF.
#
# Two ways to use it:
#
#   * Sourced (how 06/07 use it) -- prepares the env and EXPORTS the results into
#     the caller's shell (PATH gets the venv, plus SO101_PORT / SO101_URDF /
#     PYTHON / LEROBOT_VENV). The caller then needs no env vars set:
#
#         source cicd/prepare_lerobot_so101.sh
#
#   * Executed standalone -- does the same setup and prints a summary, so you can
#     provision / re-provision the env on its own:
#
#         bash cicd/prepare_lerobot_so101.sh
#
# Knobs (all optional -- the whole point is that none are required):
#   SO101_PORT            force a serial port instead of auto-detecting
#   SO101_URDF            force a URDF path instead of searching known locations
#   LEROBOT_VENV          venv location            (default: cicd/.lerobot-venv)
#   LEROBOT_PYTHON        interpreter uv builds on  (default: 3.12)
#   LEROBOT_PREPARE_FORCE=1   reinstall even if the stamp says it's current
#   SKIP_LEROBOT_PREPARE=1    do nothing (env already provisioned out-of-band)

# --- sourced-vs-executed -----------------------------------------------------
# Errors must `return` when sourced (so we don't kill the operator's shell) and
# `exit` when executed. All work lives in a function that only ever `return`s;
# the trampoline at the bottom converts that to the right thing.

_lerobot_prepare_main() {
  # Resolve our own location so this works regardless of the caller's cwd.
  local self="${BASH_SOURCE[0]}"
  local here root
  here="$(cd "$(dirname "$self")" && pwd)"
  root="$(cd "$here/.." && pwd)"

  local plugin_dir="$root/plugins/lerobot-teleop/python"
  local venv="${LEROBOT_VENV:-$root/cicd/.lerobot-venv}"
  local py_ver="${LEROBOT_PYTHON:-3.12}"
  local venv_py="$venv/bin/python"
  local stamp="$venv/.prepare-stamp"

  _p_log()  { printf '\033[35m[prepare-lerobot]\033[0m %s\n' "$*" >&2; }
  _p_fail() { printf '\033[31m[prepare-lerobot] FAIL:\033[0m %s\n' "$*" >&2; return 1; }

  if [ "${SKIP_LEROBOT_PREPARE:-0}" = "1" ]; then
    _p_log "SKIP_LEROBOT_PREPARE=1 -- assuming the env is already provisioned"
    return 0
  fi

  command -v uv >/dev/null 2>&1 \
    || { _p_fail "uv is not on PATH. Install it: https://docs.astral.sh/uv/ (brew install uv)"; return 1; }

  [ -d "$plugin_dir" ] || { _p_fail "plugin dir missing: $plugin_dir"; return 1; }

  # --- 1. the Python env ------------------------------------------------------
  #
  # A single `uv pip install -e <plugin>` drags in `lerobot[kinematics]` (its
  # declared dependency), so we do not install lerobot separately. The install
  # is the slow part, so it is gated behind a stamp: we only reinstall when the
  # plugin's pyproject changes, the venv is missing/broken, or FORCE is set.

  local want_stamp
  want_stamp="$(_lerobot_stamp "$plugin_dir/pyproject.toml")"

  local need_install=0
  if [ "${LEROBOT_PREPARE_FORCE:-0}" = "1" ]; then
    need_install=1
    _p_log "LEROBOT_PREPARE_FORCE=1 -- reinstalling"
  elif [ ! -x "$venv_py" ]; then
    need_install=1
    _p_log "no venv at $venv -- creating it"
  elif [ ! -x "$venv/bin/lerobot-teleoperate" ]; then
    need_install=1
    _p_log "venv exists but lerobot-teleoperate is missing -- (re)installing"
  elif [ ! -f "$stamp" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$want_stamp" ]; then
    need_install=1
    _p_log "plugin definition changed since last install -- updating"
  fi

  if [ "$need_install" = "1" ]; then
    if [ ! -x "$venv_py" ]; then
      _p_log "creating venv on Python $py_ver (uv will fetch it if needed)"
      uv venv --python "$py_ver" "$venv" >&2 \
        || { _p_fail "uv venv failed"; return 1; }
    fi
    _p_log "installing lerobot[kinematics] + vr_operator plugin (first run downloads a lot)"
    uv pip install --python "$venv_py" -e "$plugin_dir" >&2 \
      || { _p_fail "dependency install failed"; return 1; }
    # The plugin only declares lerobot[kinematics] (it does IK, not the bus), but
    # 06/07 drive `so101_follower` directly and lerobot-teleoperate talks to the
    # Feetech bus -- both need the `feetech` extra (feetech-servo-sdk). Install it
    # explicitly so the device path is actually runnable, not just importable.
    uv pip install --python "$venv_py" "lerobot[feetech]" >&2 \
      || { _p_fail "installing lerobot[feetech] failed"; return 1; }
    printf '%s' "$want_stamp" > "$stamp"
    _p_log "install complete"
  else
    _p_log "env is up to date ($venv)"
  fi

  # Make the venv authoritative for this process onward.
  export LEROBOT_VENV="$venv"
  export PATH="$venv/bin:$PATH"
  export PYTHON="$venv_py"

  # Verify the things the tests actually reach for, rather than trusting the
  # stamp blindly. Importing `lerobot.scripts.lerobot_teleoperate` here does
  # double duty: it proves the entry point loads (cv2/torch/placo all present)
  # AND it PRE-WARMS those heavy imports + the OS page cache. That matters: the
  # very first `lerobot-teleoperate` start is >30s cold, which overruns 06's 30s
  # Hello-handshake window and fails the test. Paying that cost here -- before
  # the test's handshake clock starts -- makes the first real run start warm.
  command -v lerobot-teleoperate >/dev/null 2>&1 \
    || { _p_fail "lerobot-teleoperate still not on PATH after install"; return 1; }
  _p_log "verifying + pre-warming lerobot imports (first cold run can take ~30s)"
  "$venv_py" - <<'PY' >&2 || { _p_fail "lerobot/vr_operator import check failed in the venv"; return 1; }
import importlib, sys
try:
    importlib.import_module("lerobot_teleoperator_vr_operator")
    importlib.import_module("lerobot.robots.so_follower")
    importlib.import_module("scservo_sdk")  # feetech bus SDK the device path needs
    # The exact entry lerobot-teleoperate runs -- pulls in cv2/torch/placo and
    # warms them so the plugin starts inside 06's handshake window.
    importlib.import_module("lerobot.scripts.lerobot_teleoperate")
except Exception as e:  # pragma: no cover - diagnostic path
    sys.exit(f"import check failed: {e}")
PY

  # --- 2. the serial port -----------------------------------------------------
  local port
  port="$(_lerobot_detect_port)" || return 1
  export SO101_PORT="$port"

  # --- 3. the URDF ------------------------------------------------------------
  local urdf
  urdf="$(_lerobot_detect_urdf "$root")" || return 1
  export SO101_URDF="$urdf"

  _p_log "READY"
  _p_log "  venv : $venv"
  _p_log "  port : $SO101_PORT"
  _p_log "  urdf : $SO101_URDF"
  return 0
}

# Stamp = interpreter version + a hash of the plugin's dependency declaration.
# Change either and the next run reinstalls; touch nothing and it is a no-op.
_lerobot_stamp() {
  local pyproject="$1" hash
  if command -v shasum >/dev/null 2>&1; then
    hash="$(shasum -a 256 "$pyproject" 2>/dev/null | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    hash="$(sha256sum "$pyproject" 2>/dev/null | awk '{print $1}')"
  else
    hash="$(wc -c < "$pyproject" 2>/dev/null | tr -d ' ')"
  fi
  printf 'v2|py=%s|%s' "${LEROBOT_PYTHON:-3.12}" "$hash"
}

# Find the serial port the SO-101 is on. Honors an explicit SO101_PORT; otherwise
# scans the conventional device nodes. On macOS a device appears as BOTH
# /dev/tty.usbmodemXXXX and /dev/cu.usbmodemXXXX -- the same physical port -- so
# we look at the tty.* nodes only (what LeRobot's examples use) and fall back to
# cu.* only if no tty.* exists, to avoid counting one arm as two.
_lerobot_detect_port() {
  if [ -n "${SO101_PORT:-}" ]; then
    if [ -e "$SO101_PORT" ]; then
      printf '%s' "$SO101_PORT"
      return 0
    fi
    printf '\033[31m[prepare-lerobot] FAIL:\033[0m SO101_PORT=%s was set but that device is not present\n' "$SO101_PORT" >&2
    return 1
  fi

  local list=() p
  # macOS USB-serial (preferred): tty.usbmodem / tty.usbserial
  for p in /dev/tty.usbmodem* /dev/tty.usbserial*; do [ -e "$p" ] && list+=("$p"); done
  # macOS callout twins, only if no tty.* matched
  if [ ${#list[@]} -eq 0 ]; then
    for p in /dev/cu.usbmodem* /dev/cu.usbserial*; do [ -e "$p" ] && list+=("$p"); done
  fi
  # Linux
  if [ ${#list[@]} -eq 0 ]; then
    for p in /dev/ttyACM* /dev/ttyUSB*; do [ -e "$p" ] && list+=("$p"); done
  fi

  if [ ${#list[@]} -eq 0 ]; then
    printf '\033[31m[prepare-lerobot] FAIL:\033[0m no SO-101 serial port found.\n' >&2
    printf '  Plug the arm in over USB, or set SO101_PORT=/dev/... explicitly.\n' >&2
    return 1
  fi
  if [ ${#list[@]} -gt 1 ]; then
    printf '\033[31m[prepare-lerobot] FAIL:\033[0m more than one serial device is present; cannot pick one:\n' >&2
    printf '    %s\n' "${list[@]}" >&2
    printf '  Set SO101_PORT=/dev/... to the SO-101 and re-run.\n' >&2
    return 1
  fi
  printf '%s' "${list[0]}"
  return 0
}

# Locate the SO-101 URDF. Honors an explicit SO101_URDF; otherwise checks the
# LeRobot download cache first (where lerobot-teleoperate looks by default) and
# then the copy vendored in this repo's examples.
_lerobot_detect_urdf() {
  local root="$1"
  if [ -n "${SO101_URDF:-}" ]; then
    if [ -f "$SO101_URDF" ]; then
      printf '%s' "$SO101_URDF"
      return 0
    fi
    printf '\033[31m[prepare-lerobot] FAIL:\033[0m SO101_URDF=%s was set but the file does not exist\n' "$SO101_URDF" >&2
    return 1
  fi

  local candidates=(
    "$HOME/.cache/huggingface/lerobot/robot-urdfs/so101/so101_new_calib.urdf"
    "$root/examples/mujuco-arm-so101/assets/so101/so101_new_calib.urdf"
    "$root/xr/assets/mujoco/so101_new_calib.urdf"
  )
  local c
  for c in "${candidates[@]}"; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done

  printf '\033[31m[prepare-lerobot] FAIL:\033[0m so101_new_calib.urdf not found.\n' >&2
  printf '  Looked in:\n' >&2
  printf '    %s\n' "${candidates[@]}" >&2
  printf '  Fetch it from the SO-ARM100 repo and set SO101_URDF, or run a lerobot\n' >&2
  printf '  command once to populate the cache.\n' >&2
  return 1
}

# --- trampoline --------------------------------------------------------------
# `&& ... || ...` so a non-zero return does not trip the caller's `set -e`
# before we can capture and re-surface it deliberately below.
_lerobot_prepare_main && _lerobot_prepare_rc=0 || _lerobot_prepare_rc=$?
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  # sourced: hand the exit code back to the caller without killing their shell
  return "$_lerobot_prepare_rc"
else
  exit "$_lerobot_prepare_rc"
fi
