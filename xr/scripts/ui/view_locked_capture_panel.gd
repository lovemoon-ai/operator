extends "res://scripts/ui/two_column_settings_panel.gd"
class_name ViewLockedCapturePanel

const CaptureProviderRegistryScript := preload("res://scripts/xr/capture_provider_registry.gd")

signal saved(options: Dictionary)
## Emitted when the user taps the 📷 button next to the Upload URL field.
## capture_app.gd subscribes and opens the QR scanner overlay. The scanner
## eventually calls set_upload_url_from_scan() to feed the result back.
## `exit_requested` is inherited from BaseSettingsPanel — don't redeclare.
signal scan_upload_url_requested
signal tracker_connect_requested
signal scan_live_server_requested
signal connect_live_server_requested(options: Dictionary)
signal manual_upload_requested(sessions: Array, options: Dictionary)
signal body_pose_debug_toggled
signal h2_debug_toggled
signal g1_debug_toggled

# 840 wide gives ~430px of detail column after sidebar + margins. The 1180-tall
# legacy viewport went away once the form was split into groups — every group
# fits comfortably in 720, including the upload section.
const VIEWPORT_SIZE := Vector2i(840, 720)
const DEFAULT_SAVE_ROOT := "/sdcard/Movies/SpatialMP4"
const DEFAULT_LIVE_SERVER_HOST := "127.0.0.1"
const DEFAULT_LIVE_SERVER_PORT := 63910
const DEFAULT_LIVE_RESULT_PORT := 63912
const STORAGE_REFRESH_SECONDS := 3.0
const SETTINGS_PATH := "user://capture_settings.cfg"
const SECTION := "capture"
# Hand-joint capture (record_hand_data) and controller-pose capture
# (record_controller_pose) describe two physically incompatible input
# regimes -- the operator is either driving with bare hands or with the
# Touch / PICO controllers, never both at once. Recording both at the
# same time produces sidecar data that downstream consumers can't make
# sense of (which transform "owns" the wrist at frame T?), so the
# toggles are wired as a mutex: enabling one auto-disables the other
# and we never let set_options leave both enabled. The pair is declared
# as a constant so the mutex logic stays declarative -- adding another
# pair later is just another entry.
const INPUT_SOURCE_MUTEX := {
	"record_hand_data": "record_controller_pose",
	"record_controller_pose": "record_hand_data",
}
# Health check timeout: keep short so the user is not stuck staring at
# "Checking..." if the endpoint is firewalled/dead. 8 s is enough for a
# TLS handshake on slow Wi-Fi but short enough that the operator can
# react. Anything longer feels broken in a HMD.
const UPLOAD_HEALTH_TIMEOUT_S := 8.0
const MAX_LOCAL_UPLOAD_SESSIONS := 40
const MAX_LOCAL_STORAGE_SESSIONS := 0
const LOCAL_UPLOAD_PREVIEW_BUTTON_WIDTH := 116
const LOCAL_FILE_MODE_UPLOAD := "upload"
const LOCAL_FILE_MODE_DELETE := "delete"
const RGB_PROVIDER_DEFAULT := "quest"
const RGB_RESOLUTIONS := {
	"pico": [
		Vector2i(2048, 1536),
		Vector2i(1920, 1440),
		Vector2i(1280, 960),
		Vector2i(1024, 768),
		Vector2i(640, 480),
	],
	"quest": [
		Vector2i(640, 480),
		Vector2i(800, 600),
		Vector2i(1280, 960),
	],
}
const RGB_DEFAULT_RESOLUTION := {
	"pico": Vector2i(640, 480),
	"quest": Vector2i(1280, 960),
}
const RGB_FPS_VALUES := {
	"pico": [30, 60],
	"quest": [15, 30, 60],
}
const DEFAULT_RGB_FPS := 30
const RGB_CODEC_HEVC := "hevc"
const RGB_CODEC_H264 := "h264"
const RGB_CODEC_VALUES := [RGB_CODEC_HEVC, RGB_CODEC_H264]
const DEFAULT_RGB_CODEC := RGB_CODEC_HEVC

# Auto-detected input source ("hands" or "controllers") used for the title-bar
# indicator + record-stream defaults. The current pointer mode is still owned
# by capture_app.gd so the panel never persists a transient detection flip.
var _indicator_mode := ""
var _motion_tracker_toggle: CheckButton
var _body_pose_debug_button: Button
var _h2_debug_button: Button
var _g1_debug_button: Button
var _motion_tracker_supported := false
var _depth_toggle: CheckButton
var _depth_supported := false
var _save_root: LineEdit
var _server_host: LineEdit
var _server_port: SpinBox
var _result_port: SpinBox
var _server_token: LineEdit
var _stream_toggles: Dictionary = {}
var _upload_url: LineEdit
var _upload_token := ""
var _upload_status_label: Label
var _upload_url_ready := false
var _upload_url_ready_value := ""
var _upload_health_pending_url := ""
var _upload_main_view: VBoxContainer
var _local_upload_view: VBoxContainer
var _local_file_menu_mode := LOCAL_FILE_MODE_UPLOAD
var _local_file_title_label: Label
var _manual_upload_button: Button
var _local_upload_status_label: Label
var _local_upload_scroll: ScrollContainer
var _local_upload_list: VBoxContainer
var _local_upload_upload_button: Button
var _local_upload_sessions: Array = []
var _local_upload_selection: Dictionary = {}
var _live_server_status_label: Label
var _storage_view_button: Button
# Dedicated HTTPRequest for the open()-time upload-URL health probe.
# Separate from capture_app.gd's upload_ack_request so the two flows
# (QR ACK challenge vs plain reachability check) don't clobber each
# other if the user scans a code while a probe is in flight.
var _upload_health_request: HTTPRequest
# _cursor, _pointer_position/_pointer_pressed, _highlighted_slot are
# inherited from BaseSettingsPanel — don't redeclare. (The hold-to-confirm
# exit indicator/state vars are gone now that Exit is a single click.)
var _storage_label: Label
var _tracker_section_label: Label
var _tracker_status_label: Label
var _tracker_connect_button: Button
var _tracker_connect_slot: PanelContainer
var _storage_refresh_accum := STORAGE_REFRESH_SECONDS
var _storage_plugin: Object
var _storage_plugin_checked := false
var _live_server_mode := false
var _capture_provider_name := RGB_PROVIDER_DEFAULT
var _rgb_resolution_button: Button
var _rgb_resolution_menu: VBoxContainer
var _rgb_fps_button: Button
var _rgb_fps_menu: VBoxContainer
var _rgb_codec_button: Button
var _rgb_codec_menu: VBoxContainer
var _requested_rgb_resolution := ""
var _requested_rgb_fps := DEFAULT_RGB_FPS
var _requested_rgb_codec := DEFAULT_RGB_CODEC
var _refreshing_rgb_selects := false
# Mirror of the live-server connection state reported by capture_app via
# set_live_server_connectivity_status(). Used by _on_confirm_requested to
# gate the Save button in live-feed mode.
var _live_server_connected := false
# Inline "popup-style" callout that appears under the server-host row when
# the user tries to save without a configured + connected server. See
# _build_live_server_required_callout().
var _live_server_required_callout: PanelContainer
var _live_server_required_label: Label
var _live_server_required_timer: Timer
const LIVE_SERVER_REQUIRED_VISIBLE_S := 5.0


func _init(live_server_mode: bool = false) -> void:
	_live_server_mode = live_server_mode
	var title_key := "UI_LIVE_FEED_SETTINGS_TITLE" if _live_server_mode else "UI_CAPTURE_SETTINGS_TITLE"
	# Two-column layout: left sidebar of group names, right pane holds the
	# active group's controls. Each group has its own scroll, so adding new
	# fields only grows the affected group instead of stretching the panel.
	_setup_two_column_panel(VIEWPORT_SIZE, Vector2(0.63, 0.54), title_key, "UI_SAVE", 2, true)
	if not _live_server_mode:
		_setup_upload_health_request()
	set_options(_load_settings())


func _settings_path() -> String:
	return SETTINGS_PATH


func _settings_section() -> String:
	return SECTION


func _settings_defaults() -> Dictionary:
	return _mode_default_options()


func _settings_log_tag() -> String:
	return "CaptureSettings"


func _settings_secret_keys() -> Dictionary:
	return _settings_secret_key_map()


func _setup_upload_health_request() -> void:
	# HTTPRequest needs to live in the scene tree to drive its internal
	# HTTPClient. We add it as a child here in _init(); the engine will
	# call _ready() once the panel itself enters the tree.
	_upload_health_request = HTTPRequest.new()
	_upload_health_request.name = "UploadHealthRequest"
	_upload_health_request.timeout = UPLOAD_HEALTH_TIMEOUT_S
	_upload_health_request.use_threads = true
	add_child(_upload_health_request)
	_upload_health_request.request_completed.connect(_on_upload_health_completed)


func _process(delta: float) -> void:
	super._process(delta)
	if not visible or _live_server_mode:
		return
	_storage_refresh_accum += delta
	if _storage_refresh_accum >= STORAGE_REFRESH_SECONDS:
		_storage_refresh_accum = 0.0
		_refresh_storage_usage()


func get_options() -> Dictionary:
	# interaction_mode is intentionally NOT returned here. The router's
	# persisted/automation override lives in capture_app.gd::capture_options;
	# runtime hand/controller detection is kept out of saved settings.
	var options := {
		"stereo_rgb": _toggle_enabled("stereo_rgb"),
		# NOTE: deliberately NOT gated on _depth_supported. capture_app.gd owns
		# depth gating for unsupported providers (Pico) via its
		# _update_depth_support_flag()/_effective_capture_options() force-off,
		# which run with the camera plugin bound. Gating here too races against
		# the provider probe: at _setup_ui the panel options are merged into
		# capture_options while _depth_supported is still false, latching depth
		# off even on Quest where it IS supported.
		"record_depth": _toggle_enabled("record_depth"),
		"record_head_pose": _toggle_enabled("record_head_pose"),
		"record_controller_pose": _toggle_enabled("record_controller_pose"),
		"record_hand_data": _toggle_enabled("record_hand_data"),
		"record_body_tracking": _toggle_enabled("record_body_tracking"),
		# Same rationale as record_depth above: NOT gated on
		# _motion_tracker_supported. capture_app.gd force-offs trackers for
		# non-Pico providers via _update_motion_tracker_support_flag() and
		# _effective_capture_options(); gating here too races the provider
		# probe and latches trackers off on Pico (where they ARE supported)
		# when the panel options are merged at _setup_ui.
		"record_motion_trackers": _toggle_enabled("record_motion_trackers"),
		"max_motion_trackers": 2,
		# v3 spatial audio: opt-in for privacy. The toggle defaults off below
		# (default_on=false in _add_stream_toggle) so a recording never opens
		# the mic without the operator explicitly enabling it.
		"record_audio": _toggle_enabled("record_audio")
	}
	var rgb_resolution := _selected_rgb_resolution()
	options["rgb_width"] = rgb_resolution.x
	options["rgb_height"] = rgb_resolution.y
	options["rgb_resolution"] = _resolution_text(rgb_resolution)
	options["rgb_fps"] = _selected_rgb_fps()
	options["rgb_codec"] = _selected_rgb_codec()
	if _live_server_mode:
		options["server_host"] = _configured_server_host()
		options["server_port"] = _configured_server_port()
		options["server_result_port"] = _configured_result_port()
		options["server_auth_token"] = _server_token.text.strip_edges() if _server_token != null else ""
		options["save_controller_hand_sidecar"] = false
		options["save_body_sidecar"] = false
		options["save_root"] = ""
		options["upload_url"] = ""
		options["upload_token"] = ""
		options["upload_on_finalize"] = false
		options["keep_local_after_upload"] = true
	else:
		options["show_hand_skeleton_overlay"] = _toggle_enabled_or_default("show_hand_skeleton_overlay")
		options["save_controller_hand_sidecar"] = _toggle_enabled("save_controller_hand_sidecar")
		options["save_body_sidecar"] = _toggle_enabled("save_body_sidecar")
		options["save_root"] = _configured_save_root()
		options["upload_url"] = _upload_url.text.strip_edges() if _upload_url else ""
		options["upload_token"] = _upload_token
		options["upload_on_finalize"] = _toggle_enabled("upload_on_finalize") and _upload_url_can_auto_upload()
		options["keep_local_after_upload"] = _toggle_enabled("keep_local_after_upload")
	return options


