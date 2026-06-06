extends RefCounted
class_name EgoSettingsStore

# Persists Ego-mode capture options (interaction mode, stream toggles,
# save_root, upload URL/hidden token/toggles) across app launches.
#
# Lives in the same ConfigFile (`user://ego_settings.cfg`) used by the
# teleop SettingsUI pattern at `xr/scenes/ui/settings_ui.gd:232-268`,
# but under a distinct section so the two modes do not collide.
#
# Token storage is base64-obfuscated (NOT encrypted). The file lives
# in the app's private data dir on Android, which is sandboxed from
# other apps but readable on a rooted device. See
# `claw/issues/010-ego-data-upload.md` ("Trip-wires") for the
# rationale and recommended hardening path (mTLS or short-lived
# tokens) for production deployments.

const SETTINGS_PATH := "user://ego_settings.cfg"
const SECTION := "ego_capture"
const SECTION_UPLOAD := "ego_upload"

const DEFAULT_SAVE_ROOT := "/sdcard/DCIM/SpatialMP4"
const DEFAULTS := {
	"interaction_mode": "controllers",
	"stereo_rgb": true,
	"record_depth": true,
	"record_head_pose": true,
	"record_controller_pose": true,
	"record_hand_data": true,
	"record_audio": false,
	"audio_channel_layout": "stereo",
	"audio_sample_rate_hz": 48000,
	"audio_bitrate_bps": 128000,
	"server_host": "127.0.0.1",
	"server_port": 63910,
	"server_result_port": 63912,
	"server_auth_token": "",
	"save_controller_hand_sidecar": false,
	"save_root": DEFAULT_SAVE_ROOT,
	"upload_url": "",
	"upload_token": "",
	"upload_on_finalize": true,
	"keep_local_after_upload": true,
	"allow_metered_upload": false,
}


static func load_options() -> Dictionary:
	var cfg := ConfigFile.new()
	var out := DEFAULTS.duplicate(true)
	if cfg.load(SETTINGS_PATH) != OK:
		return out

	for key in [
		"interaction_mode",
		"stereo_rgb",
		"record_depth",
		"record_head_pose",
		"record_controller_pose",
		"record_hand_data",
		"record_audio",
		"audio_channel_layout",
		"audio_sample_rate_hz",
		"audio_bitrate_bps",
		"server_host",
		"server_port",
		"server_result_port",
		"save_controller_hand_sidecar",
		"save_root",
	]:
		if cfg.has_section_key(SECTION, key):
			out[key] = cfg.get_value(SECTION, key, out[key])

	for key in [
		"upload_url",
		"upload_on_finalize",
		"keep_local_after_upload",
		"allow_metered_upload",
	]:
		if cfg.has_section_key(SECTION_UPLOAD, key):
			out[key] = cfg.get_value(SECTION_UPLOAD, key, out[key])

	if cfg.has_section_key(SECTION_UPLOAD, "upload_token_b64"):
		var encoded := str(cfg.get_value(SECTION_UPLOAD, "upload_token_b64", ""))
		out["upload_token"] = _decode_token(encoded)

	if cfg.has_section_key(SECTION, "server_auth_token_b64"):
		var encoded_live_token := str(cfg.get_value(SECTION, "server_auth_token_b64", ""))
		out["server_auth_token"] = _decode_token(encoded_live_token)

	return out


static func save_options(options: Dictionary) -> Error:
	var cfg := ConfigFile.new()
	# Best-effort load so we preserve any unknown keys a future build
	# may have written.
	cfg.load(SETTINGS_PATH)

	for key in [
		"interaction_mode",
		"stereo_rgb",
		"record_depth",
		"record_head_pose",
		"record_controller_pose",
		"record_hand_data",
		"record_audio",
		"audio_channel_layout",
		"audio_sample_rate_hz",
		"audio_bitrate_bps",
		"server_host",
		"server_port",
		"server_result_port",
		"save_controller_hand_sidecar",
		"save_root",
	]:
		if options.has(key):
			cfg.set_value(SECTION, key, options[key])

	for key in [
		"upload_url",
		"upload_on_finalize",
		"keep_local_after_upload",
		"allow_metered_upload",
	]:
		if options.has(key):
			cfg.set_value(SECTION_UPLOAD, key, options[key])

	if options.has("upload_token"):
		var token := str(options["upload_token"])
		if token.is_empty():
			# Remove the obfuscated value rather than leave the previous
			# token sitting on disk after the user cleared the field.
			if cfg.has_section_key(SECTION_UPLOAD, "upload_token_b64"):
				cfg.erase_section_key(SECTION_UPLOAD, "upload_token_b64")
		else:
			cfg.set_value(SECTION_UPLOAD, "upload_token_b64", _encode_token(token))

	if options.has("server_auth_token"):
		var live_token := str(options["server_auth_token"])
		if live_token.is_empty():
			if cfg.has_section_key(SECTION, "server_auth_token_b64"):
				cfg.erase_section_key(SECTION, "server_auth_token_b64")
		else:
			cfg.set_value(SECTION, "server_auth_token_b64", _encode_token(live_token))

	var err := cfg.save(SETTINGS_PATH)
	if err != OK:
		push_warning("[EgoSettingsStore] Failed to save %s: error %d" % [SETTINGS_PATH, err])
	return err


static func defaults() -> Dictionary:
	return DEFAULTS.duplicate(true)


# --- Token obfuscation (NOT encryption) --------------------------------------
# Plain base64 keeps the token from showing up in casual `cat` of the
# settings file. Anyone with filesystem read access can still recover
# it trivially. See header comment.

static func _encode_token(plain: String) -> String:
	return Marshalls.utf8_to_base64(plain)


static func _decode_token(encoded: String) -> String:
	if encoded.is_empty():
		return ""
	var decoded := Marshalls.base64_to_utf8(encoded)
	return decoded
