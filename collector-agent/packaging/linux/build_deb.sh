#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
version="$(python3 -c 'import pathlib; print(next(line.split(chr(34))[1] for line in pathlib.Path("pyproject.toml").read_text().splitlines() if line.startswith("version = ")))')"
build_root="$(mktemp -d)"
trap 'rm -rf "$build_root"' EXIT

python3 -m venv .build-venv
.build-venv/bin/pip install --upgrade pip pyinstaller .
.build-venv/bin/pyinstaller --clean --noconfirm packaging/operator-collector.spec

package_root="$build_root/operator-collector_${version}_amd64"
mkdir -p "$package_root/usr/local/bin" "$package_root/usr/lib/systemd/user" "$package_root/DEBIAN"
install -m 0755 dist/operator-collector "$package_root/usr/local/bin/operator-collector"
install -m 0644 packaging/linux/operator-collector.service "$package_root/usr/lib/systemd/user/operator-collector.service"

sed "s/@VERSION@/$version/" > "$package_root/DEBIAN/control" <<'EOF'
Package: operator-collector
Version: @VERSION@
Section: utils
Priority: optional
Architecture: amd64
Maintainer: LoveMoon
Depends: adb, ffmpeg
Description: Operator Quest data collection workstation agent
EOF

mkdir -p dist/installers
dpkg-deb --build "$package_root" "dist/installers/operator-collector_${version}_amd64.deb"
echo "Built dist/installers/operator-collector_${version}_amd64.deb"