func set_options(options: Dictionary) -> void:
	# We deliberately do NOT read `interaction_mode` from the options dict
	# here. capture_app.gd owns both the persisted override and the runtime
	# detection state; the panel only mirrors the detected indicator and
	# stream defaults.
	for key in _stream_toggles.keys():
		var toggle := _stream_toggles[key] as CheckButton
		if toggle == null:
			continue
		var value := bool(options.get(key, _default_value_for_key(key)))
		# For the input-source mutex pair, bypass the `toggled` signal so
		# bulk-load doesn't fire the mutex callback (which would otherwise
		# silently flip whichever key arrived second based on Dictionary
		# iteration order). We resolve any "both true" config explicitly
		# below via _enforce_input_source_mutex_from_loaded_state().
		if INPUT_SOURCE_MUTEX.has(key) or key == "upload_on_finalize":
			toggle.set_pressed_no_signal(value)
		else:
			toggle.button_pressed = value
	_enforce_input_source_mutex_from_loaded_state()
	_requested_rgb_resolution = _resolution_from_options(options)
	_requested_rgb_fps = int(options.get("rgb_fps", DEFAULT_RGB_FPS))
	_requested_rgb_codec = _normalize_rgb_codec(str(options.get("rgb_codec", DEFAULT_RGB_CODEC)))
	_refresh_rgb_selects()
	if _save_root != null:
		var save_root := str(options.get("save_root", DEFAULT_SAVE_ROOT)).strip_edges()
		_save_root.text = DEFAULT_SAVE_ROOT if save_root.is_empty() else save_root
	if _upload_url != null:
		_upload_url.text = str(options.get("upload_url", ""))
	_clear_upload_url_ready()
	_upload_token = str(options.get("upload_token", ""))
	_enforce_auto_upload_ready(false)
	if _server_host != null:
		var server_host := str(options.get("server_host", DEFAULT_LIVE_SERVER_HOST)).strip_edges()
		_server_host.text = DEFAULT_LIVE_SERVER_HOST if server_host.is_empty() else server_host
	if _server_port != null:
		_server_port.value = clampi(int(options.get("server_port", DEFAULT_LIVE_SERVER_PORT)), 1, 65535)
	if _result_port != null:
		_result_port.value = clampi(int(options.get("server_result_port", DEFAULT_LIVE_RESULT_PORT)), 1, 65535)
	if _server_token != null:
		_server_token.text = str(options.get("server_auth_token", ""))
	_storage_refresh_accum = STORAGE_REFRESH_SECONDS
	if is_inside_tree() and not _live_server_mode:
		_refresh_storage_usage()


func open() -> void:
	super.open()
	if _live_server_mode:
		return
	_show_upload_main_menu()
	_storage_refresh_accum = STORAGE_REFRESH_SECONDS
	_refresh_storage_usage()
	# Don't auto-probe on open — every open() would hit the operator's
	# network even when they're just toggling a stream switch. Reset
	# the status row so a stale result from a previous open doesn't
	# linger, and let the operator press the pulse button to actually
	# run the check.
	if _upload_status_label != null:
		_upload_status_label.text = ""
		_upload_status_label.visible = false


func set_live_server_defaults(host: String, port: int, token: String = "", result_port: int = DEFAULT_LIVE_RESULT_PORT) -> void:
	if _server_host != null:
		_server_host.text = host if not host.strip_edges().is_empty() else DEFAULT_LIVE_SERVER_HOST
	if _server_port != null:
		_server_port.value = clampi(port, 1, 65535)
	if _server_token != null:
		_server_token.text = token
	if _result_port != null:
		_result_port.value = clampi(result_port, 1, 65535)


func show_live_server_settings() -> void:
	if _live_server_mode:
		select_group("live")
	open()


func _build_settings_content(parent: VBoxContainer) -> void:
	build_two_column(parent)

	if _live_server_mode:
		_build_live_server_group()

	# Control-mode picker used to live here as an OptionButton (controllers /
	# hands / head). It moved out of the UI per the auto-detect redesign --
	# the active source is sensed at runtime and surfaced via the title-bar
	# indicator (see set_input_mode_indicator()), so there is nothing for the
	# operator to choose any more.

	# --- Streams group -----------------------------------------------------
	var streams := register_group("streams", "UI_CAPTURED_STREAMS", "camera")
	_add_stream_toggle(streams, "stereo_rgb", tr("UI_STEREO_RGB"))
	_add_stream_toggle(streams, "record_depth", tr("UI_DEPTH"))
	# Depth capture is Quest-only today (XR_META_environment_depth). Like the
	# motion-tracker row below, hide the slot until capture_app confirms the
	# provider supports it so a Pico operator never flips a switch that
	# silently records nothing.
	_depth_toggle = _stream_toggles.get("record_depth")
	_set_depth_row_visible(_depth_supported)
	_add_stream_toggle(streams, "record_head_pose", tr("UI_HEAD_POSE"))
	_add_stream_toggle(streams, "record_controller_pose", tr("UI_CONTROLLER_POSES"))
	_add_stream_toggle(streams, "record_hand_data", tr("UI_HAND_JOINTS"), false)
	# Hand vs. controller capture is one-or-the-other -- wire the mutex
	# before any other state is loaded so set_options (which fires below
	# via _load_settings()) still goes through the same enforcement.
	_wire_input_source_mutex()
	_add_stream_toggle(streams, "record_body_tracking", tr("UI_BODY_TRACKING"))
	_add_stream_toggle(streams, "record_motion_trackers", tr("UI_MOTION_TRACKERS"))
	# Motion-tracker capture is a PICO-only stream (powered by the PICO
	# body-tracking extension). On other runtimes we hide the toggle slot
	# entirely instead of letting the operator flip a switch that silently
	# writes no data.
	_motion_tracker_toggle = _stream_toggles.get("record_motion_trackers")
	_set_motion_tracker_row_visible(_motion_tracker_supported)

	_tracker_section_label = _add_section_label_to(streams, "UI_TRACKER_SETUP")
	_tracker_status_label = _add_status_label_to(streams, "")
	_tracker_connect_button = Button.new()
	_tracker_connect_button.text = tr("UI_CONNECT_PICO_TRACKERS")
	_tracker_connect_button.custom_minimum_size.y = 55
	_tracker_connect_button.add_theme_font_size_override("font_size", 21)
	_tracker_connect_button.pressed.connect(func() -> void: tracker_connect_requested.emit())
	_tracker_connect_slot = add_interactive(streams, _tracker_connect_button)
	set_pico_tracker_status(false, false, 0, false, false, false)

	# Audio opens the microphone and is renamed to a plain "Audio" toggle now
	# that the rest of the capture flow treats it as a first-class stream
	# rather than a niche opt-in. The runtime RECORD_AUDIO permission still
	# gates the actual recording downstream, so a denied prompt degrades to
	# video-only instead of failing the session.
	_add_stream_toggle(streams, "record_audio", tr("UI_RECORD_AUDIO"), true)

	# --- Display group -----------------------------------------------------
	if not _live_server_mode:
		var display := register_group("display", "UI_GROUP_DISPLAY", "settings")
		_add_stream_toggle(display, "show_hand_skeleton_overlay", tr("UI_SHOW_HAND_SKELETON_OVERLAY"), true)

	# --- Robot constraint group -------------------------------------------
	var robot_constraint := register_group("robot_constraint", "UI_ROBOT_CONSTRAINT_GROUP", "robot-arm")
	_body_pose_debug_button = Button.new()
	_body_pose_debug_button.text = tr("UI_SHOW_BODY_POSE_DEBUG")
	_body_pose_debug_button.custom_minimum_size.y = 55
	_body_pose_debug_button.add_theme_font_size_override("font_size", 21)
	_body_pose_debug_button.pressed.connect(_on_body_pose_debug_pressed)
	add_interactive(robot_constraint, _body_pose_debug_button)

	_h2_debug_button = Button.new()
	_h2_debug_button.text = tr("UI_SHOW_H2_DEBUG")
	_h2_debug_button.custom_minimum_size.y = 55
	_h2_debug_button.add_theme_font_size_override("font_size", 21)
	_h2_debug_button.pressed.connect(_on_h2_debug_pressed)
	add_interactive(robot_constraint, _h2_debug_button)

	_g1_debug_button = Button.new()
	_g1_debug_button.text = tr("UI_SHOW_G1_DEBUG")
	_g1_debug_button.custom_minimum_size.y = 55
	_g1_debug_button.add_theme_font_size_override("font_size", 21)
	_g1_debug_button.pressed.connect(_on_g1_debug_pressed)
	add_interactive(robot_constraint, _g1_debug_button)

	if _live_server_mode:
		return

	# --- Outputs group -----------------------------------------------------
	var outputs := register_group("outputs", "UI_OUTPUTS", "check")
	_add_rgb_recording_controls(outputs)
	# Controller/hand poses always go into the MP4 mett tracks. This toggle only
	# controls whether they are ALSO written as separate JSONL sidecar files for
	# debugging. Default off to avoid the extra main-thread JSON cost.
	_add_stream_toggle(outputs, "save_controller_hand_sidecar", tr("UI_CONTROLLER_HAND_SIDECAR"), false)
	# Body joints likewise always land in the MP4 mett body_joints track; this
	# toggle only adds the JSONL sidecar (the one place the frame-level
	# body_flags + PICO velocity/acceleration extras are preserved).
	_add_stream_toggle(outputs, "save_body_sidecar", tr("UI_BODY_SIDECAR"), false)

	# --- Storage group -----------------------------------------------------
	var storage := register_group("storage", "UI_GROUP_STORAGE", "plug")

	_save_root = LineEdit.new()
	_save_root.text = DEFAULT_SAVE_ROOT
	_save_root.placeholder_text = DEFAULT_SAVE_ROOT
	_save_root.custom_minimum_size.y = 55
	_save_root.add_theme_font_size_override("font_size", 19)
	_save_root.text_changed.connect(_on_save_root_changed)
	add_interactive(storage, _save_root)

	_storage_label = _add_status_label_to(storage, tr("UI_STORAGE_CHECKING"))

	_storage_view_button = Button.new()
	_storage_view_button.text = tr("UI_STORAGE_VIEW")
	_storage_view_button.tooltip_text = tr("UI_STORAGE_VIEW_TOOLTIP")
	_storage_view_button.custom_minimum_size.y = 55
	_storage_view_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_storage_view_button.add_theme_font_size_override("font_size", 21)
	_storage_view_button.pressed.connect(_on_storage_view_button_pressed)
	add_interactive(storage, _storage_view_button)

	# --- Upload group ------------------------------------------------------
	# Optional: if `upload_url` is non-empty and `upload_on_finalize` is
	# on, every finalized session is queued for resumable upload (TUS
	# 1.0.0) to the configured endpoint. See
	# `claw/issues/010-ego-data-upload.md`. Settings persist via
	# BaseSettingsPanel across app launches.
	var upload := register_group("upload", "UI_UPLOAD", "signal")
	_upload_main_view = VBoxContainer.new()
	_upload_main_view.add_theme_constant_override("separation", 14)
	_upload_main_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_upload_main_view.size_flags_vertical = Control.SIZE_FILL
	upload.add_child(_upload_main_view)

	# [LineEdit — Upload URL] [💓 health-check] [📷 scan]
	# The health-check button (pulse icon) probes the configured URL
	# on demand — no auto-trigger on panel open, so we don't hit the
	# operator's network every time they tweak a stream toggle.
	# The QR scan button (camera icon) only renders on Android (gated
	# by _qr_scan_supported), where the QR Scanner plugin AAR is bundled
	# into the APK. On macOS / Linux dev builds the row is just the
	# LineEdit + the health-check button. See
	# claw/issues/011-xr-qr-scanner.md.
	var upload_url_row := HBoxContainer.new()
	upload_url_row.add_theme_constant_override("separation", 8)
	upload_url_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_upload_main_view.add_child(upload_url_row)

	_upload_url = LineEdit.new()
	_upload_url.placeholder_text = "https://my-ingest.local:8443/ingest"
	_upload_url.custom_minimum_size.y = 55
	_upload_url.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_upload_url.add_theme_font_size_override("font_size", 19)
	_upload_url.text_changed.connect(_on_upload_url_text_changed)
	add_interactive(upload_url_row, _upload_url)

	# Manual health-check trigger. Always available — even on desktop
	# dev builds we want a way to verify the server is up.
	_add_url_action_button(
		upload_url_row,
		"pulse",
		tr("UI_UPLOAD_HEALTH_CHECK_TOOLTIP"),
		_on_health_check_button_pressed
	)

	if _qr_scan_supported():
		_add_url_action_button(
			upload_url_row,
			"camera",
			tr("UI_SCAN_QR_TOOLTIP"),
			_on_scan_button_pressed
		)

	_upload_status_label = _add_status_label_to(_upload_main_view, "")
	_upload_status_label.visible = false

	var auto_upload_toggle := _add_stream_toggle(_upload_main_view, "upload_on_finalize", tr("UI_AUTO_UPLOAD_ON_STOP"), true)
	auto_upload_toggle.toggled.connect(_on_upload_on_finalize_toggled)
	_add_stream_toggle(_upload_main_view, "keep_local_after_upload", tr("UI_KEEP_LOCAL_AFTER_UPLOAD"), true)

	_manual_upload_button = Button.new()
	_manual_upload_button.text = tr("UI_UPLOAD_LOCAL_RECORDINGS")
	_manual_upload_button.custom_minimum_size.y = 55
	_manual_upload_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_manual_upload_button.add_theme_font_size_override("font_size", 21)
	_manual_upload_button.pressed.connect(_on_local_upload_button_pressed)
	add_interactive(_upload_main_view, _manual_upload_button)
	_sync_manual_upload_button_state()
	_build_local_upload_menu(parent)


