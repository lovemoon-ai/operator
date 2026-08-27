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
  (f) no retired operator_launcher_card_* option lingers in a preset;
  (g) robot profiles and baked GLBs ship, while source URDF/mesh trees do not.
  (h) every preset has one valid quick-entry value whose mode feature is on.
  (i) each Teleop preset stays a faithful derivation of its base preset, and
      the build never rewrites export_presets.cfg to get there.
  (j) nothing a Teleop preset keeps references something it excludes, by
      res:// path or by a global class_name only the excluded file declares.
  (k) every non-Pico preset excludes the Pico GDExtension at the resource
      filter stage, before Godot generates .godot/extension_list.cfg.

Exits non-zero with itemized errors.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
XR_DIR = ROOT / "xr"
PRESETS = ROOT / "xr" / "export_presets.cfg"
EXPORT_PLUGIN = ROOT / "xr" / "addons" / "operator_features" / "export_plugin.gd"
REGISTRY = ROOT / "xr" / "scripts" / "contracts" / "features" / "feature_registry.gd"
OPERATOR_FEATURE = ROOT / "xr" / "scripts" / "contracts" / "features" / "operator_feature.gd"
QUICK_ENTRY_CONFIG = (
    ROOT / "xr" / "scripts" / "app" / "launcher" / "quick_entry_config.gd"
)
XR_MAKEFILE = ROOT / "xr" / "Makefile"
MODE_SELECT = ROOT / "xr" / "scripts" / "app" / "launcher" / "mode_select.gd"
HAND_CAPTURE_GDEXTENSION = (
    ROOT / "xr" / "addons" / "hand_capture" / "hand_capture.gdextension"
)
SHARED_ANDROID_MANIFESTS = (
    ROOT / "xr" / "android" / "build" / "AndroidManifest.xml",
    ROOT / "xr" / "android" / "build" / "src" / "debug" / "AndroidManifest.xml",
    ROOT / "xr" / "android" / "build" / "src" / "release" / "AndroidManifest.xml",
)
CAPTURE_ONLY_MANIFEST_MARKERS = (
    "android.permission.CAMERA",
    "android.permission.MANAGE_EXTERNAL_STORAGE",
    "android.permission.MODIFY_AUDIO_SETTINGS",
    "android.permission.RECORD_AUDIO",
    "horizonos.permission.HEADSET_CAMERA",
    "android.hardware.camera",
)
CAPTURE_EXPORTERS = (
    ROOT / "xr" / "addons" / "spatial_capture_contract" / "contract.gd",
    ROOT / "xr" / "addons" / "capture_common" / "export_plugin.gd",
    ROOT / "xr" / "addons" / "spatialmp4_muxer" / "export_plugin.gd",
    ROOT / "xr" / "addons" / "quest_capture_android" / "export_plugin.gd",
    ROOT / "xr" / "addons" / "pico_capture_android" / "export_plugin.gd",
    ROOT / "xr" / "addons" / "qr_scanner" / "qr_scanner.gd",
    ROOT / "xr" / "addons" / "live-push" / "export_plugin.gd",
)

# The operator_launcher plugin and its operator_launcher_card_* options were
# retired: launcher cards are plain operator_feature_mode_* features now.
# Rule (f) keeps the old options from creeping back in.
RETIRED_OPTION_PREFIX = "operator_launcher_card_"

