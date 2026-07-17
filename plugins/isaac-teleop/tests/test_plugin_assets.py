from __future__ import annotations

import hashlib
from pathlib import Path


PLUGIN_ROOT = Path(__file__).resolve().parents[1]


def _read_schema_lock() -> dict[str, str]:
    entries: dict[str, str] = {}
    for line in (PLUGIN_ROOT / "schema" / "SCHEMA.lock").read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        entries[key] = value
    return entries


def test_schema_snapshot_matches_lock() -> None:
    lock = _read_schema_lock()
    schemas = sorted((PLUGIN_ROOT / "schema").glob("*.fbs"))
    assert schemas
    for schema in schemas:
        digest = hashlib.sha256(schema.read_bytes()).hexdigest()
        assert lock[schema.name] == digest


def test_upstream_patch_is_pinned_to_same_revision() -> None:
    manifest = (PLUGIN_ROOT / "plugin.toml").read_text()
    lock = _read_schema_lock()
    assert f'isaac_teleop_tag = "{lock["upstream_tag"]}"' in manifest
    assert f'isaac_teleop_commit = "{lock["upstream_commit"]}"' in manifest
    assert (PLUGIN_ROOT / "upstream" / "0001-teleop-session-external-mode.patch").is_file()

