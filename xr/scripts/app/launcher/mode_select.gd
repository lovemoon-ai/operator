extends Node3D

## Launcher / mode-select scene. Renders the operator mode cards enabled
## for this build as individual Viewport2DIn3D quads floating in front of
## the user. Each card is a distinct 3D entity that can be hovered and
## clicked with the XR ray pointer.
##
## Which cards appear is decided entirely by the `operator_feature_mode_*`
## flags (see FeatureSet); the Exit card is one of them and quits the app
## instead of opening a scene.

const LIVE_FEED_SCENE := "res://scenes/live_feed_app.tscn"
const VR_SCENE := "res://scenes/vr_mode.tscn"
const TELEOP_SCENE := "res://scenes/teleop_main.tscn"
const EGO_CAPTURE_SCENE := "res://scenes/capture_app.tscn"
const MUJOCO_SCENE := "res://scenes/mujoco/mujoco_device_test.tscn"
const TEST_RUNNER_SCENE := "res://scenes/test_runner.tscn"
const MODE_TELEOP := "teleop"
const MODE_EGO_CAPTURE := "ego_capture"
const MODE_LIVE_FEED := "live_feed"
const MODE_VR := "vr"
const MODE_MUJOCO := "mujoco"
const MODE_EXIT := "exit"
const MODE_PANEL_FALLBACK_DELAY_SEC := 2.0
const HEAD_TRACKING_WAIT_FRAMES := 30
const FALLBACK_EYE_HEIGHT := 1.5

const ViewportTemplate := preload("res://scenes/ui/viewport_2d_in_3d_clean.tscn")
const CardSceneTemplate := preload("res://scenes/ui/mode_select_ui.tscn")
const CardUIScript := preload("res://scripts/ui/mode_select_ui.gd")
const QuickEntryConfigScript := preload("res://scripts/app/launcher/quick_entry_config.gd")

const CARD_VIEWPORT_SIZE := Vector2(420, 540)
const CARD_SCREEN_SIZE := Vector2(0.30, 0.38)
# Cards live on a cylinder centred on the user's head. CARD_RADIUS_M is the
# horizontal (XZ) distance from the head to each card surface. With a fixed
# radius every card is exactly the same distance away — earlier we pinned
# every card at z = -0.95 with different x, which left the center card
# noticeably closer than the corner cards ("第二块卡片明显更靠近").
const CARD_RADIUS_M := 0.95
const TOP_ROW_Y := 0.21
const BOTTOM_ROW_Y := -0.21
# Yaw angles around the user (degrees). Top row spans wider because it has
# three slots; bottom row is two slots tighter to the centre. Tweak these
# to widen / narrow the menu; CARD_RADIUS_M is independent of the angles.
const TOP_ROW_ANGLES_DEG := [-19.5, 0.0, 19.5]
const BOTTOM_ROW_ANGLES_DEG := [-10.0, 10.0]

@onready var _start_xr: XRToolsStartXR = get_node_or_null("StartXR")
@onready var _camera: XRCamera3D = $XROrigin3D/XRCamera3D
@onready var _origin: XROrigin3D = $XROrigin3D

class CardEntry:
	var mode: String
	var quad: Node3D
	var ui: Control
	var status_pending: String = ""
	# Offset from the launch-time camera anchor (yaw + position). Multiplied
	# by the snapshotted anchor in _anchor_cards_to_camera() to compute the
	# final world-locked transform under XROrigin3D.
	var local_offset: Transform3D = Transform3D.IDENTITY