func _build_live_server_group() -> void:
	var live := register_group("live", "UI_LIVE_SERVER", "signal")
	_add_field_label(live, tr("UI_LIVE_SERVER_HOST"))
	var server_host_row := HBoxContainer.new()
	server_host_row.add_theme_constant_override("separation", 8)
	server_host_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	live.add_child(server_host_row)

	_server_host = LineEdit.new()
	_server_host.text = DEFAULT_LIVE_SERVER_HOST
	_server_host.placeholder_text = tr("UI_LIVE_SERVER_HOST")
	_server_host.custom_minimum_size.y = 55
	_server_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_server_host.add_theme_font_size_override("font_size", 19)
	# Any keystroke invalidates a prior successful connection (it was bound
	# to the old host) and dismisses a stale "must connect" callout.
	_server_host.text_changed.connect(_on_server_host_text_changed)
	add_interactive(server_host_row, _server_host)

	if _qr_scan_supported():
		_add_url_action_button(
			server_host_row,
			"camera",
			tr("UI_SCAN_SERVER_QR_TOOLTIP"),
			_on_scan_live_server_button_pressed
		)
	_add_live_connect_button(server_host_row)
	# Callout sits between the host row and the connection-status label so the
	# warning visually attaches to the input the user must fix.
	_build_live_server_required_callout(live)
	_live_server_status_label = _add_status_label_to(live, "")
	_live_server_status_label.visible = false

	_add_field_label(live, tr("UI_LIVE_SERVER_PORT"))
	_server_port = SpinBox.new()
	_server_port.min_value = 1
	_server_port.max_value = 65535
	_server_port.step = 1
	_server_port.value = DEFAULT_LIVE_SERVER_PORT
	_server_port.prefix = "%s " % tr("UI_LIVE_SERVER_PORT")
	_server_port.custom_minimum_size.y = 55
	_server_port.add_theme_font_size_override("font_size", 19)
	add_interactive(live, _server_port)

	_add_field_label(live, tr("UI_LIVE_RESULT_PORT"))
	_result_port = SpinBox.new()
	_result_port.min_value = 1
	_result_port.max_value = 65535
	_result_port.step = 1
	_result_port.value = DEFAULT_LIVE_RESULT_PORT
	_result_port.prefix = "%s " % tr("UI_LIVE_RESULT_PORT")
	_result_port.custom_minimum_size.y = 55
	_result_port.add_theme_font_size_override("font_size", 19)
	add_interactive(live, _result_port)

	_add_field_label(live, tr("UI_LIVE_SERVER_TOKEN"))
	_server_token = LineEdit.new()
	_server_token.placeholder_text = tr("UI_LIVE_SERVER_TOKEN")
	_server_token.secret = true
	_server_token.custom_minimum_size.y = 55
	_server_token.add_theme_font_size_override("font_size", 19)
	add_interactive(live, _server_token)


func _on_confirm_requested() -> void:
	# Live-feed mode requires a configured + connected live server before the
	# user can leave settings — otherwise capture starts pointing at a dead
	# endpoint. Surface the reason inline next to the host input instead of
	# silently failing the dependent steps later.
	if _live_server_mode:
		var blocker := _live_server_save_blocker()
		if blocker != "":
			_show_live_server_required_callout(blocker)
			return
	var options := get_options()
	_save_settings(options)
	close()
	saved.emit(options)


func _add_stream_toggle(parent: Container, key: String, label: String, default_on: bool = true) -> CheckButton:
	var toggle := add_toggle(parent, label, default_on, 23)
	_stream_toggles[key] = toggle
	return toggle


func _add_section_label_to(parent: Container, text_key: String) -> Label:
	var lbl := Label.new()
	lbl.text = tr(text_key)
	lbl.add_theme_font_size_override("font_size", 21)
	lbl.add_theme_color_override("font_color", COL_SECTION)
	parent.add_child(lbl)
	return lbl


func _add_status_label_to(parent: Container, initial_text: String) -> Label:
	# add_status_label() in BaseSettingsPanel hard-codes _content as the parent,
	# but in the two-column layout we want the label inside a specific group.
	var lbl := Label.new()
	lbl.text = initial_text
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.add_theme_color_override("font_color", COL_STATUS)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(lbl)
	return lbl


func _on_body_pose_debug_pressed() -> void:
	emit_signal("body_pose_debug_toggled")


func _on_h2_debug_pressed() -> void:
	emit_signal("h2_debug_toggled")


func _on_g1_debug_pressed() -> void:
	emit_signal("g1_debug_toggled")


func set_body_pose_debug_visible(visible_for_debug: bool) -> void:
	if _body_pose_debug_button == null:
		return
	_body_pose_debug_button.text = tr("UI_HIDE_BODY_POSE_DEBUG") if visible_for_debug else tr("UI_SHOW_BODY_POSE_DEBUG")


func set_h2_debug_visible(visible_for_debug: bool) -> void:
	if _h2_debug_button == null:
		return
	_h2_debug_button.text = tr("UI_HIDE_H2_DEBUG") if visible_for_debug else tr("UI_SHOW_H2_DEBUG")


func set_g1_debug_visible(visible_for_debug: bool) -> void:
	if _g1_debug_button == null:
		return
	_g1_debug_button.text = tr("UI_HIDE_G1_DEBUG") if visible_for_debug else tr("UI_SHOW_G1_DEBUG")


func set_pico_tracker_status(
		visible_for_capture: bool,
		connected: bool,
		tracker_count: int,
		request_sent: bool,
		can_open_setup: bool,
		opening_setup: bool
) -> void:
	if _tracker_section_label == null or _tracker_status_label == null or _tracker_connect_button == null or _tracker_connect_slot == null:
		return
	_tracker_section_label.visible = visible_for_capture
	_tracker_status_label.visible = visible_for_capture
	_tracker_connect_slot.visible = visible_for_capture and not connected
	if not visible_for_capture:
		return
	if connected:
		_tracker_status_label.text = tr("UI_PICO_TRACKERS_CONNECTED") % tracker_count
		_tracker_connect_button.disabled = true
		return
	if opening_setup:
		_tracker_status_label.text = tr("UI_OPENING_TRACKER_SETUP")
	elif request_sent:
		_tracker_status_label.text = tr("UI_PICO_TRACKER_REQUEST_SENT")
	else:
		_tracker_status_label.text = tr("UI_PICO_TRACKERS_DISCONNECTED")
	_tracker_connect_button.disabled = not can_open_setup or opening_setup
	_tracker_connect_button.text = tr("UI_OPENING_TRACKER_SETUP") if opening_setup else tr("UI_CONNECT_PICO_TRACKERS")


## Push the auto-detected input source ("hands" / "controllers" / "head")
## into the panel. Updates ONLY the title-bar indicator and the record-
## stream defaults; the panel never persists or owns the active pointer mode.
##
##   - hands       -> hand icon,        record_hand_data on,   record_controller_pose off
##   - controllers -> controller icon,  record_controller_pose on, record_hand_data off
## "head" (volume-button capture) reuses the controller icon and leaves the
## record toggles alone because the operator is still physically holding a
## controller.
func set_interaction_mode(mode: String) -> void:
	var normalized := mode
	if normalized != "hands" and normalized != "controllers" and normalized != "head":
		normalized = "controllers"
	var changed := normalized != _indicator_mode
	_indicator_mode = normalized
	set_input_mode_indicator(normalized)
	if not changed:
		return
	# Only auto-flip stream defaults for the gesture / controller swap. The
	# head-buttons path is a niche capture flow that should keep whichever
	# combination the operator picked manually.
	if normalized == "hands":
		_force_stream_default("record_hand_data", true)
		_force_stream_default("record_controller_pose", false)
	elif normalized == "controllers":
		_force_stream_default("record_controller_pose", true)
		_force_stream_default("record_hand_data", false)


## Declares whether the bound capture provider can produce motion-tracker
## data (PICO only, today). When false the UI row is hidden and the saved
## option is forced off so a non-PICO build never claims to record trackers
## it cannot read.
func set_motion_tracker_supported(supported: bool) -> void:
	_motion_tracker_supported = supported
	_set_motion_tracker_row_visible(supported)
	if not supported and _motion_tracker_toggle != null:
		_motion_tracker_toggle.button_pressed = false


func _set_motion_tracker_row_visible(visible_for_capture: bool) -> void:
	if _motion_tracker_toggle == null:
		return
	var slot := _motion_tracker_toggle.get_parent()
	if slot is Control:
		(slot as Control).visible = visible_for_capture