# (i) A Teleop APK is a plain export preset derived from its full counterpart,
# not a build-time rewrite of export_presets.cfg. Exporting "Pico Teleop" from
# the Godot editor and running `make build-pico-teleop` must therefore produce
# the same APK. The pairing is only maintainable if differences are restricted
# to the product surface: name/resource filter, the static capture-stack tag,
# capture-only Android permissions, and operator_* options.
PRESET_PAIRS = (
    ("Meta Quest", "Meta Quest Teleop"),
    ("Pico", "Pico Teleop"),
)
PAIR_DIVERGENT_SETTINGS = frozenset({"name", "exclude_filter", "custom_features"})
PAIR_DIVERGENT_OPTIONS = frozenset({
    "permissions/camera",
    "permissions/manage_external_storage",
    "permissions/modify_audio_settings",
    "permissions/record_audio",
})
TELEOP_QUICK_ENTRY = "teleop"
TELEOP_REQUIRED_OPTIONS = {
    "operator_feature_mode_teleop": True,
    "operator_feature_mode_ego_capture": False,
    "operator_feature_mode_live_feed": False,
    "operator_feature_mode_vr": False,
    "operator_feature_mode_exit": True,
    "operator_feature_sink_spatialmp4": False,
    "operator_feature_sink_live_stream": False,
    "operator_feature_sink_upload": False,
    "operator_feature_test_harness": False,
    "permissions/camera": False,
    "permissions/manage_external_storage": False,
    "permissions/modify_audio_settings": False,
    "permissions/record_audio": False,
}
# Capture/VR resources a Teleop APK must not ship. The native side is already
# gated by the operator_capture_stack tag; this is the PCK half, and without it
# a Teleop APK still carries capture scenes and the hand_capture extension
# descriptor whose .so was stripped.
TELEOP_REQUIRED_EXCLUDES = frozenset({
    "addons/capture_common/**",
    "addons/hand_capture/**",
    "addons/live-push/**",
    "addons/pico_capture_android/**",
    "addons/qr_scanner/**",
    "addons/quest_capture_android/**",
    "addons/spatial_capture_contract/**",
    "addons/spatialmp4_muxer/**",
    "scenes/capture_app.tscn",
    "scenes/live_feed_app.tscn",
    "scenes/vr_mode.tscn",
    "scripts/app/modes/capture_app_base.gd*",
    "scripts/core/capture/**",
    "scripts/sinks/live_stream/**",
    "scripts/sinks/spatialmp4/**",
    "scripts/sinks/upload/**",
})
PICO_OPENXR_EXCLUDE = "addons/pico_openxr/**"
MAKE_PRESET_VARIABLES = (
    ("FULL_QUEST_EXPORT_PRESET", "Meta Quest"),
    ("FULL_PICO_EXPORT_PRESET", "Pico"),
    ("TELEOP_QUEST_EXPORT_PRESET", "Meta Quest Teleop"),
    ("TELEOP_PICO_EXPORT_PRESET", "Pico Teleop"),
)

# (j) Resource kinds an export packs and that can reference each other. Godot
# never scans these directories for res:// resources.
PROJECT_RESOURCE_SUFFIXES = frozenset({".gd", ".tscn", ".tres", ".gdshader"})
NON_RESOURCE_DIRS = frozenset({".godot", ".git", "android", "build"})
# `preload()` and a path-form `extends` are the two references GDScript must
# resolve while parsing; a runtime load() failure is recoverable, these are not.
GDSCRIPT_HARD_REFERENCE = re.compile(
    r'preload\(\s*"res://([^"]+)"|^\s*extends\s+"res://([^"]+)"', re.M
)
SCENE_RESOURCE_REFERENCE = re.compile(r'path="res://([^"]+)"')


def parse_presets(text):
    """Return preset names, top-level settings, and option values by index."""
    presets = {}
    current = None
    in_options = None
    for line in text.splitlines():
        line = line.strip()
        m = re.match(r"^\[preset\.(\d+)\]$", line)
        if m:
            current = int(m.group(1))
            presets.setdefault(current, {"name": "", "settings": {}, "options": {}})
            in_options = None
            continue
        m = re.match(r"^\[preset\.(\d+)\.options\]$", line)
        if m:
            in_options = int(m.group(1))
            presets.setdefault(
                in_options, {"name": "", "settings": {}, "options": {}}
            )
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
        elif current is not None:
            presets[current]["settings"][key] = value
            if key == "name":
                presets[current]["name"] = value.strip('"')
    return presets


def parse_bool(raw):
    return raw.strip().lower() == "true"


def parse_filter(raw):
    return {item.strip() for item in raw.strip('"').split(",") if item.strip()}


def parse_string(raw):
    return raw.strip().strip('"')


def parse_plugin_table(text):
    """Parse FEATURE_OPTIONS entries from export_plugin.gd -> {name: default}."""
    table = {}
    for m in re.finditer(
        r'\{\s*"name":\s*"(operator_feature_\w+)",\s*"default":\s*(true|false)\s*\}', text
    ):
        table[m.group(1)] = m.group(2) == "true"
    return table


