#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

version="$(python3 -c 'import pathlib; print(next(line.split(chr(34))[1] for line in pathlib.Path("pyproject.toml").read_text().splitlines() if line.startswith("version = ")))')"
python_embed_version="${PYTHON_EMBED_VERSION:-3.11.9}"
python_embed_sha256="${PYTHON_EMBED_SHA256:-009d6bf7e3b2ddca3d784fa09f90fe54336d5b60f0e0f305c37f400bf83cfd3b}"
work_root="$(mktemp -d /tmp/operator-collector-windows.XXXXXX)"
trap 'rm -rf "$work_root"' EXIT

tools_root="$work_root/tools"
downloads="$work_root/downloads"
bundle="$work_root/bundle"
mkdir -p "$tools_root" "$downloads" "$bundle/Lib/site-packages"

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
install -m 0644 packaging/windows/runtime/python311._pth "$bundle/python311._pth"
install -m 0644 packaging/windows/runtime/operator-collector.cmd "$bundle/operator-collector.cmd"
install -m 0644 packaging/windows/runtime/operator-collector-background.vbs "$bundle/operator-collector-background.vbs"
install -m 0644 packaging/windows/runtime/operator-collector-stop.ps1 "$bundle/operator-collector-stop.ps1"

mkdir -p dist/installers
output_file="$(pwd)/dist/installers/OperatorCollector-${version}-unsigned-setup.exe"
NSISDIR="$tools_root/usr/share/nsis" "$tools_root/usr/bin/makensis" \
  -DAPP_VERSION="$version" \
  -DBUNDLE_DIR="$bundle" \
  -DOUTPUT_FILE="$output_file" \
  packaging/windows/operator-collector-cross.nsi

echo "Built $output_file"
