#!/usr/bin/env python3
"""Operator release version: one number for Rust, Python, C++ and XR.

`VERSION` at the repo root is the source of truth (SemVer: 0.2.0, 0.2.0-rc.1).
Only two other files carry a literal copy, and `set` rewrites both:

  robot/Cargo.toml   [workspace.package] version, inherited by every crate.
                     Python (maturin, `dynamic = ["version"]`) and the C ABI
                     `operator_version()` take their version from here.
  xr/project.godot   application/config/version; the operator-features export
                     plugin turns it into the APK versionName.

cpp/liboperator reads VERSION directly at CMake configure time.

Usage:
  python3 scripts/version.py show
  python3 scripts/version.py set 0.2.0
  python3 scripts/version.py check [--tag v0.2.0]
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSION_FILE = ROOT / "VERSION"
CARGO_TOML = ROOT / "robot" / "Cargo.toml"
PROJECT_GODOT = ROOT / "xr" / "project.godot"

# Pre-release tags are limited to the ones maturin maps onto PEP 440
# (0.2.0-rc.1 -> 0.2.0rc1), so the wheel version always matches.
SEMVER = re.compile(r"^\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.\d+)?$")
CARGO_VERSION = re.compile(r'(\[workspace\.package\]\n(?:.*\n)*?version = ")([^"]*)(")')
GODOT_VERSION = re.compile(r'^(config/version=")([^"]*)(")$', re.M)


def read_version() -> str:
    return VERSION_FILE.read_text().strip()


def _field(path: Path, pattern: re.Pattern[str]) -> str | None:
    match = pattern.search(path.read_text())
    return match.group(2) if match else None


def _replace(path: Path, pattern: re.Pattern[str], version: str) -> None:
    text, count = pattern.subn(lambda m: m.group(1) + version + m.group(3), path.read_text(), count=1)
    if count != 1:
        sys.exit(f"error: no version field found in {path.relative_to(ROOT)}")
    path.write_text(text)


def check(tag: str | None) -> list[str]:
    version = read_version()
    errors = []
    if not SEMVER.match(version):
        errors.append(f"VERSION '{version}' is not MAJOR.MINOR.PATCH[-alpha|beta|rc.N]")
    for path, pattern in ((CARGO_TOML, CARGO_VERSION), (PROJECT_GODOT, GODOT_VERSION)):
        found = _field(path, pattern)
        if found != version:
            errors.append(f"{path.relative_to(ROOT)} has {found!r}, VERSION has {version!r}")
    for crate in sorted((ROOT / "robot" / "crates").glob("*/Cargo.toml")):
        if "\nversion.workspace = true\n" not in crate.read_text():
            errors.append(f"{crate.relative_to(ROOT)} must use `version.workspace = true`")
    if tag is not None and tag != f"v{version}":
        errors.append(f"tag {tag!r} does not match VERSION (expected 'v{version}')")
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("show", help="print the current version")
    set_parser = commands.add_parser("set", help="bump the version everywhere")
    set_parser.add_argument("version")
    check_parser = commands.add_parser("check", help="fail if any component disagrees with VERSION")
    check_parser.add_argument("--tag", help="also require this git tag to be v<VERSION>")
    args = parser.parse_args(argv)

    if args.command == "show":
        print(read_version())
        return 0
    if args.command == "set":
        if not SEMVER.match(args.version):
            parser.error(f"'{args.version}' is not MAJOR.MINOR.PATCH[-alpha|beta|rc.N]")
        VERSION_FILE.write_text(args.version + "\n")
        _replace(CARGO_TOML, CARGO_VERSION, args.version)
        _replace(PROJECT_GODOT, GODOT_VERSION, args.version)
        # Refresh the workspace crates' entries in Cargo.lock only.
        subprocess.run(["cargo", "update", "--workspace"], cwd=ROOT / "robot", check=True)
    errors = check(getattr(args, "tag", None))
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if not errors:
        print(f"version {read_version()} is consistent")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