def parse_const_string(text, name):
    match = re.search(r'^\s*const %s := "([^"]+)"$' % re.escape(name), text, re.M)
    return match.group(1) if match else ""


def parse_const_string_array(text, name):
    match = re.search(
        r"^\s*const %s := \[(.*?)\]" % re.escape(name), text, re.M | re.S
    )
    if not match:
        return []
    return re.findall(r'"([^"]+)"', match.group(1))


def parse_make_words(text, name):
    match = re.search(r"^%s\s*:?=\s*(.*)$" % re.escape(name), text, re.M)
    return match.group(1).split() if match else []


def parse_make_value(text, name):
    """Raw right-hand side of a Make assignment (preset names contain spaces)."""
    match = re.search(r"^%s\s*:?=\s*(.*)$" % re.escape(name), text, re.M)
    return match.group(1).strip() if match else ""


def build_script_sources():
    """Every file that can run during an XR build, for the rewrite guard.

    Scanning only xr/Makefile would miss the obvious workaround: move the
    rewrite into an included makefile or a helper shell script.
    """
    sources = [XR_MAKEFILE]
    sources.extend(sorted((ROOT / "xr" / "makefiles").glob("Makefile*")))
    sources.extend(sorted((ROOT / "xr").rglob("*.sh")))
    sources.extend(sorted((ROOT / "cicd").glob("*.sh")))
    seen = set()
    result = []
    for path in sources:
        resolved = path.resolve()
        if resolved in seen or not path.is_file():
            continue
        seen.add(resolved)
        result.append((path, path.read_text(errors="replace")))
    return result


def parse_gdscript_function(text, name):
    """Return the body of `func <name>(...)`, or "" when it is absent.

    Used instead of a bare substring test so a check cannot pass just because
    the symbol appears somewhere else in the file (a comment, another caller).
    """
    match = re.search(r"^(\t*)(?:static )?func %s\(" % re.escape(name), text, re.M)
    if not match:
        return ""
    indent = len(match.group(1))
    lines = text[match.start() :].splitlines()
    # A signature may wrap across lines; the body starts after the line that
    # closes it with ":".
    start = 0
    for offset, line in enumerate(lines):
        if line.rstrip().endswith(":"):
            start = offset + 1
            break
    body_indent = "\t" * (indent + 1)
    body = []
    for line in lines[start:]:
        if line.strip() and not line.startswith(body_indent):
            break
        body.append(line)
    return "\n".join(body)


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


_PROJECT_RESOURCES = None


def project_resources():
    """Every res:// resource an export can pack, as res-relative paths."""
    global _PROJECT_RESOURCES
    if _PROJECT_RESOURCES is not None:
        return _PROJECT_RESOURCES
    resources = []
    # Prune at the top level rather than filtering after the fact: xr/build and
    # xr/android hold whole Gradle and export trees that dwarf the project.
    for entry in sorted(XR_DIR.iterdir()):
        if entry.name in NON_RESOURCE_DIRS:
            continue
        for path in [entry] if entry.is_file() else entry.rglob("*"):
            if path.is_file() and path.suffix in PROJECT_RESOURCE_SUFFIXES:
                resources.append(path.relative_to(XR_DIR).as_posix())
    _PROJECT_RESOURCES = sorted(resources)
    return _PROJECT_RESOURCES


def filter_matcher(patterns):
    """Godot matches export filters with String.matchn(): '*' spans '/' too.

    _edit_files_with_filter() tests each candidate both with and without the
    res:// prefix, so a bare `scripts/foo.gd*` pattern matches. Mirroring that
    exactly matters: a looser matcher would call files excluded that still ship,
    and a stricter one would miss the very breaks this rule exists to find.
    """
    if not patterns:
        return lambda rel: False
    alternatives = []
    for pattern in patterns:
        alternatives.append(
            "".join(
                ".*" if ch == "*" else "." if ch == "?" else re.escape(ch)
                for ch in pattern
            )
        )
    compiled = re.compile("^(?:%s)$" % "|".join(alternatives), re.I)
    return lambda rel: bool(compiled.match(rel) or compiled.match("res://" + rel))


