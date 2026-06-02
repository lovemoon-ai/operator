#!/usr/bin/env bash
# End-to-end video pipeline test using a local RTSP stream.
#
# Components, in dependency order:
#
#   ffmpeg  -- testsrc2 1280x720@30 H.264 publisher
#       │
#       ▼ rtsp://127.0.0.1:8554/test
#   mediamtx -- standalone RTSP server (sink + source)
#       │
#       ▼ rtsp://127.0.0.1:8554/test (xr-bridge pulls)
#   xr-bridge --video-only --config tests/configs/bridge_video.yaml
#       │   - relays the RTSP NALs over the XR wire protocol
#       │   - broadcasts mDNS `_xrobo._tcp.local.` and UDP discovery on :63900
#       │   - listens on :12345 (video) + :63901 (pose/cmd) for the headset
#       │
#       ▼ Quest 3 (same Wi-Fi) discovers + connects automatically
#   Quest app (org.xrobotoolkit.client)
#       - MediaCodec decodes H.264 NALs
#       - AHB zero-copy path renders into the OpenXR swapchain
#       - logs `[LiveVideo] AHB stats: frames=N post_decode=… rx_to_present=…`
#
# Pass criteria: the Quest reports ≥30 decoded frames within --frame-wait
# seconds after the app is up. Default --frame-wait is 20s.
#
# Usage:
#   bash tests/rtsp_test.sh                    # full e2e, requires app already launchable
#   bash tests/rtsp_test.sh --launch-app       # also start the Quest activity
#   bash tests/rtsp_test.sh --skip-build       # don't rebuild xr-bridge
#   bash tests/rtsp_test.sh --frame-wait 30    # wait up to 30s for frames
#   bash tests/rtsp_test.sh --codec hevc       # publish H.265 (libx265) instead of H.264
#   bash tests/rtsp_test.sh --keep             # keep mediamtx/ffmpeg/xr-bridge running after test
#
# Requirements (auto-checked at startup):
#   - ffmpeg (with libx264; libx265 too for --codec hevc)
#   - mediamtx  (brew install mediamtx)
#   - adb (with a Quest device attached, in developer mode)
#   - cargo (only if --skip-build is not used)
#   - Quest and Mac on the same Wi-Fi (mDNS / UDP broadcast discovery)
#   - Quest app already installed and signed in to handle OpenXR
#
# Stop with Ctrl-C — every spawned process is killed via the EXIT trap
# unless --keep is given.

set -euo pipefail

# --- Paths -------------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="org.xrobotoolkit.client"
ACT="com.godot.game.GodotApp"
RTSP_URL="rtsp://127.0.0.1:8554/test"
LOG_DIR="$ROOT/tests/logs/rtsp-$(date +%Y%m%d-%H%M%S)"

# --- Args --------------------------------------------------------------------
LAUNCH_APP=0
SKIP_BUILD=0
FRAME_WAIT=20
KEEP=0
MIN_FRAMES=30
# Codec under test. h264 (default) publishes libx264 + bridge_video.yaml;
# hevc publishes libx265 and uses bridge_video_hevc.yaml (feed codec: hevc),
# exercising the video/hevc MediaCodec path on the headset.
CODEC=h264

usage() {
    sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    exit "${1:-0}"
}

while (("$#")); do
    case "$1" in
    --launch-app) LAUNCH_APP=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --frame-wait) FRAME_WAIT="$2"; shift 2 ;;
    --min-frames) MIN_FRAMES="$2"; shift 2 ;;
    --codec) CODEC="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h | --help) usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage 1 ;;
    esac
done

case "$CODEC" in
h264) CFG="$ROOT/tests/configs/bridge_video.yaml" ;;
hevc) CFG="$ROOT/tests/configs/bridge_video_hevc.yaml" ;;
*) echo "unknown --codec: $CODEC (use h264 or hevc)" >&2; exit 1 ;;
esac