# Plain Array (not Array[CardEntry]): GDScript typed arrays don't accept
# inner classes as the element type in stable Godot 4.x. The contents are
# always CardEntry instances; callers can use `as CardEntry` if a Variant
# cast is needed.
var _cards: Array = []
var _xr_started := false
var _changing_scene := false
# Typed runtime feature lookup (operator_feature_* tags in exported APKs,
# registry defaults in editor/dev runs).
var _features: FeatureSet = FeatureSet.from_export_tags()


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	# Test harness entry (WP7): only when the APK was exported with the
	# operator_feature_test_harness feature AND an explicit test suite was
	# requested via intent extras. A test-enabled APK with no test request
	# boots the normal launcher.
	if _features.enabled(OperatorFeature.TEST_HARNESS):
		var test_suite := _requested_test_suite()
		if not test_suite.is_empty():
			print("[Operator] Test harness requested: suite=%s" % test_suite)
			_change_scene(TEST_RUNNER_SCENE)
			return

	var automation_request := _get_automation_mode_request()
	var automation_requested := bool(automation_request["requested"])
	var automation_mode := String(automation_request["mode"])
	# The quick entry is only read when nothing was requested explicitly, so an
	# automation run never burns the process's one quick-entry visit.
	var quick_entry_mode := ""
	if not automation_requested:
		quick_entry_mode = QuickEntryConfigScript.consume_for_process(
			get_tree().root, QuickEntryConfigScript.from_export_tags())
	var startup_mode := resolve_startup_route(
		automation_mode, quick_entry_mode, _features, automation_requested)
	if not startup_mode.is_empty() and _open_mode(startup_mode):
		if startup_mode == automation_mode:
			print("[Operator] Automation mode selected: %s" % startup_mode)
		else:
			print("[Operator] Export quick entry selected: %s" % startup_mode)
		return
	if automation_requested and startup_mode.is_empty():
		var requested_mode := String(automation_request["raw_mode"])
		if requested_mode.is_empty():
			requested_mode = "<empty>"
		push_error(
			"[Operator] Requested mode '%s' is not available in this build — "
			% requested_mode + "showing the launcher"
		)

	_configure_passthrough()
	_spawn_cards()

	if _start_xr:
		_start_xr.xr_started.connect(_on_xr_started)
		if _start_xr.has_signal("xr_failed_to_initialize"):
			_start_xr.xr_failed_to_initialize.connect(_on_xr_failed)
		# XRToolsStartXR keeps its active state in a static flag. On a scene
		# transition the replacement StartXR node does not receive another
		# focused-state signal, so waiting only for xr_started always falls into
		# the 2-second fallback. Finish launcher setup immediately when the
		# existing OpenXR session is already active.
		if XRToolsStartXR.is_xr_active():
			call_deferred("_on_xr_started")
	else:
		call_deferred("_on_xr_started")

	_arm_startup_fallback()
	print("[Operator] Mode select initialized (%d cards spawned)" % _cards.size())


func _spawn_cards() -> void:
	var card_data := _configured_card_data()
	var positions := _compute_card_positions(card_data.size())
	for i in range(card_data.size()):
		var entry := card_data[i] as Dictionary
		var card := _create_card(entry, positions[i])
		_cards.append(card)


func _configured_card_data() -> Array:
	var enabled_modes := _configured_launcher_card_modes()
	var card_data: Array = []
	for entry in _all_card_data():
		var mode := String(entry["mode"])
		if enabled_modes.has(mode):
			card_data.append(entry)
	return card_data


func _configured_launcher_card_modes() -> Array:
	var modes: Array = []
	for mode in _all_launcher_card_modes():
		if _launcher_card_feature_enabled(String(mode)):
			modes.append(mode)
	return modes


func _all_launcher_card_modes() -> Array:
	return [MODE_TELEOP, MODE_EGO_CAPTURE, MODE_LIVE_FEED, MODE_VR, MODE_EXIT]


## Every card, Exit included, is gated by its `operator_feature_mode_*`
## flag. In editor/dev runs FeatureSet falls back to registry defaults
## (ego_capture and exit are on), so the launcher is never empty.
func _launcher_card_feature_enabled(mode: String) -> bool:
	return _mode_feature_enabled(mode, _features)


static func _mode_feature_enabled(mode: String, features: FeatureSet) -> bool:
	match mode:
		MODE_TELEOP:
			return features.enabled(OperatorFeature.MODE_TELEOP)
		MODE_EGO_CAPTURE:
			return features.enabled(OperatorFeature.MODE_EGO_CAPTURE)
		MODE_LIVE_FEED:
			return features.enabled(OperatorFeature.MODE_LIVE_FEED)
		MODE_VR:
			return features.enabled(OperatorFeature.MODE_VR)
		MODE_EXIT:
			return features.enabled(OperatorFeature.MODE_EXIT)
		_:
			return false


func _all_card_data() -> Array:
	return [
		{
			"mode": MODE_TELEOP,
			"title_key": "UI_TELEOP_MODE",
			"kind": CardUIScript.Kind.TELEOP,
		},
		{
			"mode": MODE_EGO_CAPTURE,
			"title_key": "UI_EGO_MODE",
			"kind": CardUIScript.Kind.EGO_CAPTURE,
		},
		{
			"mode": MODE_LIVE_FEED,
			"title_key": "UI_LIVE_FEED_MODE",
			"kind": CardUIScript.Kind.LIVE_FEED,
		},
		{
			"mode": MODE_VR,
			"title_key": "UI_VR_MODE",
			"kind": CardUIScript.Kind.VR,
		},
		{
			"mode": MODE_EXIT,
			"title_key": "UI_EXIT_MODE",
			"kind": CardUIScript.Kind.EXIT,
		},
	]


