#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

version="$(python3 -c 'import pathlib; print(next(line.split(chr(34))[1] for line in pathlib.Path("pyproject.toml").read_text().splitlines() if line.startswith("version = ")))')"
python_embed_version="${PYTHON_EMBED_VERSION:-3.11.9}"
python_embed_sha256="${PYTHON_EMBED_SHA256:-009d6bf7e3b2ddca3d784fa09f90fe54336d5b60f0e0f305c37f400bf83cfd3b}"
platform_tools_version="${PLATFORM_TOOLS_VERSION:-37.0.1}"
platform_tools_sha256="${PLATFORM_TOOLS_SHA256:-45f4d63113e895ebde0c90f194099a4676b6ac653bd28d54314a9e022bbc1a99}"
work_root="$(mktemp -d /tmp/operator-collector-windows.XXXXXX)"
trap 'rm -rf "$work_root"' EXIT

tools_root="$work_root/tools"
downloads="$work_root/downloads"
bundle="$work_root/bundle"
build_venv="$work_root/build-venv"
mkdir -p \
  "$tools_root" \
  "$downloads" \
  "$bundle/Lib/site-packages" \
  "$bundle/tools/ffmpeg"

(
  cd "$downloads"
  apt-get download nsis nsis-common
)
for package in "$downloads"/*.deb; do
  dpkg-deb -x "$package" "$tools_root"
done

python_embed="$downloads/python-${python_embed_version}-embed-amd64.zip"
curl --fail --location --retry 3 --output "$python_embed" \
  "https://www.python.org/ftp/python/${python_embed_version}/python-${python_embed_version}-embed-amd64.zip"
printf '%s  %s\n' "$python_embed_sha256" "$python_embed" | sha256sum --check --status
unzip -q "$python_embed" -d "$bundle"

cp -a src/operator_collector "$bundle/Lib/site-packages/operator_collector"
python3 -m venv "$build_venv"
"$build_venv/bin/pip" install --disable-pip-version-check \
  --target "$bundle/Lib/site-packages" \
  --platform win_amd64 \
  --python-version 3.11 \
  --implementation cp \
  --abi cp311 \
  --only-binary=:all: \
  "modelscope-hub==0.1.8" \
  "imageio-ffmpeg==0.6.0"

platform_tools="$downloads/platform-tools.zip"
curl --fail --location --retry 3 --output "$platform_tools" \
  "https://dl.google.com/android/repository/platform-tools_r${platform_tools_version}-win.zip"
printf '%s  %s\n' "$platform_tools_sha256" "$platform_tools" | sha256sum --check --status
unzip -q "$platform_tools" -d "$bundle/tools"

ffmpeg_binary="$(find "$bundle/Lib/site-packages/imageio_ffmpeg/binaries" -type f -name '*.exe' -print -quit)"
test -n "$ffmpeg_binary"
install -m 0755 \
  "$ffmpeg_binary" \
  "$bundle/tools/ffmpeg/ffmpeg.exe"
install -m 0644 packaging/THIRD_PARTY_NOTICES.txt "$bundle/THIRD_PARTY_NOTICES.txt"
install -m 0644 packaging/windows/runtime/python311._pth "$bundle/python311._pth"
install -m 0644 packaging/windows/runtime/operator-collector.cmd "$bundle/operator-collector.cmd"
install -m 0644 packaging/windows/runtime/operator-collector-background.vbs "$bundle/operator-collector-background.vbs"
install -m 0644 packaging/windows/runtime/operator-collector-stop.ps1 "$bundle/operator-collector-stop.ps1"

test -f "$bundle/tools/platform-tools/adb.exe"
test -f "$bundle/tools/ffmpeg/ffmpeg.exe"
test -f "$bundle/python.exe"
test -f "$bundle/Lib/site-packages/modelscope_hub/__init__.py"

mkdir -p dist/installers
output_file="$(pwd)/dist/installers/OperatorCollector-${version}-unsigned-setup.exe"
NSISDIR="$tools_root/usr/share/nsis" "$tools_root/usr/bin/makensis" \
  -DAPP_VERSION="$version" \
  -DBUNDLE_DIR="$bundle" \
  -DOUTPUT_FILE="$output_file" \
  packaging/windows/operator-collector-cross.nsi

echo "Built $output_file"
