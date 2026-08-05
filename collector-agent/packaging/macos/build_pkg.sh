#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
version="$(python3 -c 'import pathlib; print(next(line.split(chr(34))[1] for line in pathlib.Path("pyproject.toml").read_text().splitlines() if line.startswith("version = ")))')"
build_root="$(mktemp -d)"
trap 'rm -rf "$build_root"' EXIT

python3 -m venv .build-venv
.build-venv/bin/pip install --upgrade pip pyinstaller .
.build-venv/bin/pyinstaller --clean --noconfirm packaging/operator-collector.spec

payload="$build_root/payload"
mkdir -p "$payload/usr/local/bin" "$payload/Library/LaunchAgents"
install -m 0755 dist/operator-collector "$payload/usr/local/bin/operator-collector"
install -m 0644 packaging/macos/com.lovemoon.operator-collector.plist \
  "$payload/Library/LaunchAgents/com.lovemoon.operator-collector.plist"
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$payload"
fi

mkdir -p dist/installers
COPYFILE_DISABLE=1 pkgbuild \
  --root "$payload" \
  --filter '(^|/)\._' \
  --filter '(^|/)\.DS_Store$' \
  --identifier com.lovemoon.operator-collector \
  --version "$version" \
  --install-location / \
  "dist/installers/OperatorCollector-${version}-unsigned.pkg"

echo "Built dist/installers/OperatorCollector-${version}-unsigned.pkg"
echo "Set DEVELOPER_ID_INSTALLER and run productsign before distribution."
