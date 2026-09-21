extends RefCounted
## Unit coverage for video-panel placement and controller-ray distance control.

const CASE_ID := "teleop.live_video_panel_layout"
const LiveVideoViewScript = preload("res://addons/live_video/live_video_view.gd")
const SettingsInteractionRouterScript = preload("res://scripts/ui/settings_interaction_router.gd")


## Stands in for a real control surface (the sidecar Reset button), which does
## act on a press and therefore keeps the historical capture-on-press behavior
## without declaring captures_teleop_press().
class PressCapturingTarget:
	extends RefCounted

	func captures_teleop_input() -> bool:
		return true


class LockedControlSurface:
	extends RefCounted

	func captures_teleop_input() -> bool:
		return true

	func captures_teleop_scroll() -> bool:
		return false


class RestartingDecoder:
	extends RefCounted
	var running := false
	var starts := 0

	func is_running() -> bool:
		return running

	func start_decoder_with_codec(_width: int, _height: int, _codec: String) -> bool:
		starts += 1
		running = true
		return true


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var view = LiveVideoViewScript.new()
	var camera := XRCamera3D.new()
	var display := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(3.2, 1.8)
	display.mesh = quad
	view.add_child(camera)
	view.add_child(display)
	view._xr_camera = camera
	view._display_mesh = display
	view._default_panel_distance = 3.0
	view.follow_distance = 3.0

	view.follow_camera = true
	view.set_panel_distance(2.0)
	t.is_true(is_equal_approx(view.follow_distance, 2.0), "view-locked distance is adjustable")
	t.is_true(display.position.is_equal_approx(Vector3(0.0, 0.0, -2.0)),
		"view-locked panel moves in front of the camera")
	t.is_true(view.is_panel_distance_locked(), "video distance starts locked")
	t.is_true(view.captures_teleop_input(),
		"video panel remains an interaction target while locked")
	t.is_false(view.captures_teleop_scroll(),
		"a locked video panel does not capture robot joystick input")
	view.adjust_panel_distance_from_scroll(-100.0)
	t.is_true(is_equal_approx(view.follow_distance, 2.0),
		"a locked panel ignores joystick distance changes")
	view.set_panel_distance_locked(false)
	t.is_true(view.captures_teleop_scroll(),
		"an unlocked video panel captures joystick input while adjusting")
	view.adjust_panel_distance_from_scroll(-100.0)
	t.is_true(is_equal_approx(view.follow_distance, 2.15),
		"joystick-up scroll moves the video panel farther away")

	view.follow_camera = false
	var world_locked_basis := Basis(Vector3.UP, deg_to_rad(15.0))
	display.basis = world_locked_basis
	view.adjust_panel_distance_from_scroll(100.0)
	t.is_true(is_equal_approx(view.follow_distance, 2.15),
		"world-locked panel accepts ray-target joystick distance input")
	t.is_true(display.position.is_equal_approx(Vector3(0.0, 0.0, -2.15)),
		"world-locked distance change repositions once without enabling follow mode")
	t.is_true(display.basis.is_equal_approx(world_locked_basis),
		"world-locked distance adjustment preserves panel orientation")
	t.is_false(view.follow_camera, "distance adjustment preserves world-lock mode")

	view.set_panel_distance(100.0)
	t.is_true(is_equal_approx(view.follow_distance, 6.0), "distance is capped at the far limit")
	view.set_panel_distance(0.1)
	t.is_true(is_equal_approx(view.follow_distance, 2.0), "distance is capped at the near limit")

	view.reset_panel_position()
	t.is_true(is_equal_approx(view.follow_distance, 3.0), "Reset restores the default distance")
	t.is_true(display.position.is_equal_approx(Vector3(0.0, 0.0, -3.0)),
		"Reset centers the panel in front of the current view")
	t.is_false(view.follow_camera, "Reset preserves world-lock mode")

	camera.position = Vector3(1.0, 0.5, 0.25)
	view.show_video_panel = false
	view.visible = false
	view._initialized = true
	view._receiving_video = true
	view.set_show_video_panel(true)
	t.is_true(
		display.position.is_equal_approx(camera.position + Vector3(0.0, 0.0, -3.0)),
		"a newly visible world-locked panel starts in front of the current view"
	)
	view.set_show_performance_info(false)
	t.is_false(view.show_performance_info, "video performance information can be hidden")
	view.set_show_performance_info(true)
	t.is_true(view.show_performance_info, "video performance information can be restored")

	t.is_true(view.update_pointer_from_ray(camera.position, Vector3.FORWARD),
		"controller ray can target the video surface")
	t.is_false(view.update_pointer_from_ray(camera.position, Vector3.RIGHT),
		"rays missing the video surface are rejected")

	var performance_offset := LiveVideoViewScript._performance_panel_local_offset(
		Vector2(3.2, 1.8), Vector2(3.2, 0.45)
	)
	t.is_true(is_zero_approx(performance_offset.x),
		"performance panel stays horizontally aligned with the video")
	t.is_true(performance_offset.y > 1.8 * 0.5,
		"performance panel is positioned above the video")
	t.is_true(performance_offset.z > 0.0,
		"performance panel renders slightly in front of the video plane")
	var menu_offset := LiveVideoViewScript._video_menu_local_offset(
		Vector2(3.2, 1.8), Vector2(0.9, 0.39), Vector2(3.2, 0.23)
	)
	t.is_true(menu_offset.y < -1.8 * 0.5,
		"the expanded video menu is positioned below the video")
	var status_offset := LiveVideoViewScript._video_status_local_offset(
		Vector2(3.2, 1.8), Vector2(3.2, 0.23)
	)
	t.is_true(status_offset.y < -1.8 * 0.5 and status_offset.y > menu_offset.y,
		"the status bar stays between the video and expanded controls")
	var more_offset := LiveVideoViewScript._video_more_button_local_offset(
		Vector2(3.2, 1.8), Vector2(0.16, 0.16)
	)
	t.is_true(more_offset.x > 0.0 and more_offset.y < 0.0,
		"the compact menu button sits inside the video's lower-right corner")

	view._record_local_latency({"receive_ns": 1_000_000_000}, 1_025_000_000)
	t.is_true(is_equal_approx(view._smoothed_local_latency_ms, 25.0),
		"XRobotToolkit receive timestamps produce a numeric local latency")
	view._stale_dropped_count = 2
	view._decoder_busy_count = 3
	t.is_true(view._total_drop_count() == 5,
		"compact drop count includes local stale and decoder drops")

	t.eq(
		LiveVideoViewScript._resolve_yuv_color_standard("auto", 720),
		LiveVideoViewScript.YUV_COLOR_STANDARD_BT709,
		"720p video defaults to BT.709",
	)
	t.eq(
		LiveVideoViewScript._resolve_yuv_color_standard("smpte170m", 1080),
		LiveVideoViewScript.YUV_COLOR_STANDARD_BT601,
		"explicit BT.601 aliases override the resolution default",
	)
	t.eq(
		LiveVideoViewScript._resolve_yuv_color_range("jpeg"),
		LiveVideoViewScript.YUV_COLOR_RANGE_FULL,
		"JPEG/full-range aliases select full-range YUV",
	)
	var intervals: Array[float] = [33.0, 34.0, 50.0, 32.0, 40.0]
	t.is_true(
		is_equal_approx(LiveVideoViewScript._frame_interval_percentile(intervals, 0.50), 34.0),
		"draw interval P50 uses the rendered-frame sample window",
	)
	t.is_true(
		is_equal_approx(LiveVideoViewScript._frame_interval_percentile(intervals, 0.95), 50.0),
		"draw interval P95 exposes visible pacing spikes",
	)

	view._submitted_video_packets = [
		{"frame_id": 10, "receive_ns": 1_000_123},
		{"frame_id": 11, "receive_ns": 2_000_456},
		{"frame_id": 12, "receive_ns": 3_000_789},
	]
	var correlated_packet := view._take_latest_decoder_packet(1, 3000)
	t.eq(int(correlated_packet.get("frame_id", -1)), 12,
		"MediaCodec PTS skips parameter-set metadata that produced no frame")
	t.eq(view._submitted_video_packets.size(), 0,
		"PTS correlation retires all metadata through the decoded frame")

	view.visible = false
	view._pending_draw_sequence = 3
	view._on_frame_post_draw()
	t.eq(view._drawn_frame_count, 0,
		"frames received while the panel is hidden are not counted as drawn")
	t.eq(view._display_skipped_frame_count, 0,
		"frames intentionally hidden are not counted as display drops")
	view.visible = true
	view._pending_draw_sequence = 5
	view._on_frame_post_draw()
	t.eq(view._drawn_frame_count, 1,
		"one render completion counts one actually drawn source frame")
	t.eq(view._display_skipped_frame_count, 1,
		"only mailbox sequences skipped while visible are counted as display drops")
	view._on_frame_post_draw()
	t.eq(view._drawn_frame_count, 1,
		"re-rendering the same texture does not inflate displayed frame count")

	var restarting_decoder := RestartingDecoder.new()
	view._video_decoder = restarting_decoder
	view._configured_width = 1280
	view._configured_height = 720
	view._configured_codec = "h264"
	view._on_video_decoder_error("synthetic failure")
	t.is_true(view._decoder_restart_pending,
		"decoder failures schedule recovery after the worker stops")
	view._restart_video_decoder_after_error()
	t.eq(restarting_decoder.starts, 1,
		"decoder recovery restarts the configured codec")
	t.is_false(view._decoder_restart_pending,
		"successful decoder recovery clears the pending restart")
	view._video_decoder = null

	# Regression: the measured distance must not be clamped before the scroll
	# delta is applied. In world-locked mode the operator can walk until the
	# panel sits outside [MIN, MAX]; a pre-clamped reading let a single scroll
	# tick land strictly inside the range it should have stopped at (8.0 read
	# as 6.0, minus one tick = 5.85).
	view.follow_camera = false
	display.position = camera.position + Vector3(0.0, 0.0, -8.0)
	t.is_true(is_equal_approx(view._current_panel_distance(), 8.0),
		"an out-of-range panel reports its true distance, unclamped")
	view.adjust_panel_distance_from_scroll(100.0)
	t.is_true(is_equal_approx(view.follow_distance, 6.0),
		"pulling an out-of-range panel closer stops exactly at the far limit")

	# Regression: clear_video_stream() rebinds the shader to the placeholder,
	# so the AHB bind flag must clear with it. Leaving it set wedged the view
	# permanently -- _process() only rebinds while the flag is false and the
	# YUV fallback returns early while it is true, so nothing could draw again
	# after a reconnect.
	view._ahb_bound_to_shader = true
	view.clear_video_stream()
	t.is_false(view._ahb_bound_to_shader,
		"clearing the stream releases the AHB binding so a reconnect can rebind")

	# Regression: a trigger press on the passive video surface must not capture
	# teleop input. set_pointer_pressed() is a no-op here, so capturing would
	# neutralize every controller key -- the grip deadman included -- while the
	# operator was merely pointing through the panel at the robot.
	var router := SettingsInteractionRouterScript.new()
	t.is_true(view.captures_teleop_input(),
		"video panel still captures while its scroll axis is being adjusted")
	t.is_false(view.captures_teleop_press(),
		"video panel must not claim capture for a press it does not act on")
	router._pressed_target = view
	t.is_false(router.is_teleop_input_captured(),
		"pressing the passive video surface must not zero the grip deadman")

	var control_surface := PressCapturingTarget.new()
	router._pressed_target = control_surface
	t.is_true(router.is_teleop_input_captured(),
		"a real control surface still captures teleop input on press")
	var locked_control := LockedControlSurface.new()
	router._pressed_target = locked_control
	t.is_true(router.is_teleop_input_captured(),
		"locked sidecar buttons capture press input without enabling scroll capture")
	t.is_false(
		SettingsInteractionRouterScript._target_captures_teleop_scroll(locked_control),
		"locked sidecar does not capture joystick scrolling",
	)
	router.free()

	view.free()