## Declares whether the bound capture provider can produce environment-depth
## data (Quest only, today). When false the UI row is hidden and the saved
## option is forced off so the recording manifest never advertises a depth
## stream the device cannot read.
func set_depth_supported(supported: bool) -> void:
	_depth_supported = supported
	_set_depth_row_visible(supported)
	if not supported and _depth_toggle != null:
		_depth_toggle.button_pressed = false


func _set_depth_row_visible(visible_for_capture: bool) -> void:
	if _depth_toggle == null:
		return
	var slot := _depth_toggle.get_parent()
	if slot is Control:
		(slot as Control).visible = visible_for_capture


func set_capture_provider_name(provider: String) -> void:
	var normalized := provider.strip_edges().to_lower()
	if normalized != "pico" and normalized != "quest":
		normalized = RGB_PROVIDER_DEFAULT
	if _capture_provider_name == normalized:
		return
	_capture_provider_name = normalized
	_refresh_rgb_selects()


func _rgb_provider_key() -> String:
	return "pico" if _capture_provider_name == "pico" else "quest"


func _refresh_rgb_selects() -> void:
	_refreshing_rgb_selects = true
	_rebuild_rgb_resolution_select()
	_rebuild_rgb_fps_select()
	_rebuild_rgb_codec_select()
	_refreshing_rgb_selects = false


func _rebuild_rgb_resolution_select() -> void:
	if _rgb_resolution_button == null:
		return
	var provider := _rgb_provider_key()
	var selected_text := _requested_rgb_resolution
	var fallback: Vector2i = RGB_DEFAULT_RESOLUTION.get(provider, RGB_DEFAULT_RESOLUTION[RGB_PROVIDER_DEFAULT])
	var fallback_text := _resolution_text(fallback)
	if selected_text.is_empty():
		selected_text = fallback_text
	_clear_rgb_menu(_rgb_resolution_menu)
	var choices: Array = RGB_RESOLUTIONS.get(provider, RGB_RESOLUTIONS[RGB_PROVIDER_DEFAULT])
	var selected_found := false
	for i in range(choices.size()):
		var resolution := choices[i] as Vector2i
		var text := _resolution_text(resolution)
		if text == selected_text:
			selected_found = true
		_add_rgb_menu_option(
			_rgb_resolution_menu,
			text,
			_on_rgb_resolution_option_pressed.bind(text)
		)
	if not selected_found:
		selected_text = fallback_text
	_requested_rgb_resolution = selected_text
	_rgb_resolution_button.text = selected_text
	if _rgb_resolution_menu != null:
		_rgb_resolution_menu.visible = false


func _rebuild_rgb_fps_select() -> void:
	if _rgb_fps_button == null:
		return
	var provider := _rgb_provider_key()
	var requested_fps := _requested_rgb_fps if _requested_rgb_fps > 0 else DEFAULT_RGB_FPS
	_clear_rgb_menu(_rgb_fps_menu)
	var fps_values: Array = RGB_FPS_VALUES.get(provider, RGB_FPS_VALUES[RGB_PROVIDER_DEFAULT])
	var selected_found := false
	for i in range(fps_values.size()):
		var fps := int(fps_values[i])
		if fps == requested_fps:
			selected_found = true
		_add_rgb_menu_option(
			_rgb_fps_menu,
			tr("UI_RGB_RECORDING_FPS_VALUE") % fps,
			_on_rgb_fps_option_pressed.bind(fps)
		)
	if not selected_found:
		requested_fps = DEFAULT_RGB_FPS
		if not fps_values.has(DEFAULT_RGB_FPS) and fps_values.size() > 0:
			requested_fps = int(fps_values[0])
	_requested_rgb_fps = requested_fps
	_rgb_fps_button.text = tr("UI_RGB_RECORDING_FPS_VALUE") % requested_fps
	if _rgb_fps_menu != null:
		_rgb_fps_menu.visible = false


func _rebuild_rgb_codec_select() -> void:
	if _rgb_codec_button == null:
		return
	var selected_codec := _normalize_rgb_codec(_requested_rgb_codec)
	_clear_rgb_menu(_rgb_codec_menu)
	for codec in RGB_CODEC_VALUES:
		var codec_text := str(codec)
		_add_rgb_menu_option(
			_rgb_codec_menu,
			_rgb_codec_label(codec_text),
			_on_rgb_codec_option_pressed.bind(codec_text)
		)
	_requested_rgb_codec = selected_codec
	_rgb_codec_button.text = _rgb_codec_label(selected_codec)
	if _rgb_codec_menu != null:
		_rgb_codec_menu.visible = false


func _add_rgb_recording_controls(parent: VBoxContainer) -> void:
	_add_field_label(parent, tr("UI_RGB_RECORDING_RESOLUTION"))
	_rgb_resolution_button = _make_rgb_dropdown_button()
	_rgb_resolution_button.pressed.connect(_on_rgb_resolution_button_pressed)
	add_interactive(parent, _rgb_resolution_button)
	_rgb_resolution_menu = _make_rgb_dropdown_menu()
	parent.add_child(_rgb_resolution_menu)

	_add_field_label(parent, tr("UI_RGB_RECORDING_FPS"))
	_rgb_fps_button = _make_rgb_dropdown_button()
	_rgb_fps_button.pressed.connect(_on_rgb_fps_button_pressed)
	add_interactive(parent, _rgb_fps_button)
	_rgb_fps_menu = _make_rgb_dropdown_menu()
	parent.add_child(_rgb_fps_menu)

	_add_field_label(parent, tr("UI_RGB_RECORDING_CODEC"))
	_rgb_codec_button = _make_rgb_dropdown_button()
	_rgb_codec_button.pressed.connect(_on_rgb_codec_button_pressed)
	add_interactive(parent, _rgb_codec_button)
	_rgb_codec_menu = _make_rgb_dropdown_menu()
	parent.add_child(_rgb_codec_menu)
	_refresh_rgb_selects()


func _make_rgb_dropdown_button() -> Button:
	var button := Button.new()
	button.custom_minimum_size.y = 55
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.clip_text = true
	button.add_theme_font_size_override("font_size", 21)
	return button


func _make_rgb_dropdown_menu() -> VBoxContainer:
	var menu := VBoxContainer.new()
	menu.visible = false
	menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu.add_theme_constant_override("separation", 4)
	return menu


func _add_rgb_menu_option(parent: VBoxContainer, text: String, callback: Callable) -> void:
	if parent == null:
		return
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 47
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.clip_text = true
	button.add_theme_font_size_override("font_size", 20)
	button.pressed.connect(callback)
	add_interactive(parent, button)


func _clear_rgb_menu(menu: VBoxContainer) -> void:
	if menu == null:
		return
	for child in menu.get_children():
		menu.remove_child(child)
		child.queue_free()


func _on_rgb_resolution_button_pressed() -> void:
	if _refreshing_rgb_selects or _rgb_resolution_menu == null:
		return
	_rgb_resolution_menu.visible = not _rgb_resolution_menu.visible
	if _rgb_fps_menu != null:
		_rgb_fps_menu.visible = false
	if _rgb_codec_menu != null:
		_rgb_codec_menu.visible = false


func _on_rgb_fps_button_pressed() -> void:
	if _refreshing_rgb_selects or _rgb_fps_menu == null:
		return
	_rgb_fps_menu.visible = not _rgb_fps_menu.visible
	if _rgb_resolution_menu != null:
		_rgb_resolution_menu.visible = false
	if _rgb_codec_menu != null:
		_rgb_codec_menu.visible = false


func _on_rgb_codec_button_pressed() -> void:
	if _refreshing_rgb_selects or _rgb_codec_menu == null:
		return
	_rgb_codec_menu.visible = not _rgb_codec_menu.visible
	if _rgb_resolution_menu != null:
		_rgb_resolution_menu.visible = false
	if _rgb_fps_menu != null:
		_rgb_fps_menu.visible = false


func _on_rgb_resolution_option_pressed(text: String) -> void:
	if _refreshing_rgb_selects:
		return
	_requested_rgb_resolution = text
	if _rgb_resolution_button != null:
		_rgb_resolution_button.text = text
	if _rgb_resolution_menu != null:
		_rgb_resolution_menu.visible = false


func _on_rgb_fps_option_pressed(fps: int) -> void:
	if _refreshing_rgb_selects:
		return
	_requested_rgb_fps = fps
	if _rgb_fps_button != null:
		_rgb_fps_button.text = tr("UI_RGB_RECORDING_FPS_VALUE") % fps
	if _rgb_fps_menu != null:
		_rgb_fps_menu.visible = false


func _on_rgb_codec_option_pressed(codec: String) -> void:
	if _refreshing_rgb_selects:
		return
	_requested_rgb_codec = _normalize_rgb_codec(codec)
	if _rgb_codec_button != null:
		_rgb_codec_button.text = _rgb_codec_label(_requested_rgb_codec)
	if _rgb_codec_menu != null:
		_rgb_codec_menu.visible = false


func _selected_rgb_resolution() -> Vector2i:
	return _parse_resolution_text(_selected_rgb_resolution_text())


func _selected_rgb_resolution_text() -> String:
	if not _requested_rgb_resolution.is_empty():
		return _requested_rgb_resolution
	var provider := _rgb_provider_key()
	return _resolution_text(RGB_DEFAULT_RESOLUTION.get(provider, RGB_DEFAULT_RESOLUTION[RGB_PROVIDER_DEFAULT]))


func _selected_rgb_fps() -> int:
	return _requested_rgb_fps if _requested_rgb_fps > 0 else DEFAULT_RGB_FPS


func _selected_rgb_codec() -> String:
	return _normalize_rgb_codec(_requested_rgb_codec)


func _rgb_codec_label(codec: String) -> String:
	if _normalize_rgb_codec(codec) == RGB_CODEC_H264:
		return tr("UI_RGB_CODEC_H264")
	return tr("UI_RGB_CODEC_HEVC")


func _normalize_rgb_codec(codec: String) -> String:
	var normalized := codec.strip_edges().to_lower()
	if normalized in ["h265", "h.265", "video/hevc"]:
		return RGB_CODEC_HEVC
	if normalized in ["avc", "h.264", "video/avc"]:
		return RGB_CODEC_H264
	if RGB_CODEC_VALUES.has(normalized):
		return normalized
	return DEFAULT_RGB_CODEC


func _resolution_from_options(options: Dictionary) -> String:
	var explicit := str(options.get("rgb_resolution", "")).strip_edges()
	if not explicit.is_empty():
		return explicit
	var width := int(options.get("rgb_width", 0))
	var height := int(options.get("rgb_height", 0))
	if width > 0 and height > 0:
		return "%dx%d" % [width, height]
	return ""


func _resolution_text(resolution: Vector2i) -> String:
	return "%dx%d" % [resolution.x, resolution.y]


func _parse_resolution_text(text: String) -> Vector2i:
	var normalized := text.strip_edges().to_lower()
	var parts := normalized.split("x", false, 2)
	if parts.size() != 2:
		var provider := _rgb_provider_key()
		return RGB_DEFAULT_RESOLUTION.get(provider, RGB_DEFAULT_RESOLUTION[RGB_PROVIDER_DEFAULT])
	return Vector2i(maxi(1, int(parts[0])), maxi(1, int(parts[1])))


func _force_stream_default(key: String, value: bool) -> void:
	if not _stream_toggles.has(key):
		return
	var toggle := _stream_toggles[key] as CheckButton
	if toggle == null:
		return
	toggle.button_pressed = value