# --- Pretty logging ---------------------------------------------------------
if [ -t 1 ]; then
    BOLD=$(tput bold); GREEN=$(tput setaf 2); RED=$(tput setaf 1)
    YELLOW=$(tput setaf 3); BLUE=$(tput setaf 4); DIM=$(tput dim); RESET=$(tput sgr0)
else
    BOLD=""; GREEN=""; RED=""; YELLOW=""; BLUE=""; DIM=""; RESET=""
fi
step() { echo; echo "${BOLD}${BLUE}▶ $*${RESET}"; }
ok()   { echo "  ${GREEN}✓${RESET} $*"; }
warn() { echo "  ${YELLOW}!${RESET} $*"; }
err()  { echo "  ${RED}✗${RESET} $*" >&2; }
note() { echo "  ${DIM}$*${RESET}"; }

# --- Process bookkeeping (clean shutdown) -----------------------------------
declare -a CLEANUP_PIDS=()
PID_MEDIAMTX=""
PID_FFMPEG=""
PID_BRIDGE=""

cleanup() {
    local rc=$?
    if [ "$KEEP" = "1" ] && [ "$rc" = "0" ]; then
        echo
        warn "--keep set: leaving the pipeline running:"
        [ -n "$PID_MEDIAMTX" ] && note "  mediamtx     pid=$PID_MEDIAMTX"
        [ -n "$PID_FFMPEG"   ] && note "  ffmpeg       pid=$PID_FFMPEG"
        [ -n "$PID_BRIDGE"   ] && note "  xr-bridge    pid=$PID_BRIDGE"
        note "  logs in: $LOG_DIR"
        return
    fi
    if ((${#CLEANUP_PIDS[@]} > 0)); then
        echo
        step "Cleanup"
        for pid in "${CLEANUP_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
                ok "killed pid=$pid"
            fi
        done
        sleep 0.5
        # belt-and-braces: pkill anything matching our process patterns so a
        # previous run's leftovers don't survive either
        pkill -f "mediamtx" 2>/dev/null || true
        pkill -f "ffmpeg.*rtsp://127\\.0\\.0\\.1:8554/test" 2>/dev/null || true
        pkill -f "xr-bridge.*--video-only" 2>/dev/null || true
    fi
    # Stop the Quest app — only if we were the one who launched it, so a
    # human-started session isn't disturbed. Skip on --keep so the operator
    # can keep playing with the live pipeline after a pass.
    if [ "$LAUNCH_APP" = "1" ]; then
        if adb shell "pidof $PKG" 2>/dev/null | grep -q '[0-9]'; then
            adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
            ok "stopped Quest app ($PKG)"
        fi
    fi
    if [ "$rc" != "0" ]; then
        echo
        err "FAIL (exit $rc) — logs in $LOG_DIR"
    fi
}
trap cleanup EXIT INT TERM

track() {
    CLEANUP_PIDS+=("$1")
}

# --- Pre-flight -------------------------------------------------------------
step "Pre-flight"

for tool in ffmpeg mediamtx adb; do
    if ! command -v "$tool" >/dev/null; then
        err "missing tool: $tool"
        case "$tool" in
        ffmpeg)   note "  brew install ffmpeg" ;;
        mediamtx) note "  brew install mediamtx" ;;
        adb)      note "  brew install --cask android-platform-tools" ;;
        esac
        exit 1
    fi
done
ok "ffmpeg, mediamtx, adb on PATH"

if [ ! -f "$CFG" ]; then
    err "config not found: $CFG"
    exit 1
fi
ok "config: $CFG"

DEVICE=$(adb devices | awk 'NR>1 && $2=="device"{print $1}' | head -1)
if [ -z "$DEVICE" ]; then
    err "no adb device attached"
    note "  plug in your Quest 3, enable developer mode, allow USB debug"
    exit 1
fi
ok "adb device: $DEVICE"

