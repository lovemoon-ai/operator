#!/usr/bin/env python3
"""Static validator for the operator_feature_* export-preset feature system.

Runs on the host, no Godot required. Checks:
  (a) every declared operator_feature_* option is present in every Android
      [preset.N.options] section;
  (b) no unknown operator_feature_* option appears in presets;
  (c) feature dependency/conflict rules are satisfied per preset;
  (d) production presets (names not containing "Test") set
      operator_feature_test_harness=false;
  (e) the export-plugin FEATURE_OPTIONS table matches the runtime
      feature registry table (name + default);
  (f) no retired operator_launcher_card_* option lingers in a preset.

Exits non-zero with itemized errors.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PRESETS = ROOT / "xr" / "export_presets.cfg"
EXPORT_PLUGIN = ROOT / "xr" / "addons" / "operator_features" / "export_plugin.gd"
REGISTRY = ROOT / "xr" / "scripts" / "contracts" / "features" / "feature_registry.gd"
OPERATOR_FEATURE = ROOT / "xr" / "scripts" / "contracts" / "features" / "operator_feature.gd"

# The operator_launcher plugin and its operator_launcher_card_* options were
# retired: launcher cards are plain operator_feature_mode_* features now.
# Rule (f) keeps the old options from creeping back in.
RETIRED_OPTION_PREFIX = "operator_launcher_card_"


def parse_presets(text):
    """Return {preset_index: {"name": str, "options": {key: raw_value}}}."""
    presets = {}
    current = None
    in_options = None
    for line in text.splitlines():
        line = line.strip()
        m = re.match(r"^\[preset\.(\d+)\]$", line)
        if m:
            current = int(m.group(1))
            presets.setdefault(current, {"name": "", "options": {}})
            in_options = None
            continue
        m = re.match(r"^\[preset\.(\d+)\.options\]$", line)
        if m:
            in_options = int(m.group(1))
            presets.setdefault(in_options, {"name": "", "options": {}})
            continue
        if line.startswith("["):
            in_options = None
            continue
        if "=" not in line or not line:
            continue
        key, _, value = line.partition("=")
        key, value = key.strip(), value.strip()
        if in_options is not None:
            presets[in_options]["options"][key] = value
        elif current is not None and key == "name":
            presets[current]["name"] = value.strip('"')
    return presets


def parse_bool(raw):
    return raw.strip().lower() == "true"


def parse_plugin_table(text):
    """Parse FEATURE_OPTIONS entries from export_plugin.gd -> {name: default}."""
    table = {}
    for m in re.finditer(
        r'\{\s*"name":\s*"(operator_feature_\w+)",\s*"default":\s*(true|false)\s*\}', text
    ):
        table[m.group(1)] = m.group(2) == "true"
    return table


def parse_registry(text):
    """Parse FeatureDefinition.create(...) calls -> list of dicts.

    Returns entries: {option, default, requires:[option,...], conflicts:[...]}.
    """
    id_map = parse_id_map()
    entries = []
    # Match each FeatureDefinition.create( ... ) block (non-greedy across lines)
    for m in re.finditer(r"FeatureDefinition\.create\(\s*(.*?)\)\)", text, re.S):
        args = m.group(1)
        idm = re.search(r"OperatorFeature\.(\w+)\s*,\s*(true|false)", args)
        if not idm:
            continue
        const_name, default = idm.group(1), idm.group(2) == "true"
        feature_id = id_map.get(const_name)
        if feature_id is None:
            continue
        entry = {
            "option": "operator_feature_%s" % feature_id,
            "default": default,
            "requires": [],
            "conflicts": [],
        }
        # robot_constraint passes a named requires var; resolve known pattern
        if "robot_constraint_requires" in args:
            entry["requires"] = ["operator_feature_robot_control"]
        for rm in re.finditer(r"\[OperatorFeature\.(\w+)\]", args):
            req = id_map.get(rm.group(1))
            if req:
                entry["requires"].append("operator_feature_%s" % req)
        entry["requires"] = sorted(set(entry["requires"]))
        entries.append(entry)
    return entries


def parse_id_map():
    """OperatorFeature const name -> feature id string, from operator_feature.gd."""
    text = OPERATOR_FEATURE.read_text()
    id_map = {}
    const_vals = dict(re.findall(r"^const (\w+) := (\d+)$", text, re.M))
    for m in re.finditer(r"(\w+):\s*\"(\w+)\"", text):
        if m.group(1) in const_vals:
            id_map[m.group(1)] = m.group(2)
    return id_map


def main():
    errors = []
    for path in (PRESETS, EXPORT_PLUGIN, REGISTRY, OPERATOR_FEATURE):
        if not path.exists():
            print("ERROR: missing file: %s" % path, file=sys.stderr)
            return 1

    plugin_table = parse_plugin_table(EXPORT_PLUGIN.read_text())
    registry = parse_registry(REGISTRY.read_text())
    registry_table = {e["option"]: e["default"] for e in registry}
    presets = parse_presets(PRESETS.read_text())

    if not plugin_table:
        errors.append("export_plugin.gd: no FEATURE_OPTIONS entries parsed")
    if not registry:
        errors.append("feature_registry.gd: no FeatureDefinition.create entries parsed")

    # (e) plugin table matches registry table
    for name, default in sorted(plugin_table.items()):
        if name not in registry_table:
            errors.append("(e) plugin declares %s but registry does not" % name)
        elif registry_table[name] != default:
            errors.append(
                "(e) default mismatch for %s: plugin=%s registry=%s"
                % (name, default, registry_table[name])
            )
    for name in sorted(registry_table):
        if name not in plugin_table:
            errors.append("(e) registry declares %s but plugin does not" % name)

    declared = set(plugin_table)

    for idx in sorted(presets):
        preset = presets[idx]
        pname = preset["name"] or "preset.%d" % idx
        options = preset["options"]
        feature_opts = {k: v for k, v in options.items() if k.startswith("operator_feature_")}

        # (a) every declared feature explicitly present
        for name in sorted(declared):
            if name not in options:
                errors.append("(a) preset '%s' missing option %s" % (pname, name))
        # (b) no unknown operator_feature_* options
        for name in sorted(feature_opts):
            if name not in declared:
                errors.append("(b) preset '%s' has unknown option %s" % (pname, name))

        enabled = {k: parse_bool(v) for k, v in feature_opts.items() if k in declared}

        # (c) dependencies/conflicts
        for entry in registry:
            if not enabled.get(entry["option"], False):
                continue
            for req in entry["requires"]:
                if not enabled.get(req, False):
                    errors.append(
                        "(c) preset '%s': %s requires %s" % (pname, entry["option"], req)
                    )
            for conflict in entry["conflicts"]:
                if enabled.get(conflict, False):
                    errors.append(
                        "(c) preset '%s': %s conflicts with %s"
                        % (pname, entry["option"], conflict)
                    )

        # (d) production presets must disable the test harness
        if "Test" not in pname:
            if enabled.get("operator_feature_test_harness", False):
                errors.append(
                    "(d) production preset '%s' enables operator_feature_test_harness" % pname
                )

        # (f) retired launcher-card options must not reappear
        for name in sorted(options):
            if name.startswith(RETIRED_OPTION_PREFIX):
                errors.append(
                    "(f) preset '%s' has retired option %s (use operator_feature_mode_* instead)"
                    % (pname, name)
                )

    if errors:
        print("validate_xr_features: FAILED (%d errors)" % len(errors), file=sys.stderr)
        for err in errors:
            print("  - %s" % err, file=sys.stderr)
        return 1
    print(
        "validate_xr_features: OK (%d features, %d Android presets)"
        % (len(declared), len(presets))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