# Hook the mutex pair so the user clicking either toggle disables its
# partner. We connect once after both toggles have been registered. The
# callback only acts when the toggle was just enabled -- a disable never
# implies the partner should flip back on -- so the partner's own
# `toggled` signal fires with `enabled=false`, hits this same callback,
# and short-circuits. No recursion guard needed.
func _wire_input_source_mutex() -> void:
	for primary in INPUT_SOURCE_MUTEX.keys():
		var toggle := _stream_toggles.get(primary) as CheckButton
		if toggle == null:
			continue
		toggle.toggled.connect(_on_input_source_toggled.bind(primary))


func _on_input_source_toggled(enabled: bool, key: String) -> void:
	if not enabled:
		return
	var partner_key := String(INPUT_SOURCE_MUTEX.get(key, ""))
	if partner_key.is_empty():
		return
	var partner := _stream_toggles.get(partner_key) as CheckButton
	if partner == null or not partner.button_pressed:
		return
	# set_pressed_no_signal so we don't bounce back through this handler
	# (and don't trigger the toggle_off click sound from add_interactive,
	# which would feel like a phantom UI click to the operator).
	partner.set_pressed_no_signal(false)


# After bulk-loading toggle state from disk we may still have a config
# where both mutex partners are recorded as true (e.g. an install that
# pre-dates this rule, or a hand-edited cfg). Resolve it deterministically
# so the panel never displays a contradictory state: prefer the value the
# operator most recently confirmed via `_indicator_mode`, otherwise fall
# back to keeping `record_controller_pose` enabled because the runtime
# also defaults to the controllers interaction mode.
func _enforce_input_source_mutex_from_loaded_state() -> void:
	var hand_toggle := _stream_toggles.get("record_hand_data") as CheckButton
	var controller_toggle := _stream_toggles.get("record_controller_pose") as CheckButton
	if hand_toggle == null or controller_toggle == null:
		return
	if not (hand_toggle.button_pressed and controller_toggle.button_pressed):
		return
	var keep_hands := _indicator_mode == "hands"
	if keep_hands:
		controller_toggle.set_pressed_no_signal(false)
	else:
		hand_toggle.set_pressed_no_signal(false)


func _add_field_label(parent: Container, text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.add_theme_color_override("font_color", COL_SECTION)
	parent.add_child(lbl)
	return lbl


func _toggle_enabled(key: String) -> bool:
	var toggle: CheckButton = _stream_toggles[key]
	return toggle.button_pressed


func _toggle_enabled_or_default(key: String) -> bool:
	var toggle := _stream_toggles.get(key) as CheckButton
	if toggle == null:
		return bool(_default_value_for_key(key))
	return toggle.button_pressed


func _upload_url_can_auto_upload() -> bool:
	if _upload_url == null:
		return false
	var url := _upload_url.text.strip_edges()
	return not url.is_empty() and _upload_url_ready and _upload_url_ready_value == url


func _sync_manual_upload_button_state() -> void:
	if _manual_upload_button == null:
		return
	var ready := _upload_url_can_auto_upload()
	_manual_upload_button.disabled = not ready
	_manual_upload_button.tooltip_text = "" if ready else tr("UI_UPLOAD_MANUAL_REQUIRES_READY")
	if not ready and _local_file_menu_mode == LOCAL_FILE_MODE_UPLOAD and _local_upload_view != null and _local_upload_view.visible:
		_show_upload_main_menu()


func _mark_upload_url_ready(url: String) -> void:
	_upload_url_ready_value = url.strip_edges()
	_upload_url_ready = not _upload_url_ready_value.is_empty()
	_upload_health_pending_url = ""
	_sync_manual_upload_button_state()


func _clear_upload_url_ready() -> void:
	_upload_url_ready = false
	_upload_url_ready_value = ""
	_upload_health_pending_url = ""
	_sync_manual_upload_button_state()


func _enforce_auto_upload_ready(show_message: bool = true) -> void:
	if not _stream_toggles.has("upload_on_finalize"):
		return
	var toggle := _stream_toggles["upload_on_finalize"] as CheckButton
	if toggle == null or not toggle.button_pressed:
		return
	if _upload_url_can_auto_upload():
		return
	toggle.set_pressed_no_signal(false)
	if show_message:
		set_upload_connectivity_status(tr("UI_UPLOAD_AUTO_REQUIRES_READY"), "warning")


func _on_upload_url_text_changed(_new_text: String) -> void:
	_clear_upload_url_ready()
	_enforce_auto_upload_ready(true)


func _on_upload_on_finalize_toggled(enabled: bool) -> void:
	if enabled:
		_enforce_auto_upload_ready(true)


func _build_local_upload_menu(parent: Container) -> void:
	_local_upload_view = VBoxContainer.new()
	_local_upload_view.add_theme_constant_override("separation", 14)
	_local_upload_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_local_upload_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(_local_upload_view)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_local_upload_view.add_child(header)

	var back_button := Button.new()
	back_button.text = tr("UI_UPLOAD_BACK_TO_SETTINGS")
	_apply_button_icon(back_button, "arrow-left")
	back_button.custom_minimum_size = Vector2(190, 52)
	back_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	back_button.add_theme_font_size_override("font_size", 18)
	back_button.pressed.connect(_on_local_upload_close_pressed)
	add_interactive(header, back_button)

	_local_file_title_label = Label.new()
	_local_file_title_label.text = tr("UI_UPLOAD_LOCAL_RECORDINGS")
	_local_file_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_local_file_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_local_file_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_local_file_title_label.add_theme_font_size_override("font_size", 24)
	_local_file_title_label.add_theme_color_override("font_color", COL_TITLE)
	header.add_child(_local_file_title_label)

	_local_upload_status_label = _add_status_label_to(_local_upload_view, "")

	_local_upload_scroll = ScrollContainer.new()
	_local_upload_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_local_upload_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_local_upload_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_local_upload_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_local_upload_view.add_child(_local_upload_scroll)

	_local_upload_list = VBoxContainer.new()
	_local_upload_list.add_theme_constant_override("separation", 8)
	_local_upload_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_local_upload_scroll.add_child(_local_upload_list)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	actions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_local_upload_view.add_child(actions)

	_local_upload_upload_button = Button.new()
	_local_upload_upload_button.text = tr("UI_UPLOAD_SELECTED")
	_local_upload_upload_button.custom_minimum_size = Vector2(190, 50)
	_local_upload_upload_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_local_upload_upload_button.add_theme_font_size_override("font_size", 19)
	_local_upload_upload_button.disabled = true
	_local_upload_upload_button.pressed.connect(_on_local_upload_confirm_pressed)
	add_interactive(actions, _local_upload_upload_button)

	var close_button := Button.new()
	close_button.text = tr("UI_UPLOAD_BACK_TO_SETTINGS")
	close_button.custom_minimum_size = Vector2(140, 50)
	close_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_button.add_theme_font_size_override("font_size", 19)
	close_button.pressed.connect(_on_local_upload_close_pressed)
	add_interactive(actions, close_button)

	_local_upload_view.visible = false


func _set_local_file_menu_mode(mode: String) -> void:
	_local_file_menu_mode = LOCAL_FILE_MODE_DELETE if mode == LOCAL_FILE_MODE_DELETE else LOCAL_FILE_MODE_UPLOAD
	if _local_file_title_label:
		_local_file_title_label.text = tr("UI_STORAGE_LOCAL_RECORDINGS") if _local_file_menu_mode == LOCAL_FILE_MODE_DELETE else tr("UI_UPLOAD_LOCAL_RECORDINGS")
	if _local_upload_upload_button:
		_local_upload_upload_button.text = tr("UI_STORAGE_DELETE_SELECTED") if _local_file_menu_mode == LOCAL_FILE_MODE_DELETE else tr("UI_UPLOAD_SELECTED")


func _local_file_count_text(count: int) -> String:
	if _local_file_menu_mode == LOCAL_FILE_MODE_DELETE:
		return tr("UI_STORAGE_LOCAL_COUNT") % count
	return tr("UI_UPLOAD_LOCAL_COUNT") % count


func _local_file_empty_text() -> String:
	if _local_file_menu_mode == LOCAL_FILE_MODE_DELETE:
		return tr("UI_STORAGE_LOCAL_EMPTY")
	return tr("UI_UPLOAD_LOCAL_EMPTY")


func _on_local_upload_button_pressed() -> void:
	if not _upload_url_can_auto_upload():
		set_upload_connectivity_status(tr("UI_UPLOAD_MANUAL_REQUIRES_READY"), "warning")
		_sync_manual_upload_button_state()
		return
	_set_local_file_menu_mode(LOCAL_FILE_MODE_UPLOAD)
	_refresh_local_upload_list()
	_show_local_upload_menu()


func _on_storage_view_button_pressed() -> void:
	_set_local_file_menu_mode(LOCAL_FILE_MODE_DELETE)
	_refresh_local_upload_list()
	_show_local_upload_menu()


func _show_local_upload_menu() -> void:
	_set_two_column_visible(false)
	_set_panel_chrome_visible(false)
	if _local_upload_view:
		_local_upload_view.visible = true
	_reset_local_upload_scroll()


func _show_upload_main_menu() -> void:
	if _local_upload_view:
		_local_upload_view.visible = false
	_set_panel_chrome_visible(true)
	_set_two_column_visible(true)
	reset_detail_scroll()


func _refresh_local_upload_list() -> void:
	_set_local_file_menu_mode(_local_file_menu_mode)
	_clear_local_upload_list()
	_local_upload_sessions = _scan_local_upload_sessions()
	_local_upload_selection.clear()
	if _local_upload_sessions.is_empty():
		if _local_upload_status_label:
			_local_upload_status_label.text = _local_file_empty_text()
		if _local_upload_upload_button:
			_local_upload_upload_button.disabled = true
		return
	if _local_upload_status_label:
		_local_upload_status_label.text = _local_file_count_text(_local_upload_sessions.size())
	for i in range(_local_upload_sessions.size()):
		var item: Dictionary = _local_upload_sessions[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_local_upload_list.add_child(row)

		var toggle := CheckButton.new()
		toggle.text = str(item.get("label", item.get("session_id", "")))
		toggle.clip_text = true
		toggle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		toggle.custom_minimum_size.y = 48
		toggle.add_theme_font_size_override("font_size", 17)
		toggle.toggled.connect(_on_local_upload_item_toggled.bind(i))
		add_interactive(row, toggle)

		var preview_button := Button.new()
		preview_button.text = tr("UI_UPLOAD_PREVIEW")
		preview_button.tooltip_text = tr("UI_UPLOAD_PREVIEW_TOOLTIP")
		preview_button.custom_minimum_size = Vector2(LOCAL_UPLOAD_PREVIEW_BUTTON_WIDTH, 48)
		preview_button.add_theme_font_size_override("font_size", 16)
		preview_button.pressed.connect(_on_local_upload_preview_pressed.bind(i))
		var preview_slot := add_interactive(row, preview_button)
		preview_slot.custom_minimum_size = Vector2(LOCAL_UPLOAD_PREVIEW_BUTTON_WIDTH, 48)
		preview_slot.size_flags_horizontal = Control.SIZE_SHRINK_END
	if _local_upload_upload_button:
		_local_upload_upload_button.disabled = true


func _clear_local_upload_list() -> void:
	if _local_upload_list == null:
		return
	for child in _local_upload_list.get_children():
		child.queue_free()


func _on_local_upload_item_toggled(enabled: bool, index: int) -> void:
	if enabled:
		_local_upload_selection[index] = true
	else:
		_local_upload_selection.erase(index)
	if _local_upload_upload_button:
		_local_upload_upload_button.disabled = _local_upload_selection.is_empty()


func _on_local_upload_preview_pressed(index: int) -> void:
	if index < 0 or index >= _local_upload_sessions.size():
		return
	var item: Dictionary = _local_upload_sessions[index]
	var mp4_path := str(item.get("mp4_path", "")).strip_edges()
	if _local_upload_status_label:
		_local_upload_status_label.text = tr("UI_UPLOAD_PREVIEW_OPENING")
	call_deferred("_open_video_preview_deferred", mp4_path)


func _open_video_preview_deferred(mp4_path: String) -> void:
	clear_pointer()
	if _open_video_preview(mp4_path):
		return
	if _local_upload_status_label:
		_local_upload_status_label.text = tr("UI_UPLOAD_PREVIEW_FAILED")


func _on_local_upload_confirm_pressed() -> void:
	if _local_file_menu_mode == LOCAL_FILE_MODE_DELETE:
		_delete_selected_local_sessions()
		return
	var selected := []
	for index in _local_upload_selection.keys():
		var i := int(index)
		if i >= 0 and i < _local_upload_sessions.size():
			selected.append(_local_upload_sessions[i])
	if selected.is_empty():
		return
	manual_upload_requested.emit(selected, get_options())
	close()
	if _local_upload_status_label:
		_local_upload_status_label.text = tr("UI_UPLOAD_MANUAL_QUEUED") % selected.size()
	if _local_upload_upload_button:
		_local_upload_upload_button.disabled = true


func _on_local_upload_close_pressed() -> void:
	_show_upload_main_menu()


func _delete_selected_local_sessions() -> void:
	var selected_indices := _local_upload_selection.keys()
	if selected_indices.is_empty():
		return
	var deleted := 0
	var failed := 0
	for index in selected_indices:
		var i := int(index)
		if i < 0 or i >= _local_upload_sessions.size():
			continue
		var item: Dictionary = _local_upload_sessions[i]
		if _delete_local_session(item):
			deleted += 1
		else:
			failed += 1
	_local_upload_selection.clear()
	_refresh_local_upload_list()
	_refresh_storage_usage()
	if _local_upload_status_label:
		if failed > 0:
			_local_upload_status_label.text = tr("UI_STORAGE_DELETE_RESULT_WITH_FAILED") % [deleted, failed]
		else:
			_local_upload_status_label.text = tr("UI_STORAGE_DELETE_RESULT") % deleted


func _delete_local_session(item: Dictionary) -> bool:
	var save_root := _configured_save_root()
	var session_dir := str(item.get("session_dir", "")).strip_edges()
	var mp4_path := str(item.get("mp4_path", "")).strip_edges()
	var ok := true
	if not session_dir.is_empty() and not _path_is_inside(session_dir, save_root):
		return false
	if not mp4_path.is_empty() and not _path_is_inside(mp4_path, save_root):
		return false
	if not session_dir.is_empty() and DirAccess.dir_exists_absolute(session_dir):
		ok = _remove_path_recursive(session_dir) and ok
	if not mp4_path.is_empty() and FileAccess.file_exists(mp4_path):
		if session_dir.is_empty() or not _path_is_inside(mp4_path, session_dir):
			ok = DirAccess.remove_absolute(mp4_path) == OK and ok
	return ok


func _remove_path_recursive(path: String) -> bool:
	if path.is_empty():
		return false
	if FileAccess.file_exists(path):
		return DirAccess.remove_absolute(path) == OK
	if not DirAccess.dir_exists_absolute(path):
		return true
	var dir := DirAccess.open(path)
	if dir == null:
		return false
	var ok := true
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry.is_empty():
			break
		if entry == "." or entry == "..":
			continue
		var child := path.path_join(entry)
		if dir.current_is_dir():
			ok = _remove_path_recursive(child) and ok
		else:
			ok = DirAccess.remove_absolute(child) == OK and ok
	dir.list_dir_end()
	ok = DirAccess.remove_absolute(path) == OK and ok
	return ok


func _path_is_inside(path: String, root: String) -> bool:
	var clean_path := ProjectSettings.globalize_path(path).simplify_path()
	var clean_root := ProjectSettings.globalize_path(root).simplify_path()
	while clean_root.length() > 1 and clean_root.ends_with("/"):
		clean_root = clean_root.substr(0, clean_root.length() - 1)
	return clean_path == clean_root or clean_path.begins_with("%s/" % clean_root)


func _open_video_preview(path: String) -> bool:
	if path.is_empty() or not FileAccess.file_exists(path):
		return false
	var plugin := _resolve_storage_plugin()
	if plugin != null:
		var opened: Variant = plugin.call("openVideoInSystemPlayer", path)
		if bool(opened):
			return true
	if OS.get_name() == "Android":
		return false
	var global_path := ProjectSettings.globalize_path(path)
	var err := OS.shell_open(global_path)
	if err != OK:
		err = OS.shell_open("file://%s" % global_path)
	return err == OK


func scroll_by_pixels(delta_pixels: float) -> bool:
	if _local_upload_view != null and _local_upload_view.visible:
		return _scroll_container_by_pixels(_local_upload_scroll, delta_pixels)
	return super.scroll_by_pixels(delta_pixels)


func _reset_local_upload_scroll() -> void:
	if _local_upload_scroll:
		_local_upload_scroll.scroll_vertical = 0


func _scan_local_upload_sessions() -> Array:
	var root := _configured_save_root()
	var dir := DirAccess.open(root)
	if dir == null:
		return []
	var sessions: Array = []
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry.is_empty():
			break
		if entry == "." or entry == ".." or entry.begins_with("."):
			continue
		if not dir.current_is_dir():
			continue
		var session_dir := root.path_join(entry)
		var manifest_path := session_dir.path_join("manifest.json")
		if not FileAccess.file_exists(manifest_path):
			continue
		var mp4_path := _mp4_path_for_local_session(root, entry, manifest_path)
		if mp4_path.is_empty() or not FileAccess.file_exists(mp4_path):
			continue
		var bytes := _file_size(mp4_path)
		if bytes <= 0:
			continue
		sessions.append({
			"session_id": entry,
			"session_dir": session_dir,
			"mp4_path": mp4_path,
			"bytes": bytes,
			"modified": FileAccess.get_modified_time(mp4_path),
			"label": "%s  %s" % [entry, _format_bytes(bytes)],
		})
	dir.list_dir_end()
	sessions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("modified", 0)) > int(b.get("modified", 0))
	)
	var limit := _local_file_session_limit()
	if limit > 0 and sessions.size() > limit:
		sessions = sessions.slice(0, limit)
	return sessions


