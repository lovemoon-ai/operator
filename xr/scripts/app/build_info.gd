extends RefCounted
## Build identity shown on the Teleop and Ego "Build info" settings pages.
##
## The version is the repo-wide release version (VERSION -> project.godot, see
## scripts/version.py). The commit is baked into the PCK by the operator-features
## export plugin, so a run straight from the editor reports "dev".

# KEEP IN SYNC with addons/operator_features/export_plugin.gd.
const BUILD_INFO_PATH := "res://build_info.cfg"


static func version() -> String:
	return String(ProjectSettings.get_setting("application/config/version", ""))


static func commit() -> String:
	if not FileAccess.file_exists(BUILD_INFO_PATH):
		return "dev"
	var build_info := ConfigFile.new()
	if build_info.load(BUILD_INFO_PATH) != OK:
		return "unknown"
	return String(build_info.get_value("build", "commit", "unknown"))