if [ "$LAUNCH_APP" = "1" ]; then
    if ! adb shell pm path "$PKG" >/dev/null 2>&1; then
        err "$PKG not installed on device"
        note "  cd xr && make build-install"
        exit 1
    fi
    ok "app installed on $DEVICE"
fi

# Stale-process sweep before we spawn fresh ones. Anything from a previous
# rtsp_test.sh run would steal ports 8554 / 12345 / 63901.
for pat in "mediamtx" "ffmpeg.*rtsp://127\\.0\\.0\\.1:8554/test" "xr-bridge.*--video-only"; do
    if pgrep -f "$pat" >/dev/null 2>&1; then
        warn "killing stale: $pat"
        pkill -f "$pat" 2>/dev/null || true
    fi
done
sleep 0.5

mkdir -p "$LOG_DIR"
ok "log dir: $LOG_DIR"

# --- Build xr-bridge --------------------------------------------------------
if [ "$SKIP_BUILD" = "0" ]; then
    step "Build xr-bridge (release)"
    (cd "$ROOT/robot" && cargo build --release -p xr-bridge --quiet 2>&1 | tee "$LOG_DIR/cargo-build.log")
    ok "built"
else
    note "skip-build set; using existing binary"
fi

XB="$ROOT/robot/target/release/xr-bridge"
if [ ! -x "$XB" ]; then
    err "xr-bridge binary not found at $XB — drop --skip-build or run cargo build first"
    exit 1
fi

# --- 1. mediamtx (RTSP server) ----------------------------------------------
step "1/4  mediamtx (RTSP server on :8554)"

# mediamtx 1.18+ refuses publishers to paths that aren't pre-declared
# ("path 'test' is not configured"). Write a minimal config that opens
# `all_others` so the ffmpeg publisher and the xr-bridge consumer can both
# reach `rtsp://127.0.0.1:8554/test` without further setup.
MTX_CFG="$LOG_DIR/mediamtx.yml"
cat > "$MTX_CFG" <<'YML'
logLevel: info
# Open every path for publish + read. Loopback only — see the rtsp/rtsps
# address fields if you want to restrict the bind.
paths:
  all_others:
YML

mediamtx "$MTX_CFG" > "$LOG_DIR/mediamtx.log" 2>&1 &
PID_MEDIAMTX=$!
track $PID_MEDIAMTX
sleep 1

if ! kill -0 $PID_MEDIAMTX 2>/dev/null; then
    err "mediamtx died on startup"
    tail -20 "$LOG_DIR/mediamtx.log" | sed 's/^/    /'
    exit 1
fi

# Confirm the RTSP port is actually open.
for i in 1 2 3 4 5; do
    if nc -z 127.0.0.1 8554 2>/dev/null; then break; fi
    sleep 0.5
done
if ! nc -z 127.0.0.1 8554 2>/dev/null; then
    err "mediamtx not listening on :8554"
    exit 1
fi
ok "mediamtx pid=$PID_MEDIAMTX listening :8554"

# --- 2. ffmpeg publisher ----------------------------------------------------
step "2/4  ffmpeg publisher (testsrc2 1280x720@30 $CODEC → $RTSP_URL)"

# `-re` paces real-time, `-tune zerolatency`/`-preset ultrafast` keep encoder
# delay minimal, `-bf 0` keeps the bitstream MediaCodec-friendly.
# `-rtsp_transport tcp` so RTP doesn't drop frames over the loopback (UDP
# loopback is unreliable on some macOS configs). The encoder + RTSP codec flip
# with --codec; the bridge stream-copies whatever it receives.
if [ "$CODEC" = "hevc" ]; then
    # libx265: re-emit VPS/SPS/PPS at each IDR (repeat-headers) so a headset
    # joining mid-stream is primed. `-tag:v hvc1` keeps the RTSP/MediaCodec
    # side on the standard HEVC sample entry.
    VENC=(-c:v libx265 -preset ultrafast -tune zerolatency
        -x265-params "keyint=30:min-keyint=30:repeat-headers=1:bframes=0"
        -tag:v hvc1)