func _mp4_path_for_local_session(root: String, session_id: String, manifest_path: String) -> String:
	var manifest := _read_json_object(manifest_path)
	var output_mp4 := str(manifest.get("output_mp4_path", "")).strip_edges()
	if not output_mp4.is_empty() and _path_is_inside(output_mp4, root) and FileAccess.file_exists(output_mp4):
		return output_mp4
	var artifacts_value: Variant = manifest.get("artifacts", {})
	var artifacts: Dictionary = artifacts_value if artifacts_value is Dictionary else {}
	var media_value: Variant = artifacts.get("media", {})
	var media: Dictionary = media_value if media_value is Dictionary else {}
	var filename := str(media.get("filename", "")).strip_edges()
	if not filename.is_empty():
		var candidate := filename if filename.begins_with("/") else root.path_join(filename)
		if _path_is_inside(candidate, root) and FileAccess.file_exists(candidate):
			return candidate
	var fallback := root.path_join("%s.mp4" % session_id)
	return fallback if FileAccess.file_exists(fallback) else ""


func _local_file_session_limit() -> int:
	return MAX_LOCAL_STORAGE_SESSIONS if _local_file_menu_mode == LOCAL_FILE_MODE_DELETE else MAX_LOCAL_UPLOAD_SESSIONS


