extends RefCounted
## Build identity shown on the Teleop and Ego "Version info" settings pages.
##
## The version is the repo-wide release version (VERSION -> project.godot, see
## scripts/version.py). The commit and build time are baked into the PCK by the
## operator-features export plugin, so a run straight from the editor reports
## "dev".

# KEEP IN SYNC with addons/operator_features/export_plugin.gd.
const BUILD_INFO_PATH := "res://build_info.cfg"


static func version() -> String:
	return String(ProjectSettings.get_setting("application/config/version", ""))


static func commit() -> String:
	var build_info := _load()
	if build_info == null:
		return "dev"
	return String(build_info.get_value("build", "commit", "unknown"))


## Export time in the headset's local timezone, as "YYYY-MM-DD HH:MM".
static func build_time() -> String:
	var build_info := _load()
	if build_info == null:
		return "dev"
	var unix_time := int(build_info.get_value("build", "time", 0))
	if unix_time <= 0:
		return "unknown"
	var time_zone: Dictionary = Time.get_time_zone_from_system()
	var local_time := unix_time + int(time_zone.get("bias", 0)) * 60
	return Time.get_datetime_string_from_unix_time(local_time, true).left(16)


static func _load() -> ConfigFile:
	if not FileAccess.file_exists(BUILD_INFO_PATH):
		return null
	var build_info := ConfigFile.new()
	if build_info.load(BUILD_INFO_PATH) != OK:
		return null
	return build_info
