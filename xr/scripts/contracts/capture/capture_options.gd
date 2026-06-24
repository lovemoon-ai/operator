class_name CaptureOptions
extends RefCounted
## v2 contracts: typed view over the capture options dictionary used by the
## ego-capture pipeline. Round-trips through from_dict()/to_dict() preserving
## unknown keys in `extra` so the manifest `capture_options` echo stays
## byte-identical to the legacy dictionary path.

const KNOWN_KEYS := [
	"interaction_mode",
	"stereo_rgb",
	"record_depth",
	"record_head_pose",
	"record_controller_pose",
	"record_controller_input",
	"record_hand_data",
	"record_body_tracking",
	"record_motion_trackers",
	"max_motion_trackers",
	"record_audio",
	"audio_channel_layout",
	"audio_sample_rate_hz",
	"audio_bitrate_bps",
	"rgb_bitrate",
	"rgb_fps",
	"rgb_width",
	"rgb_height",
	"rgb_resolution",
	"rgb_codec",
	"server_host",
	"server_port",
	"server_result_port",
	"save_controller_hand_sidecar",
	"save_body_sidecar",
	"save_root",
	"capture_sink",
	"capture_provider",
	"upload_on_finalize",
	"upload_endpoint",
]

var interaction_mode: String = "controllers"
var stereo_rgb: bool = true
var record_depth: bool = true
var record_head_pose: bool = true
var record_controller_pose: bool = true
var record_controller_input: bool = true
var record_hand_data: bool = true
var record_body_tracking: bool = true
var record_motion_trackers: bool = true
var max_motion_trackers: int = 2
var record_audio: bool = true
var audio_channel_layout: String = "stereo"
var audio_sample_rate_hz: int = 48000
var audio_bitrate_bps: int = 128000
var rgb_bitrate: int = 0
var rgb_fps: int = 0
var rgb_width: int = 0
var rgb_height: int = 0
var rgb_resolution: String = ""
var rgb_codec: String = "hevc"
var server_host: String = ""
var server_port: int = 0
var server_result_port: int = 0
var save_controller_hand_sidecar: bool = false
var save_body_sidecar: bool = false
var save_root: String = ""
var capture_sink: String = ""
var capture_provider: String = ""
var upload_on_finalize: bool = false
var upload_endpoint: String = ""
## Unknown keys preserved verbatim for round-trip fidelity.
var extra: Dictionary = {}
## Tracks which known keys were actually present in the source dictionary so
## to_dict() does not invent keys that were absent.
var _present_keys: Array = []


static func from_dict(d: Dictionary) -> CaptureOptions:
	var opts := CaptureOptions.new()
	for key in d.keys():
		var key_str := str(key)
		if KNOWN_KEYS.has(key_str):
			opts._present_keys.append(key_str)
			opts._assign(key_str, d[key])
		else:
			opts.extra[key] = d[key]
	return opts


func to_dict() -> Dictionary:
	var out := {}
	for key_v in _present_keys:
		var key := str(key_v)
		out[key] = _read(key)
	for key in extra.keys():
		out[key] = extra[key]
	return out


func get_option(key: String, default_value: Variant = null) -> Variant:
	if _present_keys.has(key):
		return _read(key)
	if extra.has(key):
		return extra[key]
	return default_value


func set_option(key: String, value: Variant) -> void:
	if KNOWN_KEYS.has(key):
		if not _present_keys.has(key):
			_present_keys.append(key)
		_assign(key, value)
	else:
		extra[key] = value


func _assign(key: String, value: Variant) -> void:
	match key:
		"interaction_mode": interaction_mode = str(value)
		"stereo_rgb": stereo_rgb = bool(value)
		"record_depth": record_depth = bool(value)
		"record_head_pose": record_head_pose = bool(value)
		"record_controller_pose": record_controller_pose = bool(value)
		"record_controller_input": record_controller_input = bool(value)
		"record_hand_data": record_hand_data = bool(value)
		"record_body_tracking": record_body_tracking = bool(value)
		"record_motion_trackers": record_motion_trackers = bool(value)
		"max_motion_trackers": max_motion_trackers = int(value)
		"record_audio": record_audio = bool(value)
		"audio_channel_layout": audio_channel_layout = str(value)
		"audio_sample_rate_hz": audio_sample_rate_hz = int(value)
		"audio_bitrate_bps": audio_bitrate_bps = int(value)
		"rgb_bitrate": rgb_bitrate = int(value)
		"rgb_fps": rgb_fps = int(value)
		"rgb_width": rgb_width = int(value)
		"rgb_height": rgb_height = int(value)
		"rgb_resolution": rgb_resolution = str(value)
		"rgb_codec": rgb_codec = str(value)
		"server_host": server_host = str(value)
		"server_port": server_port = int(value)
		"server_result_port": server_result_port = int(value)
		"save_controller_hand_sidecar": save_controller_hand_sidecar = bool(value)
		"save_body_sidecar": save_body_sidecar = bool(value)
		"save_root": save_root = str(value)
		"capture_sink": capture_sink = str(value)
		"capture_provider": capture_provider = str(value)
		"upload_on_finalize": upload_on_finalize = bool(value)
		"upload_endpoint": upload_endpoint = str(value)


func _read(key: String) -> Variant:
	match key:
		"interaction_mode": return interaction_mode
		"stereo_rgb": return stereo_rgb
		"record_depth": return record_depth
		"record_head_pose": return record_head_pose
		"record_controller_pose": return record_controller_pose
		"record_controller_input": return record_controller_input
		"record_hand_data": return record_hand_data
		"record_body_tracking": return record_body_tracking
		"record_motion_trackers": return record_motion_trackers
		"max_motion_trackers": return max_motion_trackers
		"record_audio": return record_audio
		"audio_channel_layout": return audio_channel_layout
		"audio_sample_rate_hz": return audio_sample_rate_hz
		"audio_bitrate_bps": return audio_bitrate_bps
		"rgb_bitrate": return rgb_bitrate
		"rgb_fps": return rgb_fps
		"rgb_width": return rgb_width
		"rgb_height": return rgb_height
		"rgb_resolution": return rgb_resolution
		"rgb_codec": return rgb_codec
		"server_host": return server_host
		"server_port": return server_port
		"server_result_port": return server_result_port
		"save_controller_hand_sidecar": return save_controller_hand_sidecar
		"save_body_sidecar": return save_body_sidecar
		"save_root": return save_root
		"capture_sink": return capture_sink
		"capture_provider": return capture_provider
		"upload_on_finalize": return upload_on_finalize
		"upload_endpoint": return upload_endpoint
	return null
