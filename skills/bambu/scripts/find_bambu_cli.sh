#!/usr/bin/env bash
set -euo pipefail

repo="https://github.com/DuinoDu/bambu-cli.git"
ref="feat/cloud-printing-and-headless-slicing"

declare -a candidates=()
if [[ -n "${BAMBU_CLI:-}" ]]; then
  candidates+=("$BAMBU_CLI")
fi
if command -v bambu-cli >/dev/null 2>&1; then
  candidates+=("$(command -v bambu-cli)")
fi
candidates+=(
  "$HOME/opt/bambu-cli/bin/bambu-cli"
  "$HOME/ws/bambu-cli/build/bambu-cli"
  "$HOME/ws/bambu-cli/bambu-cli"
)

declare -A seen=()
for candidate in "${candidates[@]}"; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  [[ -z "${seen[$candidate]:-}" ]] || continue
  seen[$candidate]=1

  help="$($candidate --help 2>&1 || true)"
  if [[ "$help" == *"cloud doctor"* && "$help" == *"slice"* ]]; then
    printf '%s\n' "$candidate"
    exit 0
  fi
done

cat >&2 <<EOF
No bambu-cli binary with cloud and slice support was found.

Source: $repo
Ref:    $ref

Build and install only after the user approves installation or update:
  git clone --branch $ref --single-branch $repo /tmp/bambu-cli-src
  cd /tmp/bambu-cli-src
  make test
  make install PREFIX="\$HOME/opt/bambu-cli"
EOF
exit 1

