#!/usr/bin/env python3
"""Static validator for the XR feature test manifests (WP7).

Runs on the host, no Godot required. Checks:
  (1) every operator_feature_* id in the feature registry has a manifest at
      xr/tests/manifests/features/<id>.json;
  (2) manifests are well-formed: id/feature/owner present, feature equals
      operator_feature_<id>;
  (3) required_features reference known operator_feature_* names;
  (4) required_capabilities reference known SensorCapability names;
  (5) referenced fixtures exist under xr/tests/fixtures/**/<id>.json;
  (6) referenced test scripts (res://...) exist on disk;
  (7) test case levels are known, case ids unique per manifest;
  (8) every feature has at least one static preset_matrix case and one
      integration case;
  (9) production presets (names without "Test") set
      operator_feature_test_harness=false.

Exits non-zero with itemized errors.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
XR = ROOT / "xr"
MANIFEST_DIR = XR / "tests" / "manifests" / "features"
FIXTURES_DIR = XR / "tests" / "fixtures"
OPERATOR_FEATURE = XR / "scripts" / "contracts" / "features" / "operator_feature.gd"
SENSOR_CAPABILITY = XR / "scripts" / "contracts" / "platform" / "sensor_capability.gd"
PRESETS = XR / "export_presets.cfg"

KNOWN_LEVELS = {"static", "contract", "unit", "integration", "device", "e2e"}


def parse_feature_ids():
    """Feature id strings from operator_feature.gd's _ID_TO_STRING map."""
    text = OPERATOR_FEATURE.read_text()
    const_vals = dict(re.findall(r"^const (\w+) := (\d+)$", text, re.M))
    ids = []
    for m in re.finditer(r"(\w+):\s*\"(\w+)\"", text):
        if m.group(1) in const_vals:
            ids.append(m.group(2))
    return ids


def parse_capability_names():
    text = SENSOR_CAPABILITY.read_text()
    const_vals = dict(re.findall(r"^const (\w+) := (\d+)$", text, re.M))
    names = set()
    for m in re.finditer(r"(\w+):\s*\"(\w+)\"", text):
        if m.group(1) in const_vals:
            names.add(m.group(2))
    return names


def fixture_exists(fixture_id):
    return any(FIXTURES_DIR.glob("**/%s.json" % fixture_id))


def res_path_exists(res_path):
    if not res_path.startswith("res://"):
        return False
    return (XR / res_path[len("res://"):]).exists()


def check_presets(errors):
    text = PRESETS.read_text()
    presets = {}
    current = None
    in_options = None
    for line in text.splitlines():
        line = line.strip()
        m = re.match(r"^\[preset\.(\d+)\]$", line)
        if m:
            current = int(m.group(1))
            presets.setdefault(current, {"name": "", "harness": None})
            in_options = None
            continue
        m = re.match(r"^\[preset\.(\d+)\.options\]$", line)
        if m:
            in_options = int(m.group(1))
            presets.setdefault(in_options, {"name": "", "harness": None})
            continue
        if line.startswith("["):
            in_options = None
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key, value = key.strip(), value.strip()
        if in_options is not None and key == "operator_feature_test_harness":
            presets[in_options]["harness"] = value.lower() == "true"
        elif current is not None and in_options is None and key == "name":
            presets[current]["name"] = value.strip('"')
    for idx, preset in sorted(presets.items()):
        pname = preset["name"] or "preset.%d" % idx
        if preset["harness"] is None:
            errors.append("(9) preset '%s' missing operator_feature_test_harness" % pname)
        elif "Test" not in pname and preset["harness"]:
            errors.append(
                "(9) production preset '%s' enables operator_feature_test_harness" % pname)


def main():
    errors = []
    for path in (MANIFEST_DIR, OPERATOR_FEATURE, SENSOR_CAPABILITY, PRESETS):
        if not path.exists():
            print("ERROR: missing path: %s" % path, file=sys.stderr)
            return 1

    feature_ids = parse_feature_ids()
    feature_options = {"operator_feature_%s" % fid for fid in feature_ids}
    capability_names = parse_capability_names()
    if not feature_ids:
        errors.append("no feature ids parsed from operator_feature.gd")
    if not capability_names:
        errors.append("no capability names parsed from sensor_capability.gd")

    manifest_files = {p.stem: p for p in MANIFEST_DIR.glob("*.json")}

    # (1) coverage both ways
    for fid in feature_ids:
        if fid not in manifest_files:
            errors.append("(1) feature '%s' has no test manifest" % fid)
    for stem in sorted(manifest_files):
        if stem not in feature_ids:
            errors.append("(1) manifest '%s.json' does not match a known feature" % stem)

    total_cases = 0
    for stem, path in sorted(manifest_files.items()):
        try:
            doc = json.loads(path.read_text())
        except json.JSONDecodeError as exc:
            errors.append("(2) %s: invalid JSON: %s" % (path.name, exc))
            continue
        if doc.get("id") != stem:
            errors.append("(2) %s: id '%s' must equal file stem" % (path.name, doc.get("id")))
        if doc.get("feature") != "operator_feature_%s" % stem:
            errors.append("(2) %s: feature must be operator_feature_%s" % (path.name, stem))
        if not doc.get("owner"):
            errors.append("(2) %s: missing owner" % path.name)
        for req in doc.get("required_features", []):
            if req not in feature_options:
                errors.append("(3) %s: unknown required feature '%s'" % (path.name, req))
        for cap in doc.get("required_capabilities", []):
            if str(cap).lower() not in capability_names:
                errors.append("(4) %s: unknown capability '%s'" % (path.name, cap))

        cases = doc.get("test_cases", [])
        seen_ids = set()
        has_static_matrix = False
        has_integration = False
        for case in cases:
            total_cases += 1
            cid = case.get("id", "")
            if not cid:
                errors.append("(7) %s: test case missing id" % path.name)
            elif cid in seen_ids:
                errors.append("(7) %s: duplicate case id '%s'" % (path.name, cid))
            seen_ids.add(cid)
            level = case.get("level", "")
            if level not in KNOWN_LEVELS:
                errors.append("(7) %s: case '%s' unknown level '%s'" % (path.name, cid, level))
            if level == "static" and case.get("preset_matrix"):
                has_static_matrix = True
            if level == "integration":
                has_integration = True
            fixture = case.get("fixture")
            if fixture and not fixture_exists(fixture):
                errors.append("(5) %s: case '%s' references missing fixture '%s'"
                              % (path.name, cid, fixture))
            script = case.get("script")
            if script and not res_path_exists(script):
                errors.append("(6) %s: case '%s' references missing script '%s'"
                              % (path.name, cid, script))
        if not has_static_matrix:
            errors.append("(8) %s: needs at least one static preset_matrix case" % path.name)
        if not has_integration:
            errors.append("(8) %s: needs at least one integration case" % path.name)

    check_presets(errors)

    if errors:
        print("validate_xr_test_manifests: FAILED (%d errors)" % len(errors), file=sys.stderr)
        for err in errors:
            print("  - %s" % err, file=sys.stderr)
        return 1
    print("validate_xr_test_manifests: OK (%d manifests, %d cases)"
          % (len(manifest_files), total_cases))
    return 0


if __name__ == "__main__":
    sys.exit(main())