# Returns layout positions on the launcher cylinder. Each slot maps an
# angle to (R sin θ, y, -R cos θ) — keeping every card at the same XZ
# distance R from the user's vertical axis. The previous "all cards at
# z=-0.95" approach left the centre card visibly closer than the corners
# because their straight-line distance grew with the X offset.
func _compute_card_positions(card_count: int) -> Array:
	# Restored after the merge resolution dropped the array init: the
	# match block populates ``positions`` then every branch returns it.
	var positions: Array = []
	match card_count:
		0:
			return positions
		1:
			positions.append(_card_position(0.0, 0.0))
		2:
			for angle_deg in BOTTOM_ROW_ANGLES_DEG:
				positions.append(_card_position(float(angle_deg), 0.0))
		3:
			for angle_deg in TOP_ROW_ANGLES_DEG:
				positions.append(_card_position(float(angle_deg), 0.0))
		4:
			for angle_deg in BOTTOM_ROW_ANGLES_DEG:
				positions.append(_card_position(float(angle_deg), TOP_ROW_Y))
			for angle_deg in BOTTOM_ROW_ANGLES_DEG:
				positions.append(_card_position(float(angle_deg), BOTTOM_ROW_Y))
		_:
			# 5+ cards: 3 on the top row, the rest on the bottom.
			# Two bottom cards use the tighter pair; three use the same
			# three-slot spread as the top row.
			for angle_deg in TOP_ROW_ANGLES_DEG:
				positions.append(_card_position(float(angle_deg), TOP_ROW_Y))
			var bottom_angles: Array = BOTTOM_ROW_ANGLES_DEG if (card_count - 3) <= 2 else TOP_ROW_ANGLES_DEG
			var bottom_count: int = mini(card_count - 3, bottom_angles.size())
			for i in range(bottom_count):
				positions.append(_card_position(float(bottom_angles[i]), BOTTOM_ROW_Y))
	return positions


func _card_position(angle_deg: float, y: float) -> Vector3:
	var angle_rad := deg_to_rad(angle_deg)
	return Vector3(
		CARD_RADIUS_M * sin(angle_rad),
		y,
		-CARD_RADIUS_M * cos(angle_rad),
	)


func _create_card(entry: Dictionary, local_pos: Vector3) -> CardEntry:
	var card := CardEntry.new()
	card.mode = String(entry["mode"])

	var quad: Node3D = ViewportTemplate.instantiate()
	quad.name = "Card_%s" % card.mode
	# `scene`, `viewport_size`, `screen_size` are properties on the
	# godot-xr-tools Viewport2Din3D script. We set them before adding to
	# the tree so its _ready instantiates the right child scene.
	quad.set("scene", CardSceneTemplate)
	quad.set("viewport_size", CARD_VIEWPORT_SIZE)
	quad.set("screen_size", CARD_SCREEN_SIZE)
	quad.visible = false
	# World-locked: parent to XROrigin3D, NOT the XRCamera3D. The cards
	# stay anchored at the user's launch pose and don't follow head motion.
	# _anchor_cards_to_camera() (called once XR reports a tracked head pose)
	# applies the snapshotted camera yaw + position so the layout appears
	# centred in front of wherever the operator was standing at launch.
	_origin.add_child(quad)

	var basis := Basis.IDENTITY
	# Yaw each off-axis card inward so its front (+Z, where the Viewport2DIn3D
	# screen lives) points back at the anchor origin where the operator's head
	# is. For a card at +x the inward direction is -x, hence the negated
	# numerator in the atan2 — using +local_pos.x here would tilt the cards
	# the wrong way (outward arc, "围绕着外侧").
	if absf(local_pos.x) > 0.01:
		var yaw := atan2(-local_pos.x, -local_pos.z)
		basis = Basis(Vector3.UP, yaw)
	card.quad = quad
	card.local_offset = Transform3D(basis, local_pos)
	# Park the card at the launch fallback pose for the brief window before
	# the camera-anchored transform lands. We center it ~1.5 m above origin
	# (typical eye height) so an early peek before _anchor_cards_to_camera
	# isn't at the user's feet.
	quad.transform = Transform3D(basis, local_pos + Vector3(0.0, 1.5, 0.0))
	return card


