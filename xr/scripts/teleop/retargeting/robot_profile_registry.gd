class_name RobotProfileRegistry
extends RefCounted
## Inside Robot profiles, discovered from the assets actually shipped in this
## build. Outside Robot deliberately does not use this registry: robot-service
## is authoritative for all outside embodiments.
##
## A profile is a JSON manifest in `res://assets/robot_profiles/` describing how
## one embodiment is driven (input/output contract, solver support, simulation
## model). Nothing here is hardcoded: adding a robot means generating its assets
## (`scripts/make-robot/`) and dropping a manifest beside the others.
##
## A profile is only offered when every path in its `required_assets` is present.
## Robot bundles under `assets/robots/` are generated per checkout rather than
## committed, so a build that lacks a robot's meshes must not advertise it —
## the operator would pick a robot that cannot be rendered.

const PROFILE_DIR := "res://assets/robot_profiles"

static var _profiles: Dictionary = {}
static var _unavailable: Dictionary = {}
static var _loaded := false


## Profile ids available in this build, sorted.
static func ids() -> Array[String]:
	_ensure_loaded()
	var out: Array[String] = []
	for profile_id in _profiles.keys():
		out.append(str(profile_id))
	out.sort()
	return out


static func list_profiles() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for profile_id in ids():
		out.append(get_profile(profile_id))
	return out


static func has_profile(profile_id: String) -> bool:
	_ensure_loaded()
	return _profiles.has(profile_id)


static func get_profile(profile_id: String) -> Dictionary:
	_ensure_loaded()
	if not _profiles.has(profile_id):
		return {}
	return (_profiles[profile_id] as Dictionary).duplicate(true)


static func supports_backend(profile_id: String, backend: String) -> bool:
	var profile := get_profile(profile_id)
	if profile.is_empty():
		return false
	match backend:
		"native":
			return bool(profile.get("native_supported", false))
		"remote":
			return bool(profile.get("remote_supported", false))
		_:
			return false


## Declared profiles whose assets are missing, as `{profile_id: reason}`. The
## settings UI surfaces this instead of silently showing a shorter list.
static func unavailable() -> Dictionary:
	_ensure_loaded()
	return _unavailable.duplicate(true)


## Re-scan on the next query; for tests and asset hot-swaps.
static func invalidate() -> void:
	_loaded = false
	_profiles.clear()
	_unavailable.clear()


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_profiles = {}
	_unavailable = {}
	for path in _manifest_paths():
		var manifest := _read_manifest(path)
		if manifest.is_empty():
			continue
		var profile_id := str(manifest.get("profile_id", ""))
		if profile_id.is_empty():
			push_warning("[RobotProfiles] %s has no profile_id" % path)
			continue
		var missing := _missing_assets(manifest)
		if missing.is_empty():
			_profiles[profile_id] = manifest
		else:
			_unavailable[profile_id] = "missing assets: %s" % ", ".join(missing)
	if _profiles.is_empty():
		push_warning("[RobotProfiles] no Inside Robot profile has its assets in this build")


static func _manifest_paths() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(PROFILE_DIR)
	if dir == null:
		push_warning("[RobotProfiles] cannot open %s" % PROFILE_DIR)
		return out
	for file_name in dir.get_files():
		# Exported projects may serve the manifest through its import remap.
		var name := file_name.trim_suffix(".remap")
		if name.ends_with(".json"):
			out.append("%s/%s" % [PROFILE_DIR, name])
	out.sort()
	return out


static func _read_manifest(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_warning("[RobotProfiles] cannot read %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[RobotProfiles] %s is not a JSON object" % path)
		return {}
	return parsed as Dictionary


static func _missing_assets(manifest: Dictionary) -> Array[String]:
	var missing: Array[String] = []
	var required: Array = manifest.get("required_assets", [])
	for entry in required:
		var path := str(entry)
		if not _asset_exists(path):
			missing.append(path)
	return missing


## Imported resources (GLB and friends) are packed as their import artifact, so
## the source path exists for the resource loader but not for FileAccess.
static func _asset_exists(path: String) -> bool:
	return ResourceLoader.exists(path) or FileAccess.file_exists(path)