func _read_json_object(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var size := int(f.get_length())
	f.close()
	return size


func _format_bytes(bytes: int) -> String:
	var value := float(bytes)
	var units := ["B", "KB", "MB", "GB"]
	var unit := 0
	while value >= 1024.0 and unit < units.size() - 1:
		value /= 1024.0
		unit += 1
	if unit == 0:
		return "%d %s" % [int(value), units[unit]]
	return "%.1f %s" % [value, units[unit]]


func _configured_save_root() -> String:
	if _save_root == null:
		return DEFAULT_SAVE_ROOT
	var configured := _save_root.text.strip_edges()
	return DEFAULT_SAVE_ROOT if configured.is_empty() else configured


func _default_value_for_key(key: String) -> Variant:
	return _mode_default_options().get(key)


func _mode_default_options() -> Dictionary:
	var defaults := _default_options()
	if _live_server_mode:
		defaults.erase("show_hand_skeleton_overlay")
	return defaults


static func load_settings() -> Dictionary:
	var out := BaseSettingsPanel.load_settings_from_config(
			SETTINGS_PATH,
			SECTION,
			_default_options(),
			"",
			_settings_secret_key_map()
	)
	var save_root := str(out.get("save_root", DEFAULT_SAVE_ROOT)).strip_edges()
	out["save_root"] = DEFAULT_SAVE_ROOT if save_root.is_empty() else save_root
	return out


static func _settings_secret_key_map() -> Dictionary:
	return {
		"upload_token": "upload_token_b64",
		"server_auth_token": "server_auth_token_b64",
	}


static func _default_options() -> Dictionary:
	# interaction_mode is intentionally absent -- the panel doesn't own that
	# field any more; the router-facing value lives in capture_app.gd's
	# capture_options and is only set by automation args or the "controllers"
	# default.
	return {
		"stereo_rgb": true,
		"record_depth": true,
		"record_head_pose": true,
		# Hand vs. controller capture is mutually exclusive (see
		# INPUT_SOURCE_MUTEX). The runtime defaults to the controllers
		# interaction mode, so we ship with controllers on and hands off;
		# selecting hands in the panel auto-disables controllers and
		# persists that choice.
		"record_controller_pose": true,
		"record_hand_data": false,
		"record_body_tracking": true,
		"record_motion_trackers": true,
		"max_motion_trackers": 2,
		"show_hand_skeleton_overlay": true,
		"record_audio": true,
		"audio_channel_layout": "stereo",
		"audio_sample_rate_hz": 48000,
		"audio_bitrate_bps": 128000,
		"rgb_width": 0,
		"rgb_height": 0,
		"rgb_resolution": "",
		"rgb_fps": DEFAULT_RGB_FPS,
		"rgb_codec": DEFAULT_RGB_CODEC,
		"server_host": DEFAULT_LIVE_SERVER_HOST,
		"server_port": DEFAULT_LIVE_SERVER_PORT,
		"server_result_port": DEFAULT_LIVE_RESULT_PORT,
		"server_auth_token": "",
		"save_controller_hand_sidecar": false,
		"save_body_sidecar": false,
		"save_root": DEFAULT_SAVE_ROOT,
		"upload_url": "",
		"upload_token": "",
		"upload_on_finalize": true,
		"keep_local_after_upload": true
	}


func _configured_server_host() -> String:
	if _server_host == null:
		return DEFAULT_LIVE_SERVER_HOST
	var configured := _server_host.text.strip_edges()
	return DEFAULT_LIVE_SERVER_HOST if configured.is_empty() else configured


func _configured_server_port() -> int:
	if _server_port == null:
		return DEFAULT_LIVE_SERVER_PORT
	return clampi(int(_server_port.value), 1, 65535)


func _configured_result_port() -> int:
	if _result_port == null:
		return DEFAULT_LIVE_RESULT_PORT
	return clampi(int(_result_port.value), 1, 65535)


# --- QR scan integration ---------------------------------------------------
# The actual Camera2 + ZXing scanning lives in the qr_scanner Android plugin
# (xr/android_plugin/qrscanner/). This panel only fires the signal and
# accepts the resulting payload back. capture_app.gd brokers the overlay
# lifecycle. (_on_save_pressed / _on_exit_button_pressed are inherited
# from BaseSettingsPanel — don't redeclare them.)

func _qr_scan_supported() -> bool:
	# Show the button on Android only — the plugin is Android-only by
	# design. In the editor / macOS dev builds we hide the button so we
	# don't promise something we can't deliver. Flip
	# `ProjectSettings: ego/qr_scan/force_show` to true to stub-fake it
	# during desktop UI work.
	if ProjectSettings.has_setting("ego/qr_scan/force_show"):
		if bool(ProjectSettings.get_setting("ego/qr_scan/force_show")):
			return true
	return OS.get_name() == "Android"


func _on_scan_button_pressed() -> void:
	print("[QR] upload-url scan button pressed")
	scan_upload_url_requested.emit()


func _on_scan_live_server_button_pressed() -> void:
	print("[QR] live-server scan button pressed")
	scan_live_server_requested.emit()


func _on_connect_live_server_button_pressed() -> void:
	print("[LiveServer] connect button pressed")
	set_live_server_connectivity_status(
		tr("UI_LIVE_SERVER_CONNECTING") % [_configured_server_host(), _configured_result_port()],
		"normal"
	)
	connect_live_server_requested.emit(get_options())


func _on_health_check_button_pressed() -> void:
	# Operator pressed the pulse icon — run the reachability probe now.
	# Always re-runs (cancels in-flight requests in _trigger_upload_health_check)
	# so a second tap retries instead of being dropped.
	print("[UploadHealth] manual check requested")
	_trigger_upload_health_check()


# Build a square icon-only button that sits to the right of the upload-URL
# LineEdit. Both the health-check and the QR scan buttons use the same
# geometry so the row stays tidy regardless of which buttons are present.
#
# Note on icon rendering: _apply_button_icon() in the base class is tuned
# for text+icon buttons (confirm/exit). For icon-only buttons we override
# the size constants — expand_icon with empty text can collapse the icon
# to zero in some Godot 4 builds. Setting an explicit icon_max_width and
# disabling expand_icon makes the result deterministic.
func _add_url_action_button(
		row: HBoxContainer,
		icon_name: String,
		tooltip: String,
		handler: Callable
) -> Button:
	var btn := Button.new()
	btn.tooltip_text = tooltip
	btn.custom_minimum_size = Vector2(70, 55)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	var icon := _load_icon(icon_name)
	if icon == null:
		push_warning("[ViewLockedCapturePanel] icon '%s' failed to load — button will be blank" % icon_name)
	btn.icon = icon
	btn.expand_icon = false
	btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	btn.add_theme_constant_override("icon_max_width", 36)
	btn.pressed.connect(handler)
	var slot := add_interactive(row, btn)
	slot.size_flags_horizontal = Control.SIZE_SHRINK_END
	slot.custom_minimum_size = Vector2(78, 55)
	return btn


func _add_live_connect_button(row: HBoxContainer) -> Button:
	var btn := Button.new()
	btn.text = tr("UI_CONNECT")
	btn.tooltip_text = tr("UI_LIVE_SERVER_CONNECT_TOOLTIP")
	btn.custom_minimum_size = Vector2(112, 55)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	btn.add_theme_font_size_override("font_size", 18)
	btn.pressed.connect(_on_connect_live_server_button_pressed)
	var slot := add_interactive(row, btn)
	slot.size_flags_horizontal = Control.SIZE_SHRINK_END
	slot.custom_minimum_size = Vector2(120, 55)
	return btn


## Called by capture_app.gd once the QR scanner overlay returns a payload.
## We DO NOT close the panel here — the user still needs to review + Save.
## However we DO persist the URL/token to disk immediately, so a successful
## scan survives an app restart even if the user never taps Save (this used
## to be the source of confusion: scan succeeded but the config still showed
## the old URL the next time the panel opened). See `claw/issues/...`.
func set_upload_url_from_scan(url: String, token: String = "", enable_auto_upload: bool = false, mark_ready: bool = true) -> void:
	if _upload_url == null:
		return
	var trimmed := url.strip_edges()
	if trimmed.is_empty():
		return
	_upload_url.text = trimmed
	_upload_token = token
	if mark_ready:
		_mark_upload_url_ready(trimmed)
	else:
		_clear_upload_url_ready()
	if enable_auto_upload and _stream_toggles.has("upload_on_finalize"):
		(_stream_toggles["upload_on_finalize"] as CheckButton).button_pressed = true
	# Persist immediately so the scanned endpoint is part of the saved config
	# without requiring an explicit Save tap. The full options snapshot is
	# written so we don't drop unrelated edits that were in-flight on the
	# panel; that mirrors what `_on_confirm_requested` would have done.
	_save_settings(get_options())


## Called by capture_app.gd when the same QR overlay is used from live feed.
## Accepted payloads:
##   host
##   host:port
##   http://host:port?result_port=63912&token=...
##   {"server_host":"host","server_port":63910,"server_result_port":63912}
func set_live_server_host_from_scan(payload: String) -> void:
	var parsed := _parse_live_server_payload(payload)
	var host := str(parsed.get("host", "")).strip_edges()
	if host.is_empty():
		return
	if _server_host != null:
		_server_host.text = host
	if parsed.has("port") and _server_port != null:
		_server_port.value = clampi(int(parsed["port"]), 1, 65535)
	if parsed.has("result_port") and _result_port != null:
		_result_port.value = clampi(int(parsed["result_port"]), 1, 65535)
	if parsed.has("token") and _server_token != null:
		_server_token.text = str(parsed["token"])


func _parse_live_server_payload(payload: String) -> Dictionary:
	var trimmed := payload.strip_edges()
	if trimmed.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(trimmed)
	if typeof(parsed) == TYPE_DICTIONARY:
		return _parse_live_server_dictionary(parsed as Dictionary)
	return _parse_live_server_address(trimmed)


func _parse_live_server_dictionary(data: Dictionary) -> Dictionary:
	var endpoint := str(_first_present(data, ["server_url", "url", "endpoint"])).strip_edges()
	var out := _parse_live_server_address(endpoint) if not endpoint.is_empty() else {}
	var host := str(_first_present(data, ["server_host", "host", "hostname", "address"])).strip_edges()
	if not host.is_empty():
		out["host"] = host
	var server_port := _parse_port_value(_first_present(data, ["server_port", "port", "control_port"]))
	if server_port > 0:
		out["port"] = server_port
	var result_port := _parse_port_value(_first_present(data, ["server_result_port", "result_port", "pull_port"]))
	if result_port > 0:
		out["result_port"] = result_port
	var token := str(_first_present(data, ["server_auth_token", "auth_token", "token"])).strip_edges()
	if not token.is_empty():
		out["token"] = token
	return _complete_live_server_ports(out)


func _parse_live_server_address(raw: String) -> Dictionary:
	var address := raw.strip_edges()
	if address.is_empty():
		return {}
	var query_params := {}
	var query_idx := address.find("?")
	if query_idx >= 0:
		query_params = _parse_query_params(address.substr(query_idx + 1))
		address = address.substr(0, query_idx)
	var scheme_idx := address.find("://")
	if scheme_idx >= 0:
		address = address.substr(scheme_idx + 3)
	var slash_idx := address.find("/")
	if slash_idx >= 0:
		address = address.substr(0, slash_idx)
	var at_idx := address.rfind("@")
	if at_idx >= 0:
		address = address.substr(at_idx + 1)
	address = address.strip_edges()
	if address.is_empty():
		return {}

	var host := address
	var port := 0
	if address.begins_with("["):
		var close_idx := address.find("]")
		if close_idx > 0:
			host = address.substr(1, close_idx - 1)
			var remainder := address.substr(close_idx + 1)
			if remainder.begins_with(":"):
				port = _parse_port_value(remainder.substr(1))
	else:
		var first_colon_idx := address.find(":")
		var last_colon_idx := address.rfind(":")
		if first_colon_idx > 0 and first_colon_idx == last_colon_idx:
			host = address.substr(0, first_colon_idx)
			port = _parse_port_value(address.substr(first_colon_idx + 1))

	var out := {"host": host.strip_edges()}
	var query_server_port := _parse_port_value(_first_present(query_params, ["server_port", "port", "control_port"]))
	if query_server_port > 0:
		out["port"] = query_server_port
	elif port > 0:
		out["port"] = port
	var query_result_port := _parse_port_value(_first_present(query_params, ["server_result_port", "result_port", "pull_port"]))
	if query_result_port > 0:
		out["result_port"] = query_result_port
	var query_token := str(_first_present(query_params, ["server_auth_token", "auth_token", "token"])).strip_edges()
	if not query_token.is_empty():
		out["token"] = query_token
	return _complete_live_server_ports(out)


func _complete_live_server_ports(config: Dictionary) -> Dictionary:
	if not config.has("port"):
		return config
	if config.has("result_port"):
		return config
	if _result_port == null:
		return config
	var current_server := DEFAULT_LIVE_SERVER_PORT if _server_port == null else int(_server_port.value)
	var current_result := int(_result_port.value)
	if current_result != DEFAULT_LIVE_RESULT_PORT and current_result != current_server + 2:
		return config
	var next_result := int(config["port"]) + 2
	if next_result <= 65535:
		config["result_port"] = next_result
	return config


func _parse_query_params(query: String) -> Dictionary:
	var out := {}
	for part in query.split("&", false):
		var idx := part.find("=")
		var key := part if idx < 0 else part.substr(0, idx)
		var value := "" if idx < 0 else part.substr(idx + 1)
		key = key.strip_edges().to_lower()
		if not key.is_empty():
			out[key] = value.strip_edges()
	return out


func _first_present(data: Dictionary, keys: Array) -> Variant:
	for key in keys:
		if data.has(key):
			return data[key]
	return ""


func _parse_port_value(value: Variant) -> int:
	if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
		var numeric_port := int(value)
		return mini(numeric_port, 65535) if numeric_port > 0 else 0
	var text := str(value).strip_edges()
	if text.is_valid_int():
		var text_port := int(text)
		return mini(text_port, 65535) if text_port > 0 else 0
	return 0


func set_upload_connectivity_status(text: String, level: String = "normal") -> void:
	if _upload_status_label == null:
		return
	_upload_status_label.text = text
	_upload_status_label.visible = not text.strip_edges().is_empty()
	var color := COL_STATUS
	if level == "error":
		color = Color(1.0, 0.36, 0.28)
	elif level == "success":
		color = Color(0.36, 0.96, 0.58)
	elif level == "warning":
		# Amber — server responded but probe wasn't conclusive (e.g. 401/404
		# on OPTIONS, or missing Tus-Resumable header). The endpoint is up,
		# but we can't promise the actual upload will succeed.
		color = Color(1.0, 0.78, 0.40)
	_upload_status_label.add_theme_color_override("font_color", color)


func set_live_server_connectivity_status(text: String, level: String = "normal") -> void:
	# Mirror connection state so _on_confirm_requested can gate Save without
	# polling capture_app. capture_app drives this with "success" on connect,
	# "warning" on disconnect, "error" on failure — only "success" unblocks.
	_live_server_connected = (level == "success")
	if _live_server_connected:
		_hide_live_server_required_callout()
	if _live_server_status_label == null:
		return
	_live_server_status_label.text = text
	_live_server_status_label.visible = not text.strip_edges().is_empty()
	var color := COL_STATUS
	if level == "error":
		color = Color(1.0, 0.36, 0.28)
	elif level == "success":
		color = Color(0.36, 0.96, 0.58)
	elif level == "warning":
		color = Color(1.0, 0.78, 0.40)
	_live_server_status_label.add_theme_color_override("font_color", color)


# --- Live-server save gating ----------------------------------------------
# Returns the localized reason the Save button should be blocked in
# live-feed mode, or "" if everything is good.

func _live_server_save_blocker() -> String:
	if _server_host == null:
		return ""
	if _server_host.text.strip_edges().is_empty():
		return tr("UI_LIVE_SERVER_HOST_REQUIRED")
	if not _live_server_connected:
		return tr("UI_LIVE_SERVER_CONNECT_REQUIRED")
	return ""


# Construct the inline "popup" callout that surfaces under the server-host
# row. We build it once in _build_live_server_group and toggle visibility
# from _show_live_server_required_callout / _hide_live_server_required_callout.
# Using an inline PanelContainer (instead of a real PopupPanel) keeps the
# rendering inside the SubViewport that OpenXR composition layers consume
# — native popups risk landing outside the layer.
func _build_live_server_required_callout(parent: Container) -> void:
	_live_server_required_callout = PanelContainer.new()
	_live_server_required_callout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_live_server_required_callout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	# Translucent dark-red background so the callout reads as a warning
	# without overpowering the rest of the form. White text on this is
	# WCAG-AA contrast.
	style.bg_color = Color(0.62, 0.13, 0.16, 0.96)
	style.border_color = Color(1.0, 0.36, 0.28)
	style.border_width_left = 4
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	_live_server_required_callout.add_theme_stylebox_override("panel", style)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_live_server_required_callout.add_child(row)
	# ⚠ as a leading glyph keeps the i18n surface small — no icon resource
	# to ship per locale, and the meaning translates across cultures.
	var icon_label := Label.new()
	icon_label.text = "⚠"
	icon_label.add_theme_font_size_override("font_size", 26)
	icon_label.add_theme_color_override("font_color", Color(1.0, 0.90, 0.45))
	row.add_child(icon_label)
	_live_server_required_label = Label.new()
	_live_server_required_label.text = ""
	_live_server_required_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_live_server_required_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_live_server_required_label.add_theme_font_size_override("font_size", 19)
	_live_server_required_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	row.add_child(_live_server_required_label)
	_live_server_required_callout.visible = false
	_live_server_required_callout.modulate.a = 0.0
	parent.add_child(_live_server_required_callout)
	# Auto-dismiss timer so a stale callout doesn't keep obscuring layout if
	# the user wanders off to another group without fixing the issue.
	_live_server_required_timer = Timer.new()
	_live_server_required_timer.one_shot = true
	_live_server_required_timer.wait_time = LIVE_SERVER_REQUIRED_VISIBLE_S
	_live_server_required_timer.timeout.connect(_hide_live_server_required_callout)
	_live_server_required_callout.add_child(_live_server_required_timer)


func _show_live_server_required_callout(message: String) -> void:
	if _live_server_required_callout == null or _live_server_required_label == null:
		return
	_live_server_required_label.text = message
	_live_server_required_callout.visible = true
	# Fade in for visibility — also re-tween on repeat taps so the user
	# perceives "the warning fired again" rather than a static frozen panel.
	var tween := create_tween()
	tween.tween_property(_live_server_required_callout, "modulate:a", 1.0, 0.20)
	if _live_server_required_timer != null:
		_live_server_required_timer.stop()
		_live_server_required_timer.start()


func _hide_live_server_required_callout() -> void:
	if _live_server_required_callout == null or not _live_server_required_callout.visible:
		return
	if _live_server_required_timer != null:
		_live_server_required_timer.stop()
	var tween := create_tween()
	tween.tween_property(_live_server_required_callout, "modulate:a", 0.0, 0.15)
	tween.tween_callback(func() -> void:
		if _live_server_required_callout != null:
			_live_server_required_callout.visible = false
	)


func _on_server_host_text_changed(_new_text: String) -> void:
	# Any edit invalidates a prior successful connection (the connection was
	# bound to the previous host string); the user must reconnect before
	# saving. Also dismiss any stale "must connect" callout so it doesn't
	# linger over the field they are actively editing.
	_live_server_connected = false
	_hide_live_server_required_callout()


# --- Upload URL reachability probe -----------------------------------------
# Triggered every time the panel opens. The user asked for "if the upload
# URL is non-empty, every time you open settings, check whether it's healthy
# and show the status — don't show nothing." So:
#   - empty URL  → hide the label (no row at all; nothing to check)
#   - bad URL    → red, "invalid URL"
#   - probe      → an OPTIONS request to the configured endpoint
#       - 2xx/3xx + Tus-Resumable header → green, TUS endpoint ready
#       - 2xx/3xx without Tus-Resumable  → green, generic reachable
#       - 4xx                            → amber (reachable but probe rejected)
#       - 5xx / network error / timeout  → red

func _trigger_upload_health_check() -> void:
	if _upload_status_label == null:
		return
	var url := ""
	if _upload_url != null:
		url = _upload_url.text.strip_edges()
	if url.is_empty():
		_clear_upload_url_ready()
		# Nothing configured — collapse the status row entirely so we don't
		# show stale "OK" text from a previous URL the user just cleared.
		_upload_status_label.text = ""
		_upload_status_label.visible = false
		return
	if not (url.begins_with("http://") or url.begins_with("https://")):
		_clear_upload_url_ready()
		_enforce_auto_upload_ready(false)
		set_upload_connectivity_status(tr("UI_UPLOAD_HEALTH_INVALID_URL"), "error")
		return
	if _upload_health_request == null:
		# Panel was constructed without the helper somehow — at least surface
		# that a check would have happened so the row isn't blank.
		set_upload_connectivity_status(tr("UI_UPLOAD_HEALTH_UNAVAILABLE"), "warning")
		return
	# Cancel any in-flight probe before issuing the new one so back-to-back
	# open() calls don't deliver stale callbacks.
	if _upload_health_request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_upload_health_request.cancel_request()
	_clear_upload_url_ready()
	_upload_health_pending_url = url
	set_upload_connectivity_status(tr("UI_UPLOAD_HEALTH_CHECKING"), "normal")
	# Tus-Resumable in the *request* is recommended by the TUS spec for
	# OPTIONS probes. Many ingest servers also accept a plain OPTIONS.
	var headers := PackedStringArray([
		"User-Agent: ego-uploader/1.0 (godot)",
		"Tus-Resumable: 1.0.0",
	])
	if not _upload_token.is_empty():
		headers.append("Authorization: Bearer %s" % _upload_token)
	var err := _upload_health_request.request(url, headers, HTTPClient.METHOD_OPTIONS)
	if err != OK:
		_upload_health_pending_url = ""
		set_upload_connectivity_status(tr("UI_UPLOAD_HEALTH_REQUEST_FAILED") % err, "error")


func _on_upload_health_completed(result: int, response_code: int, headers: PackedStringArray, _body: PackedByteArray) -> void:
	var checked_url := _upload_health_pending_url
	_upload_health_pending_url = ""
	var current_url := _upload_url.text.strip_edges() if _upload_url != null else ""
	if checked_url.is_empty() or current_url != checked_url:
		return
	if result != HTTPRequest.RESULT_SUCCESS:
		_clear_upload_url_ready()
		_enforce_auto_upload_ready(false)
		set_upload_connectivity_status(tr("UI_UPLOAD_HEALTH_NETWORK_ERROR") % result, "error")
		return
	# Look for Tus-Resumable / Tus-Version response headers (case-insensitive).
	# Their presence is a strong signal that the URL is actually a TUS ingest
	# endpoint, not just some web server that happens to be reachable.
	var tus_version := ""
	for h in headers:
		var idx := h.find(":")
		if idx < 0:
			continue
		var name := h.substr(0, idx).strip_edges().to_lower()
		if name == "tus-version":
			tus_version = h.substr(idx + 1).strip_edges()
			break
		if name == "tus-resumable" and tus_version.is_empty():
			tus_version = h.substr(idx + 1).strip_edges()
	if not tus_version.is_empty():
		_mark_upload_url_ready(checked_url)
		set_upload_connectivity_status(tr("UI_UPLOAD_HEALTH_TUS_OK") % tus_version, "success")
		return
	if response_code >= 200 and response_code < 400:
		_mark_upload_url_ready(checked_url)
		set_upload_connectivity_status(tr("UI_UPLOAD_HEALTH_OK") % response_code, "success")
	elif response_code >= 400 and response_code < 500:
		# Reachable but rejected the probe. Plenty of perfectly fine ingest
		# servers return 401/404 to OPTIONS — flag as warning, not error.
		_clear_upload_url_ready()
		_enforce_auto_upload_ready(false)
		set_upload_connectivity_status(tr("UI_UPLOAD_HEALTH_HTTP_WARN") % response_code, "warning")
	else:
		_clear_upload_url_ready()
		_enforce_auto_upload_ready(false)
		set_upload_connectivity_status(tr("UI_UPLOAD_HEALTH_HTTP_ERROR") % response_code, "error")


func _on_save_root_changed(_new_text: String) -> void:
	# Re-query immediately when the operator edits the path so the figure
	# tracks the volume they actually picked.
	_storage_refresh_accum = STORAGE_REFRESH_SECONDS
	_refresh_storage_usage()


func _refresh_storage_usage() -> void:
	var text := _query_storage_text()
	if _storage_label and _storage_label.text != text:
		_storage_label.text = text
		print("QcStorage %s" % text)


func _resolve_storage_plugin() -> Object:
	if _storage_plugin_checked:
		return _storage_plugin
	_storage_plugin_checked = true
	_storage_plugin = CaptureProviderRegistryScript.bind()
	return _storage_plugin


func _query_storage_text() -> String:
	var plugin := _resolve_storage_plugin()
	if plugin == null:
		return tr("UI_STORAGE_UNAVAILABLE_PLATFORM")
	var raw: Variant = plugin.call("getStorageUsageJson", _configured_save_root())
	if typeof(raw) != TYPE_STRING or String(raw).is_empty():
		return tr("UI_STORAGE_UNAVAILABLE")
	var parsed: Variant = JSON.parse_string(String(raw))
	if typeof(parsed) != TYPE_DICTIONARY:
		return tr("UI_STORAGE_UNAVAILABLE")
	if parsed.has("error"):
		return tr("UI_STORAGE_ERROR") % str(parsed["error"])
	var total_b := float(parsed.get("total_bytes", 0.0))
	var free_b := float(parsed.get("available_bytes", parsed.get("free_bytes", 0.0)))
	var capture_b := float(parsed.get("capture_dir_bytes", 0.0))
	if total_b <= 0.0:
		return tr("UI_STORAGE_UNAVAILABLE")
	var used_pct := int(round((total_b - free_b) / total_b * 100.0))
	return tr("UI_FREE_STORAGE") % [
		_human_bytes(free_b),
		_human_bytes(total_b),
		used_pct,
		_human_bytes(capture_b)
	]


func _human_bytes(amount: float) -> String:
	var gb := 1024.0 * 1024.0 * 1024.0
	var mb := 1024.0 * 1024.0
	var kb := 1024.0
	if amount >= gb:
		return "%.1f GB" % (amount / gb)
	if amount >= mb:
		return "%.0f MB" % (amount / mb)
	if amount >= kb:
		return "%.0f KB" % (amount / kb)
	return "%d B" % int(amount)