func _on_xr_started() -> void:
	if _xr_started:
		return
	_xr_started = true
	_configure_passthrough()
	# A replacement scene can enter while the OpenXR session is already active.
	# Quest usually updates the new XRCamera3D immediately; PICO can take a few
	# frames. Wait for the actual head XRPose instead of inferring validity from
	# camera height (PICO LOCAL space may legitimately report y < 0.5 m).
	for _frame in range(HEAD_TRACKING_WAIT_FRAMES):
		await get_tree().process_frame
		if _head_pose_is_tracked():
			break
	_anchor_cards_to_camera()
	for entry in _cards:
		entry.quad.visible = true

	for entry in _cards:
		await _wire_card_ui(entry)
	print("[Operator] Mode select ready (%d cards visible)" % _cards.size())


func _on_xr_failed() -> void:
	_anchor_cards_to_camera()
	for entry in _cards:
		entry.quad.visible = true
		await _wire_card_ui(entry)
	_set_status_for_all(tr("UI_OPENXR_FAILED"))


func _arm_startup_fallback() -> void:
	await get_tree().create_timer(MODE_PANEL_FALLBACK_DELAY_SEC).timeout
	if _xr_started or _changing_scene:
		return
	_anchor_cards_to_camera()
	for entry in _cards:
		entry.quad.visible = true
		await _wire_card_ui(entry)
	print("[Operator] Mode select fallback ready (%d cards visible)" % _cards.size())


# Snapshot the camera's current pose and re-place every card relative to
# that anchor. After this call the cards are world-locked — they stay
# put while the user moves / turns. We strip pitch and roll so the card
# layout always stands upright; only the camera's yaw is preserved.
func _anchor_cards_to_camera() -> void:
	var anchor := _compute_launch_anchor()
	var origin := anchor.origin
	var yaw_deg := rad_to_deg(anchor.basis.get_euler().y)
	print("[Operator] Launcher anchored at world (%.2f,%.2f,%.2f) yaw=%.1f° (cards world-locked)" % [origin.x, origin.y, origin.z, yaw_deg])
	for entry in _cards:
		entry.quad.transform = anchor * entry.local_offset


func _compute_launch_anchor() -> Transform3D:
	if _camera == null:
		return _launch_anchor_from_camera(Transform3D.IDENTITY, false)
	return _launch_anchor_from_camera(_camera.transform, _head_pose_is_tracked())


static func _launch_anchor_from_camera(camera_xf: Transform3D, head_pose_tracked: bool) -> Transform3D:
	# Height is not a tracking-validity signal. Quest STAGE space normally has
	# floor-relative eye height, while PICO may reuse LOCAL space after a scene
	# change and report a valid head pose near y=0. Replacing every y<0.5 value
	# with 1.5 put the world-locked launcher more than a metre above PICO users.
	if not head_pose_tracked:
		return Transform3D(Basis.IDENTITY, Vector3(0.0, FALLBACK_EYE_HEIGHT, 0.0))
	var origin := camera_xf.origin
	# Extract yaw only — pitch / roll would tilt the card row, which we
	# don't want for a static menu standing in front of the operator.
	# `basis.get_euler()` returns (pitch, yaw, roll); we rebuild a basis
	# from yaw alone so the launcher always stands upright.
	var yaw := camera_xf.basis.get_euler().y
	return Transform3D(Basis.from_euler(Vector3(0.0, yaw, 0.0)), origin)


func _head_pose_is_tracked() -> bool:
	var tracker := XRServer.get_tracker(&"head") as XRPositionalTracker
	if tracker == null or not tracker.has_pose(&"default"):
		return false
	var pose := tracker.get_pose(&"default")
	return pose != null and pose.get_has_tracking_data()


func _wire_card_ui(entry: CardEntry) -> void:
	if entry.ui != null:
		return
	# Wait up to ~1s for the Viewport2DIn3D's SubViewport to instance the
	# embedded mode_select_ui scene; in practice this is ready within a
	# couple of frames but we guard a long fallback to keep startup robust.
	for i in range(60):
		await get_tree().process_frame
		if entry.quad.has_method("get_scene_instance"):
			var inst: Variant = entry.quad.call("get_scene_instance")
			if inst is Control:
				entry.ui = inst as Control
				break

	if entry.ui == null:
		push_warning("[Operator] Mode card '%s' UI not ready" % entry.mode)
		return

	var data := _card_metadata(entry.mode)
	if entry.ui.has_method("configure"):
		entry.ui.configure(
			int(data.get("kind", 0)),
			tr(String(data.get("title_key", ""))),
		)
	if entry.ui.has_signal("selected"):
		entry.ui.selected.connect(_on_card_selected.bind(entry.mode))
	if not entry.status_pending.is_empty() and entry.ui.has_method("set_status"):
		entry.ui.set_status(entry.status_pending)
		entry.status_pending = ""