else
    VENC=(-c:v libx264 -preset ultrafast -tune zerolatency -profile:v baseline -bf 0)
fi
ffmpeg -hide_banner -loglevel warning -nostats \
    -re -f lavfi -i "testsrc2=size=1280x720:rate=30" \
    -an "${VENC[@]}" -pix_fmt yuv420p -g 30 \
    -f rtsp -rtsp_transport tcp "$RTSP_URL" \
    > "$LOG_DIR/ffmpeg.log" 2>&1 &
PID_FFMPEG=$!
track $PID_FFMPEG
sleep 2

if ! kill -0 $PID_FFMPEG 2>/dev/null; then
    err "ffmpeg died on startup"
    tail -20 "$LOG_DIR/ffmpeg.log" | sed 's/^/    /'
    exit 1
fi

# Confirm the stream is actually flowing through mediamtx.
if grep -qiE "publisher|publish" "$LOG_DIR/mediamtx.log" 2>/dev/null; then
    ok "ffmpeg pid=$PID_FFMPEG publishing (mediamtx accepted)"
else
    warn "mediamtx hasn't logged a publisher yet — continuing anyway"
fi

# --- 3. xr-bridge --video-only ---------------------------------------------
step "3/4  xr-bridge --video-only --config $(basename "$CFG")"

# Some macOS / WiFi setups silently drop subnet-broadcast packets between
# clients (Wi-Fi client isolation, mDNS/Bonjour multicast filter, AP isolation,
# etc.). To bypass that we sniff the Quest's wlan0 IP via adb and pass it to
# xr-bridge as a unicast discovery target. The bridge will keep doing
# broadcast too — unicast is just a belt-and-braces fallback.
QUEST_IP=$(adb shell ip -4 addr show wlan0 2>/dev/null \
    | awk '/inet /{print $2}' | cut -d/ -f1 | head -1 | tr -d '\r')
EXTRA_BRIDGE_CFG="$LOG_DIR/bridge_extra.yaml"
if [ -n "$QUEST_IP" ]; then
    # Build a derivative YAML that adds discovery_unicast_targets without
    # mutating the user-tracked test config.
    awk -v ip="$QUEST_IP" '
        /^[[:space:]]*video:[[:space:]]*$/ {
            print "  discovery_unicast_targets:"
            print "    - " ip
        }
        { print }
    ' "$CFG" > "$EXTRA_BRIDGE_CFG"
    note "  Quest wlan0 IP: $QUEST_IP — added as unicast discovery target"
    BRIDGE_CFG_USED="$EXTRA_BRIDGE_CFG"
else
    warn "couldn't read Quest's wlan0 IP via adb — using broadcast-only discovery"
    BRIDGE_CFG_USED="$CFG"
fi

RUST_LOG=info "$XB" --video-only --config "$BRIDGE_CFG_USED" \
    > "$LOG_DIR/xr-bridge.log" 2>&1 &
PID_BRIDGE=$!
track $PID_BRIDGE
sleep 2

if ! kill -0 $PID_BRIDGE 2>/dev/null; then
    err "xr-bridge died on startup"
    tail -40 "$LOG_DIR/xr-bridge.log" | sed 's/^/    /'
    exit 1
fi

# Wait for the "video-only network up" log line, but cap the wait so a
# misconfigured bridge doesn't hang the test.
for i in $(seq 1 10); do
    if grep -q "XR video-only network up" "$LOG_DIR/xr-bridge.log" 2>/dev/null; then
        break
    fi
    sleep 0.5
done
if grep -q "XR video-only network up" "$LOG_DIR/xr-bridge.log" 2>/dev/null; then
    ok "xr-bridge pid=$PID_BRIDGE up; mDNS+UDP discovery broadcasting"
    grep "XR video-only network up" "$LOG_DIR/xr-bridge.log" | head -1 | sed 's/^/    /'
