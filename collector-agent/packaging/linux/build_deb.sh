#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
version="$(python3 -c 'import pathlib; print(next(line.split(chr(34))[1] for line in pathlib.Path("pyproject.toml").read_text().splitlines() if line.startswith("version = ")))')"
platform_tools_version="${PLATFORM_TOOLS_VERSION:-37.0.1}"
platform_tools_sha256="${PLATFORM_TOOLS_SHA256:-d230f13842f60f782a8645f9c813f8f845bf36089ea7289f28c48f17979313f1}"
build_root="$(mktemp -d)"
trap 'rm -rf "$build_root"' EXIT

python3 -m venv .build-venv
.build-venv/bin/pip install --upgrade pip pyinstaller "imageio-ffmpeg==0.6.0" .
.build-venv/bin/pyinstaller --clean --noconfirm packaging/operator-collector.spec
ffmpeg_binary="$(.build-venv/bin/python -c 'import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())')"

platform_tools="$build_root/platform-tools.zip"
curl --fail --location --retry 3 --output "$platform_tools" \
  "https://dl.google.com/android/repository/platform-tools_r${platform_tools_version}-linux.zip"
printf '%s  %s\n' "$platform_tools_sha256" "$platform_tools" | sha256sum --check --status
unzip -q "$platform_tools" -d "$build_root/android"

package_root="$build_root/operator-collector_${version}_amd64"
tool_root="$package_root/usr/lib/operator-collector/tools"
mkdir -p \
  "$package_root/usr/local/bin" \
  "$package_root/usr/lib/systemd/user" \
  "$tool_root/ffmpeg" \
  "$package_root/DEBIAN"
install -m 0755 dist/operator-collector "$package_root/usr/local/bin/operator-collector"
install -m 0644 packaging/linux/operator-collector.service "$package_root/usr/lib/systemd/user/operator-collector.service"
cp -a "$build_root/android/platform-tools" "$tool_root/platform-tools"
chmod 0755 "$tool_root/platform-tools/adb" "$tool_root/platform-tools/fastboot"
install -m 0755 "$ffmpeg_binary" "$tool_root/ffmpeg/ffmpeg"
install -m 0644 packaging/THIRD_PARTY_NOTICES.txt "$package_root/usr/lib/operator-collector/THIRD_PARTY_NOTICES.txt"

test -x "$package_root/usr/local/bin/operator-collector"
test -x "$tool_root/platform-tools/adb"
test -x "$tool_root/ffmpeg/ffmpeg"

sed "s/@VERSION@/$version/" > "$package_root/DEBIAN/control" <<'EOF'
Package: operator-collector
Version: @VERSION@
Section: utils
Priority: optional
Architecture: amd64
Maintainer: LoveMoon
Description: Operator Quest data collection workstation agent
EOF

mkdir -p dist/installers
dpkg-deb --build "$package_root" "dist/installers/operator-collector_${version}_amd64.deb"
echo "Built dist/installers/operator-collector_${version}_amd64.deb"