func _card_metadata(mode: String) -> Dictionary:
	match mode:
		MODE_TELEOP:
			return {"kind": CardUIScript.Kind.TELEOP, "title_key": "UI_TELEOP_MODE"}
		MODE_EGO_CAPTURE:
			return {"kind": CardUIScript.Kind.EGO_CAPTURE, "title_key": "UI_EGO_MODE"}
		MODE_LIVE_FEED:
			return {"kind": CardUIScript.Kind.LIVE_FEED, "title_key": "UI_LIVE_FEED_MODE"}
		MODE_VR:
			return {"kind": CardUIScript.Kind.VR, "title_key": "UI_VR_MODE"}
		MODE_EXIT:
			return {"kind": CardUIScript.Kind.EXIT, "title_key": "UI_EXIT_MODE"}
		_:
			return {"kind": CardUIScript.Kind.TELEOP, "title_key": "UI_TELEOP_MODE"}


func _set_status_for_all(text: String) -> void:
	for entry in _cards:
		if entry.ui and entry.ui.has_method("set_status"):
			entry.ui.set_status(text)
		else:
			entry.status_pending = text


func _on_card_selected(mode: String) -> void:
	_open_mode(mode)


## Every route into a mode goes through here: launcher cards, the
## `operator.mode` intent/CLI override and the export quick entry. Returns
## true when the launcher handed control over (scene change or app quit), so
## a refused route falls back to showing the launcher instead of a blank scene.
func _open_mode(mode: String) -> bool:
	if _changing_scene:
		return false
	var normalized := _normalize_mode(mode)
	if normalized.is_empty():
		push_warning("[Operator] Ignoring unknown mode: %s" % mode)
		return false
	if not _mode_available(normalized, _features):
		# A Teleop-only APK ships no capture scenes and no capture native
		# libraries, so an external intent must not be able to route into one.
		push_error(
			"[Operator] Mode '%s' is not available in this build (operator_feature_mode_%s is off)"
			% [normalized, normalized]
		)
		return false
	if normalized == MODE_EXIT:
		print("[Operator] Exit card pressed — quitting app")
		_hide_all_cards()
		get_tree().quit()
		return true
	var path := _scene_for_mode(normalized)
	if path.is_empty():
		push_warning("[Operator] Ignoring unknown mode: %s" % mode)
		return false
	_change_scene(path)
	return true


## MODE_MUJOCO is the one route without an `operator_feature_mode_*` flag: it
## is an internal bring-up scene, and its native library ships in every build
## profile.
static func _mode_available(mode: String, features: FeatureSet) -> bool:
	if mode == MODE_MUJOCO:
		return true
	return _mode_feature_enabled(mode, features)


## Picks the startup route for a cold launcher visit; "" means show the
## launcher. An explicit `operator.mode` request outranks the export quick
## entry, and a request this build cannot serve falls back to the launcher
## rather than to the quick entry — a device test that asked for ego_capture
## must not look like it started by landing in whatever mode the preset opens
## on.
static func resolve_startup_route(
	automation_mode: String,
	quick_entry_mode: String,
	features: FeatureSet,
	automation_requested: bool
) -> String:
	if automation_requested:
		if not automation_mode.is_empty() and _mode_available(automation_mode, features):
			return automation_mode
		return ""
	if not quick_entry_mode.is_empty() and _mode_available(quick_entry_mode, features):
		return quick_entry_mode
	return ""


func _change_scene(path: String) -> void:
	if _changing_scene:
		return
	_changing_scene = true
	print("[Operator] Mode selected: %s" % path)
	_hide_all_cards()
	call_deferred("_change_scene_deferred", path)


func _change_scene_deferred(path: String) -> void:
	await get_tree().process_frame
	var err := get_tree().change_scene_to_file(path)
	if err != OK:
		_changing_scene = false
		for entry in _cards:
			entry.quad.visible = true
		push_error("[Operator] Failed to change scene to %s: %s" % [path, err])


func _hide_all_cards() -> void:
	for entry in _cards:
		entry.quad.visible = false