def strip_gdscript_noise(text):
    """Drop comments and string literals so only resolvable code identifiers remain."""
    text = re.sub(r'"""[\s\S]*?"""', '""', text)
    lines = []
    for line in text.splitlines():
        line = re.sub(r'"[^"\n]*"', '""', line)
        line = re.sub(r"'[^'\n]*'", "''", line)
        lines.append(re.sub(r"#.*$", "", line))
    return "\n".join(lines)


def scan_dropped_resource_references(preset_name, excludes):
    """(j) Nothing a preset keeps may reference something the preset drops.

    An exclude_filter is the only thing standing between a Teleop APK and the
    capture stack, so it is written broadly — and a pattern that also catches a
    shared base class silently breaks the product the preset exists to ship.
    GDScript resolves `extends SensorSink` at parse time, so dropping
    sink_contract.gd made teleop_mode.gd fail to compile and the Teleop APK
    reached the launcher but never started Teleop. Nothing in the export log
    said so; only the headset did.
    """
    errors = []
    matches = filter_matcher(excludes)
    resources = project_resources()
    dropped = {rel for rel in resources if matches(rel)}
    kept = [rel for rel in resources if rel not in dropped]

    dropped_classes = {}
    for rel in sorted(dropped):
        if not rel.endswith(".gd"):
            continue
        m = re.search(
            r"^class_name\s+(\w+)", (XR_DIR / rel).read_text(errors="ignore"), re.M
        )
        if m:
            dropped_classes[m.group(1)] = rel
    class_pattern = (
        re.compile(r"\b(%s)\b" % "|".join(sorted(map(re.escape, dropped_classes))))
        if dropped_classes
        else None
    )

    for rel in kept:
        text = (XR_DIR / rel).read_text(errors="ignore")
        if rel.endswith(".gd"):
            paths = [a or b for a, b in GDSCRIPT_HARD_REFERENCE.findall(text)]
            if class_pattern:
                for name in sorted(set(class_pattern.findall(strip_gdscript_noise(text)))):
                    errors.append(
                        "(j) preset '%s' keeps %s but drops %s, which declares "
                        "the global class %s it resolves at parse time"
                        % (preset_name, rel, dropped_classes[name], name)
                    )
        else:
            paths = SCENE_RESOURCE_REFERENCE.findall(text)
        for target in sorted(set(paths)):
            if target in dropped:
                errors.append(
                    "(j) preset '%s' keeps %s but drops %s, which it loads by path"
                    % (preset_name, rel, target)
                )
    return errors


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
    for path in (
        PRESETS,
        EXPORT_PLUGIN,
        REGISTRY,
        OPERATOR_FEATURE,
        QUICK_ENTRY_CONFIG,
        XR_MAKEFILE,
        MODE_SELECT,
        HAND_CAPTURE_GDEXTENSION,
        *SHARED_ANDROID_MANIFESTS,
        *CAPTURE_EXPORTERS,
    ):
        if not path.exists():
            print("ERROR: missing file: %s" % path, file=sys.stderr)
            return 1

    plugin_text = EXPORT_PLUGIN.read_text()
    plugin_table = parse_plugin_table(plugin_text)
    quick_entry_option = parse_const_string(plugin_text, "QUICK_ENTRY_OPTION")
    quick_entry_default = parse_const_string(plugin_text, "QUICK_ENTRY_DEFAULT")
    quick_entry_modes = parse_const_string_array(plugin_text, "QUICK_ENTRY_MODES")
    quick_entry_tag_prefix = parse_const_string(plugin_text, "QUICK_ENTRY_TAG_PREFIX")
    capture_stack_feature = parse_const_string(plugin_text, "CAPTURE_STACK_FEATURE")
    quick_entry_runtime_text = QUICK_ENTRY_CONFIG.read_text()
    runtime_quick_entry_modes = re.findall(
        r'^\s*const MODE_\w+ := "([^"]+)"$', quick_entry_runtime_text, re.M
    )
    runtime_quick_entry_tag_prefix = parse_const_string(
        quick_entry_runtime_text, "TAG_PREFIX"
    )
    registry = parse_registry(REGISTRY.read_text())
    registry_table = {e["option"]: e["default"] for e in registry}
    presets = parse_presets(PRESETS.read_text())
    makefile_text = XR_MAKEFILE.read_text()
    make_profiles = parse_make_words(makefile_text, "VALID_OPERATOR_BUILD_PROFILES")
    mode_select_text = MODE_SELECT.read_text()

    if not plugin_table:
        errors.append("export_plugin.gd: no FEATURE_OPTIONS entries parsed")
    if not registry:
        errors.append("feature_registry.gd: no FeatureDefinition.create entries parsed")
    if not quick_entry_option or not quick_entry_default or not quick_entry_modes:
        errors.append("export_plugin.gd: quick-entry constants are incomplete")
    elif quick_entry_default not in quick_entry_modes:
        errors.append(
            "export_plugin.gd: quick-entry default %s is not a declared mode"
            % quick_entry_default
        )
    if quick_entry_modes != runtime_quick_entry_modes:
        errors.append(
            "quick-entry mode mismatch: plugin=%s runtime=%s"
            % (quick_entry_modes, runtime_quick_entry_modes)
        )
    if quick_entry_tag_prefix != runtime_quick_entry_tag_prefix:
        errors.append(
            "quick-entry tag prefix mismatch: plugin=%s runtime=%s"
            % (quick_entry_tag_prefix, runtime_quick_entry_tag_prefix)
        )

    # (i) The Teleop build surface. Three things have to agree: the paired
    # export presets, the Make targets that select them, and the capture
    # gating that keeps stale native artifacts out of a Teleop APK.
    if make_profiles != ["full", "teleop"]:
        errors.append(
            "(i) XR Makefile build profiles must be 'full teleop', got %s"
            % make_profiles
        )
    for path, text in build_script_sources():
        for lineno, line in enumerate(text.splitlines(), 1):
            if "export_presets.cfg" not in line:
                continue
            stripped = line.strip()
            if stripped.startswith("#") or stripped.startswith(";"):
                continue
            errors.append(
                "(i) the build must not read or rewrite export_presets.cfg; "
                "select a preset by name instead: %s:%d: %s"
                % (path.relative_to(ROOT), lineno, stripped)
            )
    for variable, expected in MAKE_PRESET_VARIABLES:
        declared = parse_make_value(makefile_text, variable)
        if declared != expected:
            errors.append(
                "(i) Make %s must be '%s', got '%s'" % (variable, expected, declared)
            )
    # `override` is load-bearing: a plain target-specific assignment loses to a
    # command-line OPERATOR_BUILD_PROFILE=teleop and silently strips the
    # harness out of the test APK.
    for variable, expected in (
        ("OPERATOR_BUILD_PROFILE", "full"),
        ("OPERATOR_QUICK_ENTRY", "launcher"),
    ):
        declaration = "build-quest-test: override %s := %s" % (variable, expected)
        if declaration not in makefile_text:
            errors.append("(i) build-quest-test does not force %s=%s" % (variable, expected))
    teleop_quest_deps = parse_make_words(makefile_text, "TELEOP_QUEST_BUILD_DEPS")
    teleop_pico_deps = parse_make_words(makefile_text, "TELEOP_PICO_BUILD_DEPS")
    for label, deps in (
        ("Quest", teleop_quest_deps),
        ("Pico", teleop_pico_deps),
    ):
        for forbidden in ("deps", "build-hand-capture", "prepare-capture-plugins"):
            if forbidden in deps:
                errors.append("(i) teleop %s deps include %s" % (label, forbidden))
        for required in (
            "deps-teleop",
            "build-ahb",
            "build-godot-mujoco",
            "build-retargeting",
            "verify-retargeting-lib",
        ):
            if required not in deps:
                errors.append("(i) teleop %s deps omit %s" % (label, required))
    if "build-pico-openxr" not in teleop_pico_deps:
        errors.append("(i) teleop Pico deps omit build-pico-openxr")
    if not capture_stack_feature:
        errors.append("(i) export plugin capture-stack feature is missing")
    else:
        for path in CAPTURE_EXPORTERS:
            if capture_stack_feature not in path.read_text():
                errors.append("(i) %s does not gate on %s" % (path, capture_stack_feature))
        hand_capture_text = HAND_CAPTURE_GDEXTENSION.read_text()
        for flavor in ("debug", "release"):
            library_key = "android.%s.arm64" % flavor
            if not re.search(r"^%s\s*=" % re.escape(library_key), hand_capture_text, re.M):
                errors.append(
                    "(i) hand_capture.gdextension is missing the standard %s library key"
                    % library_key
                )
        for manifest_path in SHARED_ANDROID_MANIFESTS:
            manifest_text = manifest_path.read_text()
            for marker in CAPTURE_ONLY_MANIFEST_MARKERS:
                if marker in manifest_text:
                    errors.append(
                        "(i) shared Android manifest %s hardcodes capture-only %s"
                        % (manifest_path.relative_to(ROOT), marker)
                    )
    # Every route into a mode must pass the feature gate. Checking that
    # `_mode_available` merely appears in the file would be satisfied by a
    # comment, so require the two routing functions to actually call it.
    for function in ("_open_mode", "resolve_startup_route"):
        body = parse_gdscript_function(mode_select_text, function)
        if not body:
            errors.append("(i) mode_select.gd has no %s function" % function)
        elif "_mode_available(" not in body:
            errors.append(
                "(i) mode_select.gd %s() does not call _mode_available(); an "
                "operator.mode intent could open a mode this APK stripped"
                % function
            )
    startup_route = parse_gdscript_function(mode_select_text, "resolve_startup_route")
    if startup_route and "automation_requested" not in startup_route.split("quick_entry")[0]:
        errors.append(
            "(i) resolve_startup_route() must preserve explicit request presence "
            "before the preset quick entry"
        )

    preset_by_name = {preset["name"]: preset for preset in presets.values()}
    for base_name, teleop_name in PRESET_PAIRS:
        base = preset_by_name.get(base_name)
        teleop = preset_by_name.get(teleop_name)
        if base is None or teleop is None:
            errors.append(
                "(i) missing preset pair '%s' / '%s'" % (base_name, teleop_name)
            )
            continue
        # Everything outside the declared product-surface differences —
        # platform, signing, Gradle, OpenXR, export path — stays byte-identical.
        for key in sorted(set(base["settings"]) | set(teleop["settings"])):
            if key in PAIR_DIVERGENT_SETTINGS:
                continue
            if base["settings"].get(key) != teleop["settings"].get(key):
                errors.append(
                    "(i) preset '%s' diverges from '%s': %s=%s (expected %s)"
                    % (
                        teleop_name,
                        base_name,
                        key,
                        teleop["settings"].get(key),
                        base["settings"].get(key),
                    )
                )
        for key in sorted(set(base["options"]) | set(teleop["options"])):
            if key.startswith("operator_") or key in PAIR_DIVERGENT_OPTIONS:
                continue
            if base["options"].get(key) != teleop["options"].get(key):
                errors.append(
                    "(i) preset '%s' diverges from '%s': %s=%s (expected %s)"
                    % (
                        teleop_name,
                        base_name,
                        key,
                        teleop["options"].get(key),
                        base["options"].get(key),
                    )
                )
        for option, expected in sorted(TELEOP_REQUIRED_OPTIONS.items()):
            raw = teleop["options"].get(option)
            if raw is None or parse_bool(raw) != expected:
                errors.append(
                    "(i) preset '%s' must set %s=%s"
                    % (teleop_name, option, str(expected).lower())
                )
        if parse_string(teleop["options"].get("operator_quick_entry", "")) \
                != TELEOP_QUICK_ENTRY:
            errors.append(
                "(i) preset '%s' must set operator_quick_entry=\"%s\""
                % (teleop_name, TELEOP_QUICK_ENTRY)
            )
        base_features = parse_filter(base["settings"].get("custom_features", ""))
        teleop_features = parse_filter(teleop["settings"].get("custom_features", ""))
        if capture_stack_feature not in base_features:
            errors.append(
                "(i) preset '%s' must declare custom feature %s"
                % (base_name, capture_stack_feature)
            )
        if capture_stack_feature in teleop_features:
            errors.append(
                "(i) preset '%s' must not declare custom feature %s"
                % (teleop_name, capture_stack_feature)
            )
        base_excludes = parse_filter(base["settings"].get("exclude_filter", ""))
        teleop_excludes = parse_filter(teleop["settings"].get("exclude_filter", ""))
        dropped = sorted(base_excludes - teleop_excludes)
        if dropped:
            errors.append(
                "(i) preset '%s' drops exclusions inherited from '%s': %s"
                % (teleop_name, base_name, ", ".join(dropped))
            )
        missing = sorted(TELEOP_REQUIRED_EXCLUDES - teleop_excludes)
        if missing:
            errors.append(
                "(i) preset '%s' resource filter omits: %s"
                % (teleop_name, ", ".join(missing))
            )
        errors.extend(scan_dropped_resource_references(teleop_name, teleop_excludes))

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

        # (g) dynamic profile/GLB loads must be explicit, but robot-generation
        # source trees are never read at runtime and add roughly 90 MiB.
        settings = preset["settings"]
        includes = parse_filter(settings.get("include_filter", ""))
        excludes = parse_filter(settings.get("exclude_filter", ""))
        custom_features = parse_filter(settings.get("custom_features", ""))

        capture_mode_enabled = (
            enabled.get("operator_feature_mode_ego_capture", False)
            or enabled.get("operator_feature_mode_live_feed", False)
        )
        capture_stack_enabled = capture_stack_feature in custom_features
        if capture_mode_enabled != capture_stack_enabled:
            errors.append(
                "(i) preset '%s' capture modes=%s but custom feature %s=%s"
                % (
                    pname,
                    str(capture_mode_enabled).lower(),
                    capture_stack_feature,
                    str(capture_stack_enabled).lower(),
                )
            )

        # (k) _export_file().skip() runs too late to affect the generated
        # extension_list.cfg. The descriptor must be absent from the preset's
        # resource set on every platform where its native library cannot load.
        if "pico" in custom_features:
            if PICO_OPENXR_EXCLUDE in excludes:
                errors.append(
                    "(k) Pico preset '%s' excludes required %s"
                    % (pname, PICO_OPENXR_EXCLUDE)
                )
        elif PICO_OPENXR_EXCLUDE not in excludes:
            errors.append(
                "(k) non-Pico preset '%s' must exclude %s before Godot "
                "generates extension_list.cfg" % (pname, PICO_OPENXR_EXCLUDE)
            )
        for required in (
            "assets/robot_profiles/*.json",
            "assets/robots/*/*.glb",
        ):
            if required not in includes:
                errors.append("(g) preset '%s' does not include %s" % (pname, required))
        for pattern in includes:
            if pattern.startswith("assets/robots/") and (
                "/meshes/" in pattern
                or pattern.endswith("*.urdf")
                or pattern.endswith("*.xml")
            ):
                errors.append(
                    "(g) preset '%s' includes robot source asset %s" % (pname, pattern)
                )
        for required in (
            "assets/robots/meshes/**",
            "assets/robots/*/meshes/**",
            "assets/robots/*/*.urdf",
            "assets/robots/*/*.xml",
        ):
            if required not in excludes:
                errors.append("(g) preset '%s' does not exclude %s" % (pname, required))

        # (h) quick entry is a single startup route, not another feature flag.
        # A direct route may only target a mode enabled in the same preset.
        if quick_entry_option not in options:
            errors.append("(h) preset '%s' missing option %s" % (pname, quick_entry_option))
        else:
            quick_entry = parse_string(options[quick_entry_option])
            if quick_entry not in quick_entry_modes:
                errors.append(
                    "(h) preset '%s' has invalid %s=%s"
                    % (pname, quick_entry_option, quick_entry)
                )
            elif quick_entry != quick_entry_default:
                required_feature = "operator_feature_mode_%s" % quick_entry
                if not enabled.get(required_feature, False):
                    errors.append(
                        "(h) preset '%s': %s=%s requires %s=true"
                        % (pname, quick_entry_option, quick_entry, required_feature)
                    )

    if errors:
        print("validate_xr_features: FAILED (%d errors)" % len(errors), file=sys.stderr)
        for err in errors:
            print("  - %s" % err, file=sys.stderr)
        return 1
    print(
        "validate_xr_features: OK (%d features, %d quick-entry modes, %d build profiles, %d Android presets)"
        % (len(declared), len(quick_entry_modes), len(make_profiles), len(presets))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
