#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
version="$(python3 -c 'import pathlib; print(next(line.split(chr(34))[1] for line in pathlib.Path("pyproject.toml").read_text().splitlines() if line.startswith("version = ")))')"
platform_tools_version="${PLATFORM_TOOLS_VERSION:-37.0.1}"
platform_tools_sha256="${PLATFORM_TOOLS_SHA256:-ee39ad5967e95c2a07f04dbcbde96b1a0c916ba376096db5d2f498b7727a5d1d}"
build_root="$(mktemp -d)"
trap 'rm -rf "$build_root"' EXIT

python3 -m venv .build-venv
.build-venv/bin/pip install --upgrade pip pyinstaller "imageio-ffmpeg==0.6.0" .
.build-venv/bin/pyinstaller --clean --noconfirm packaging/operator-collector.spec
ffmpeg_binary="$(.build-venv/bin/python -c 'import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())')"

platform_tools="$build_root/platform-tools.zip"
curl --fail --location --retry 3 --output "$platform_tools" \
  "https://dl.google.com/android/repository/platform-tools_r${platform_tools_version}-darwin.zip"
printf '%s  %s\n' "$platform_tools_sha256" "$platform_tools" | shasum -a 256 --check --status
unzip -q "$platform_tools" -d "$build_root/android"

payload="$build_root/payload"
tool_root="$payload/usr/local/lib/operator-collector/tools"
mkdir -p \
  "$payload/usr/local/bin" \
  "$payload/Library/LaunchAgents" \
  "$tool_root/ffmpeg"
install -m 0755 dist/operator-collector "$payload/usr/local/bin/operator-collector"
install -m 0644 packaging/macos/com.lovemoon.operator-collector.plist \
  "$payload/Library/LaunchAgents/com.lovemoon.operator-collector.plist"
cp -a "$build_root/android/platform-tools" "$tool_root/platform-tools"
chmod 0755 "$tool_root/platform-tools/adb" "$tool_root/platform-tools/fastboot"
install -m 0755 "$ffmpeg_binary" "$tool_root/ffmpeg/ffmpeg"
install -m 0644 packaging/THIRD_PARTY_NOTICES.txt "$payload/usr/local/lib/operator-collector/THIRD_PARTY_NOTICES.txt"
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$payload"
fi

test -x "$payload/usr/local/bin/operator-collector"
test -x "$tool_root/platform-tools/adb"
test -x "$tool_root/ffmpeg/ffmpeg"

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