func _scene_for_mode(mode: String) -> String:
	match mode:
		MODE_TELEOP:
			return TELEOP_SCENE
		MODE_EGO_CAPTURE:
			return EGO_CAPTURE_SCENE
		MODE_LIVE_FEED:
			return LIVE_FEED_SCENE
		MODE_VR:
			return VR_SCENE
		MODE_MUJOCO:
			return MUJOCO_SCENE
		_:
			return ""


func _get_automation_mode_request() -> Dictionary:
	var request := _mode_request_from_args(OS.get_cmdline_user_args())
	if request.is_empty():
		request = _mode_request_from_args(OS.get_cmdline_args())
	if request.is_empty():
		request = _mode_request_from_environment()
	if request.is_empty():
		return {"requested": false, "raw_mode": "", "mode": ""}
	var raw_mode := String(request["raw_mode"])
	return {
		"requested": true,
		"raw_mode": raw_mode,
		"mode": _normalize_mode(raw_mode),
	}


func _mode_request_from_args(args: PackedStringArray) -> Dictionary:
	for i in range(args.size()):
		var arg := String(args[i]).strip_edges()
		if arg == "--operator-mode" or arg == "--mode":
			if i + 1 < args.size():
				return {"raw_mode": String(args[i + 1]).strip_edges()}
			push_warning("[Operator] %s requires a value" % arg)
			return {"raw_mode": ""}
		if arg.begins_with("--operator-mode="):
			return {"raw_mode": arg.substr("--operator-mode=".length()).strip_edges()}
		if arg.begins_with("--mode="):
			return {"raw_mode": arg.substr("--mode=".length()).strip_edges()}
		if arg.begins_with("operator.mode="):
			return {"raw_mode": arg.substr("operator.mode=".length()).strip_edges()}
		if arg.begins_with("operator_mode="):
			return {"raw_mode": arg.substr("operator_mode=".length()).strip_edges()}
	return {}


## Intent extras surface as command-line args (same mechanism as
## operator.mode): `--es operator_test_suite <s>` arrives as either an
## "operator_test_suite <s>" pair or an "operator_test_suite=<s>" token.
func _requested_test_suite() -> String:
	var all_args: Array = []
	all_args.append_array(OS.get_cmdline_user_args())
	all_args.append_array(OS.get_cmdline_args())
	for i in range(all_args.size()):
		var arg := String(all_args[i]).strip_edges()
		for key in ["operator_test_suite", "--operator-test-suite"]:
			if arg == key and i + 1 < all_args.size():
				return String(all_args[i + 1]).strip_edges()
			if arg.begins_with(key + "="):
				return arg.substr(key.length() + 1).strip_edges()
	return ""


func _mode_request_from_environment() -> Dictionary:
	for key in ["OPERATOR_MODE", "XR_OPERATOR_MODE"]:
		if OS.has_environment(key):
			return {"raw_mode": OS.get_environment(key).strip_edges()}
	return {}


func _normalize_mode(raw_mode: String) -> String:
	var mode := raw_mode.strip_edges().to_lower().replace("-", "_")
	match mode:
		MODE_TELEOP, "teleoperation", "remote", "remote_control", "driver":
			return MODE_TELEOP
		MODE_EGO_CAPTURE, "ego", "ego_record", "egocentric", "capture", "capture_app", "record", "recording", "spatialmp4":
			return MODE_EGO_CAPTURE
		MODE_LIVE_FEED, "live_capture", "live", "live_server", "server_capture", "cloud_capture":
			return MODE_LIVE_FEED
		MODE_VR, "pure_vr", "robot_vr":
			return MODE_VR
		MODE_MUJOCO, "mj", "godot_mujoco", "simulation", "sim":
			return MODE_MUJOCO
		MODE_EXIT, "quit", "shutdown", "close":
			return MODE_EXIT
		"":
			return ""
		_:
			push_warning("[Operator] Unknown automation mode '%s' (expected teleop, ego_capture, live_feed, live_capture, vr, mujoco, or exit)" % raw_mode)
			return ""


func _configure_passthrough() -> void:
	var viewport := get_viewport()
	if viewport:
		viewport.transparent_bg = true
		viewport.physics_object_picking = false
		var world := viewport.get_world_3d()
		if world and world.environment:
			world.environment.background_mode = Environment.BG_CLEAR_COLOR
			world.environment.background_color = Color(0, 0, 0, 0)

	var xr_interface := XRServer.find_interface("OpenXR")
	if xr_interface:
		xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
