#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fake_adb="$tmp_dir/adb"
state_file="$tmp_dir/pidof-count"

cat >"$fake_adb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  "shell am force-stop "*) exit 0 ;;
  "logcat -c") exit 0 ;;
  "shell am start "*) exit 0 ;;
  "shell pidof "*)
    count=0
    [[ -f "$FAKE_ADB_STATE" ]] && count=$(<"$FAKE_ADB_STATE")
    count=$((count + 1))
    printf '%s\n' "$count" >"$FAKE_ADB_STATE"
    [[ "$count" -ge 3 ]] && printf '4242\r\n'
    exit 0
    ;;
  "logcat --pid=4242 -v brief")
    printf 'godot ready\n'
    exit 0
    ;;
  *)
    printf 'unexpected adb arguments: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$fake_adb"

if ! output=$(FAKE_ADB_STATE="$state_file" make -s -C "$repo_dir" ship-fast \
  MODE=pose_inference ADB="$fake_adb" 2>&1); then
  printf '%s\n' "$output" >&2
  exit 1
fi

grep -q -- 'tailing logcat for pid 4242' <<<"$output"
[[ $(<"$state_file") -eq 3 ]]
printf 'PASS: ship-fast waited for the app PID\n'
