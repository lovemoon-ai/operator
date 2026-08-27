class_name QuickEntryConfig
extends RefCounted

## Build-time startup route selected by the Android export preset.
##
## The export plugin emits exactly one `operator_quick_entry_*` feature tag.
## Older exports and editor/dev runs have no such tag and therefore keep the
## normal launcher behavior.

const MODE_LAUNCHER := "launcher"
const MODE_TELEOP := "teleop"
const MODE_EGO_CAPTURE := "ego_capture"
const MODE_LIVE_FEED := "live_feed"

const TAG_PREFIX := "operator_quick_entry_"
const PROCESS_CONSUMED_META := &"operator_quick_entry_consumed"
const MODES := [
	MODE_LAUNCHER,
	MODE_TELEOP,
	MODE_EGO_CAPTURE,
	MODE_LIVE_FEED,
]


static func from_export_tags() -> String:
	var enabled_tags := PackedStringArray()
	for mode in MODES:
		var tag := tag_for_mode(String(mode))
		if OS.has_feature(tag):
			enabled_tags.append(tag)
	return resolve_from_tags(enabled_tags)


static func resolve_from_tags(tags: PackedStringArray) -> String:
	var selected_modes: Array[String] = []
	for mode in MODES:
		if tags.has(tag_for_mode(String(mode))):
			selected_modes.append(String(mode))
	if selected_modes.is_empty():
		return MODE_LAUNCHER
	if selected_modes.size() > 1:
		push_warning(
			"[QuickEntryConfig] Multiple quick-entry tags enabled (%s); using launcher"
			% ", ".join(selected_modes)
		)
		return MODE_LAUNCHER
	return selected_modes[0]


static func consume_for_process(root: Node, configured_mode: String) -> String:
	if configured_mode == MODE_LAUNCHER or not MODES.has(configured_mode):
		return ""
	if root != null and root.has_meta(PROCESS_CONSUMED_META):
		return ""
	if root != null:
		root.set_meta(PROCESS_CONSUMED_META, true)
	return configured_mode


static func tag_for_mode(mode: String) -> String:
	return TAG_PREFIX + mode