else
    warn "xr-bridge didn't print 'video-only network up' — last few lines:"
    tail -10 "$LOG_DIR/xr-bridge.log" | sed 's/^/    /'
fi

# Set adb reverse for the TCP ports so a USB-only Quest can also reach the
# bridge at 127.0.0.1. UDP discovery still needs Wi-Fi, but once the user has
# picked the bridge in manual mode this lets video/pose flow.
adb reverse tcp:12345 tcp:12345 >/dev/null
adb reverse tcp:63901 tcp:63901 >/dev/null
adb reverse tcp:63903 tcp:63903 >/dev/null 2>&1 || true
ok "adb reverse: 12345 (video), 63901 (pose), 63903 (telemetry)"

# --- 4. Quest app + frame observation --------------------------------------
step "4/4  Quest app + frame observation"

adb logcat -c >/dev/null

if [ "$LAUNCH_APP" = "1" ]; then
    adb shell am force-stop "$PKG"
    sleep 0.3
    adb shell am start -n "$PKG/$ACT" >/dev/null
    ok "app launched"
    sleep 5
else
    if adb shell "pidof $PKG" 2>/dev/null | tr -d '\r' | grep -q '[0-9]'; then
        ok "app already running"
    else
        warn "app not running; either start it on Quest or rerun with --launch-app"
        warn "the test will still watch for frames in case you start it manually"
    fi
fi

# Poll logcat for the AHB frame counter. We accept any line of the form
# `[LiveVideo] AHB stats: frames=N …` with N >= $MIN_FRAMES.
echo
echo "  waiting up to ${FRAME_WAIT}s for ≥${MIN_FRAMES} decoded frames…"
echo
RESULT=fail
LAST_STAT=""

deadline=$(( $(date +%s) + FRAME_WAIT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    line=$(adb logcat -d -t 200 2>/dev/null | grep -E "\[LiveVideo\] AHB stats: frames=" | tail -1 || true)
    if [ -n "$line" ]; then
        LAST_STAT="$line"
        n=$(echo "$line" | sed -n 's/.*frames=\([0-9][0-9]*\).*/\1/p')
        if [ -n "$n" ] && [ "$n" -ge "$MIN_FRAMES" ]; then
            RESULT=pass
            break
        fi
    fi
    sleep 1
done

# Capture context for the report file regardless of outcome.
adb logcat -d -t 2000 2>/dev/null \
    | grep -E "OpenXR|godot|LiveVideo|TcpHandler|Discovery|AhbVideo|TrackingProvider" \
    > "$LOG_DIR/quest-logcat.txt" 2>&1 || true

echo
if [ "$RESULT" = "pass" ]; then
    ok "PASS — Quest received decoded video"
    echo "    last stat:"
    echo "    $(echo "$LAST_STAT" | sed 's/^.*godot   *: *//')"
else
    err "FAIL — no AHB frame stats within ${FRAME_WAIT}s"
    if [ -n "$LAST_STAT" ]; then
        echo "    last stat seen (below threshold):"
        echo "    $(echo "$LAST_STAT" | sed 's/^.*godot   *: *//')"
    fi
    echo "    last 15 lines of quest logcat:"
    tail -15 "$LOG_DIR/quest-logcat.txt" 2>/dev/null | sed 's/^/      /'
fi

# --- Summary ----------------------------------------------------------------
echo
step "Summary"
note "  mediamtx log:  $LOG_DIR/mediamtx.log"
note "  ffmpeg log:    $LOG_DIR/ffmpeg.log"
note "  xr-bridge log: $LOG_DIR/xr-bridge.log"
note "  quest logcat:  $LOG_DIR/quest-logcat.txt"
echo

if [ "$RESULT" = "pass" ]; then
    exit 0
else
    exit 1
fi
