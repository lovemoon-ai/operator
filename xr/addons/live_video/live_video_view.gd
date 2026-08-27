class_name LiveVideoView
extends Node3D
## Reusable 3D display for low-latency H.264 live video.
## The view accepts Annex-B H.264 NAL/access-unit packets from any source,
## sends them to the Android MediaCodec decoder singleton, and presents the
## decoded output via AHB, YUV-plane, or RGBA texture paths.

const VideoLatencyTracker = preload("res://addons/live_video/live_video_latency.gd")
const VideoPanelSidecarScript = preload("res://scripts/ui/video_panel_sidecar.gd")
const DEFAULT_VIDEO_DECODER_SINGLETON := "KotlinVideoDecoderPlugin"
const TARGET_GROUP := "operator_interaction_target"
const DEFAULT_PANEL_DISTANCE := 3.0
const MIN_PANEL_DISTANCE := 2.0
const MAX_PANEL_DISTANCE := 6.0
const DISTANCE_METERS_PER_SCROLL_PIXEL := 0.0015
const PERFORMANCE_PANEL_GAP_METERS := 0.10
const SIDECAR_Z_OFFSET_METERS := 0.02
const VIDEO_INTERACTION_PRIORITY := 10

@onready var _display_mesh: MeshInstance3D = get_node_or_null("DisplayMesh") as MeshInstance3D
var _panel_sidecar: Node3D

# How often to refresh the performance sidecar. Once every 200 ms keeps the numbers
# legible while still being fresh enough to react to network blips.
const _HUD_UPDATE_INTERVAL_NS: int = 200_000_000
var _last_hud_update_ns: int = 0
var _display_fps: float = 0.0
var _fps_sample_ns: int = 0
var _fps_sample_frames: int = 0
var _presented_frame_count: int = 0
# Source of UDP-level reassembly drops, injected by main.gd via
# `set_packet_source`. Optional — the HUD just shows -- for udp drops if
# no source is set (e.g. on the TCP path).
var _packet_source: Node = null
var _clock_offset_ns: int = 0
var _clock_samples: int = 0

# EWMA-smoothed receive-to-display latency. Unlike source-to-headset latency,
# this is available for both Operator timed frames and XRobotToolkit frames.
const _LATENCY_EWMA_ALPHA: float = 0.2
var _smoothed_local_latency_ms: float = -1.0


## Called by main.gd whenever a new TCP/UDP video handler takes over.
## We hold a weak reference to whichever one is live so the HUD can
## surface its drop counter.
func set_packet_source(handler: Node) -> void:
	_packet_source = handler


## Optional source-clock synchronisation. offset_ns is source_clock - local_clock.
func set_clock_offset(offset_ns: int, samples: int = 1) -> void:
	_clock_offset_ns = offset_ns
	_clock_samples = maxi(0, samples)

var _shader_material: ShaderMaterial
var _placeholder_texture: ImageTexture
var _video_texture: ImageTexture
var _video_texture_size: Vector2i = Vector2i.ZERO
var _initialized: bool = false
var _receiving_video: bool = false
var _last_video_packet: Dictionary = {}
var _video_decoder: Object = null
var _video_decoder_connected: bool = false
var _video_decoder_warning_logged: bool = false
var _configured_width: int = 0
var _configured_height: int = 0
# Active codec family ("h264" / "hevc") last passed to the decoder. Defaults to
# H.264 so a descriptor without a `codec` field keeps the historical behaviour,
# and so the first configure only restarts the decoder when it actually flips.
var _configured_codec: String = "h264"
var _desired_stereo_layout: bool = true
var _video_layout_stereo: bool = true
var _pending_access_unit: PackedByteArray = PackedByteArray()
var _submitted_video_packets: Array[Dictionary] = []
var _last_ahb_frame_count: int = 0


## When true, the display panel rides with the user's head so it is always
## visible in front of them. Useful for smoke testing without needing to
## carefully position your headset before launch.
@export var follow_camera: bool = true
## Distance in meters in front of the camera when follow_camera is enabled.
@export var follow_distance: float = DEFAULT_PANEL_DISTANCE
## Optional camera path. When empty, the view looks for `XRCamera3D` under its parent.
@export var camera_path: NodePath
## Create the default quad, collision body, and HUD label if the scene did not provide them.
@export var auto_create_display_nodes: bool = true
## Default display size in meters when auto-creating the panel mesh.
@export var display_size: Vector2 = Vector2(3.2, 1.8)
## Godot Android plugin singleton that exposes start_decoder/submit_access_unit.
@export var decoder_singleton_name: String = DEFAULT_VIDEO_DECODER_SINGLETON
## When false, the panel stays hidden even when the robot is sending frames —
## the user opted out of the video display entirely. When true, the panel
## still only becomes visible AFTER `_receiving_video` flips on (i.e. a decoded
## frame was presented). Default OFF so a fresh install doesn't
## park a placeholder quad in front of the operator before they've connected
## to anything.
@export var show_video_panel: bool = false

var _xr_camera: XRCamera3D = null
var _default_panel_distance := DEFAULT_PANEL_DISTANCE
var _panel_placement_initialized := false
var _last_panel_hit_point := Vector3.ZERO
var _has_panel_hit_point := false


func _ready() -> void:
	# Display starts hidden until XR is ready.
	_ensure_display_nodes()
	_ensure_panel_sidecar()
	_default_panel_distance = clampf(follow_distance, MIN_PANEL_DISTANCE, MAX_PANEL_DISTANCE)
	add_to_group(TARGET_GROUP)
	_set_performance_metrics(0.0, 0.0, 0, 0)
	visible = false


func _ensure_display_nodes() -> void:
	if _display_mesh != null or not auto_create_display_nodes:
		return

	_display_mesh = MeshInstance3D.new()
	_display_mesh.name = "DisplayMesh"
	_display_mesh.transform.origin = Vector3(0, 0, -2.0)
	var quad := QuadMesh.new()
	quad.size = display_size
	_display_mesh.mesh = quad
	add_child(_display_mesh)

	var body := StaticBody3D.new()
	body.name = "StaticBody3D"
	body.collision_layer = 1048576
	body.collision_mask = 0
	_display_mesh.add_child(body)

	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	var shape := BoxShape3D.new()
	shape.size = Vector3(display_size.x, display_size.y, 0.02)
	collision.shape = shape
	body.add_child(collision)



func _ensure_panel_sidecar() -> void:
	if _panel_sidecar != null:
		return
	_panel_sidecar = VideoPanelSidecarScript.new()
	_panel_sidecar.name = "VideoPanelSidecar"
	if _panel_sidecar.has_signal("reset_requested"):
		_panel_sidecar.connect("reset_requested", reset_panel_position)
	add_child(_panel_sidecar)
	_sync_sidecar_transform()


## Initialize the display after XR is started.
func initialize() -> void:
	if _initialized:
		return

	_ensure_display_nodes()
	_create_placeholder_texture()
	_setup_material()
	_try_create_ahb_texture()
	_initialized = true
	# Cache XRCamera3D so _process can keep the panel in front of the user.
	_resolve_camera()
	# World-locked mode still needs one camera-relative placement. After this
	# initial placement it stays in world space until the user adjusts or resets.
	_place_panel_in_front_of_camera(follow_distance)
	# Defer visibility to `_update_panel_visibility`: even when the user has
	# opted in via `show_video_panel`, we only un-hide once the robot is
	# actually sending frames — otherwise the operator sees the blue
	# placeholder quad floating in front of them.
	_update_panel_visibility()
	print("[LiveVideo] Display initialized (follow_camera=%s, show_video_panel=%s, ahb=%s)" % [
		follow_camera, show_video_panel, _ahb_texture != null,
	])


## External setter so main.gd can flip the preference without touching the
## exported property directly (keeps the visibility invariant centralised).
func set_show_video_panel(value: bool) -> void:
	if show_video_panel == value:
		return
	show_video_panel = value
	_update_panel_visibility()


## Single source of truth for whether the 3D panel should be on screen.
## The panel is visible iff (a) the user opted in via `show_video_panel`,
## AND (b) we've seen at least one frame from the robot. Called from
## `_process` so transitions (`_receiving_video` flips, `clear_video_stream`)
## are picked up within one frame without us having to sprinkle calls at
## every state mutation site.
func _update_panel_visibility() -> void:
	var want_visible := _initialized and show_video_panel and _receiving_video
	var became_visible := want_visible and not visible
	if visible != want_visible:
		visible = want_visible
	if _panel_sidecar != null:
		_panel_sidecar.visible = want_visible
	if became_visible and not follow_camera:
		_place_panel_in_front_of_camera(follow_distance)


func _resolve_camera() -> void:
	_xr_camera = null
	if not String(camera_path).is_empty():
		_xr_camera = get_node_or_null(camera_path) as XRCamera3D
		if _xr_camera:
			return
	var origin := get_parent()
	if origin:
		_xr_camera = origin.get_node_or_null("XRCamera3D") as XRCamera3D


func get_interaction_priority() -> int:
	return VIDEO_INTERACTION_PRIORITY


func is_interaction_target_visible() -> bool:
	return is_inside_tree() and visible and _display_mesh != null


func captures_teleop_input() -> bool:
	return true


## The video panel is a passive display: set_pointer_pressed() is a no-op and
## the only input it consumes is the scroll axis used to adjust its distance.
## Reporting press capture here would zero every controller key -- the grip
## deadman included -- whenever the operator's ray crossed the panel while
## squeezing the trigger, which is the ordinary teleop pointing case because
## this target has the lowest interaction priority and sits in view centre.
func captures_teleop_press() -> bool:
	return false


func update_pointer_from_ray(ray_origin: Vector3, ray_direction: Vector3) -> bool:
	if _display_mesh == null or not visible:
		clear_pointer()
		return false
	var direction := ray_direction.normalized()
	if direction.length_squared() < 0.000001:
		clear_pointer()
		return false
	var normal := _display_mesh.global_transform.basis.z.normalized()
	var denominator := normal.dot(direction)
	if absf(denominator) < 0.0001:
		clear_pointer()
		return false
	var distance_m := normal.dot(_display_mesh.global_transform.origin - ray_origin) / denominator
	if distance_m <= 0.0:
		clear_pointer()
		return false
	var hit_point := ray_origin + direction * distance_m
	var local_hit := _display_mesh.to_local(hit_point)
	var half_size := _display_dimensions() * 0.5
	if absf(local_hit.x) > half_size.x or absf(local_hit.y) > half_size.y:
		clear_pointer()
		return false
	_last_panel_hit_point = hit_point
	_has_panel_hit_point = true
	return true


func set_pointer_pressed(_pressed: bool) -> void:
	pass


func clear_pointer() -> void:
	_has_panel_hit_point = false


func get_ray_hit_point(ray_origin: Vector3, ray_direction: Vector3) -> Vector3:
	if _has_panel_hit_point:
		return _last_panel_hit_point
	var direction := ray_direction.normalized()
	return ray_origin + direction * 0.25 if direction.length_squared() > 0.000001 else ray_origin


func scroll_by_pixels(delta_pixels: float) -> void:
	adjust_panel_distance_from_scroll(delta_pixels)


func adjust_panel_distance_from_scroll(delta_pixels: float) -> void:
	if absf(delta_pixels) < 0.001:
		return
	var current_distance := _current_panel_distance()
	set_panel_distance(current_distance + delta_pixels * DISTANCE_METERS_PER_SCROLL_PIXEL)


func set_panel_distance(distance_m: float) -> void:
	follow_distance = clampf(distance_m, MIN_PANEL_DISTANCE, MAX_PANEL_DISTANCE)
	if follow_camera or not _panel_placement_initialized:
		_place_panel_in_front_of_camera(follow_distance)
	else:
		_move_world_locked_panel_to_distance(follow_distance)


func reset_panel_position() -> void:
	follow_distance = _default_panel_distance
	_place_panel_in_front_of_camera(follow_distance)


## The panel's true distance from the camera, unclamped.
##
## Callers feed this into set_panel_distance(), which applies the single
## authoritative clamp. Clamping here as well would double-clamp: in
## world-locked mode the operator can walk until the panel sits outside
## [MIN_PANEL_DISTANCE, MAX_PANEL_DISTANCE], and a pre-clamped reading would
## then let one scroll tick push the panel past the limit it was supposed to
## stop at (8.0 m reads as 6.0, minus a tick lands on 5.85 -- inside the range
## the operator never scrolled into). Returning the real distance keeps the
## limits absolute: an out-of-range panel snaps to the boundary and stays.
func _current_panel_distance() -> float:
	if _xr_camera == null:
		_resolve_camera()
	if _xr_camera == null or _display_mesh == null:
		return follow_distance
	var camera_origin := _xr_camera.global_transform.origin
	var distance_m := camera_origin.distance_to(_display_mesh.global_transform.origin)
	if distance_m <= 0.0:
		return follow_distance
	return distance_m


func _place_panel_in_front_of_camera(distance_m: float) -> void:
	if _xr_camera == null:
		_resolve_camera()
	if _xr_camera == null or _display_mesh == null:
		return
	var camera_transform := _xr_camera.global_transform
	var panel_transform := Transform3D(camera_transform.basis, camera_transform.origin)
	panel_transform.origin += -camera_transform.basis.z.normalized() * distance_m
	_display_mesh.global_transform = panel_transform
	_panel_placement_initialized = true
	_sync_sidecar_transform()


func _move_world_locked_panel_to_distance(distance_m: float) -> void:
	if _xr_camera == null:
		_resolve_camera()
	if _xr_camera == null or _display_mesh == null:
		return
	var camera_origin := _xr_camera.global_transform.origin
	var direction := _display_mesh.global_transform.origin - camera_origin
	if direction.length_squared() < 0.000001:
		direction = -_xr_camera.global_transform.basis.z
	var panel_transform := _display_mesh.global_transform
	panel_transform.origin = camera_origin + direction.normalized() * distance_m
	_display_mesh.global_transform = panel_transform
	_panel_placement_initialized = true
	_sync_sidecar_transform()


func _display_dimensions() -> Vector2:
	if _display_mesh != null and _display_mesh.mesh is QuadMesh:
		return (_display_mesh.mesh as QuadMesh).size
	return display_size


func _sync_sidecar_transform() -> void:
	if _panel_sidecar == null or _display_mesh == null:
		return
	var sidecar_size_value: Variant = _panel_sidecar.get("quad_size")
	var sidecar_size := Vector2(3.2, 0.45)
	if sidecar_size_value is Vector2:
		sidecar_size = sidecar_size_value
	_panel_sidecar.global_transform = _display_mesh.global_transform * Transform3D(
		Basis.IDENTITY, _performance_panel_local_offset(_display_dimensions(), sidecar_size)
	)


static func _performance_panel_local_offset(
		video_size: Vector2, performance_panel_size: Vector2
) -> Vector3:
	return Vector3(
		0.0,
		video_size.y * 0.5 + PERFORMANCE_PANEL_GAP_METERS + performance_panel_size.y * 0.5,
		SIDECAR_Z_OFFSET_METERS,
	)


func get_panel_anchor_transform(local_offset: Vector3) -> Transform3D:
	if _display_mesh == null:
		return global_transform
	return _display_mesh.global_transform * Transform3D(Basis.IDENTITY, local_offset)


func _set_performance_text(text: String) -> void:
	if _panel_sidecar != null and _panel_sidecar.has_method("set_performance_text"):
		_panel_sidecar.call("set_performance_text", text)


func _set_performance_metrics(fps: float, latency_ms: float, drops: int, frames: int) -> void:
	_set_performance_text(tr("UI_VIDEO_PERFORMANCE_FORMAT") % [
		_fmt_compact_fps(fps),
		_fmt_compact_ms(latency_ms),
		str(maxi(drops, 0)),
		str(maxi(frames, 0)),
	])


## [opt 10] Try to instantiate the AhbVideoTexture from the
## libahb_decoder.so GDExtension. When successful, this becomes the
## actual sampled texture for the YUV path — Plan B's three L8
## textures are unused. ClassDB returns null when the GDExtension
## isn't loaded (i.e. .so missing on this build), in which case we
## silently keep the plan B path active.
func _try_create_ahb_texture() -> void:
	if not ClassDB.class_exists("AhbVideoTexture"):
		return
	var inst: Object = ClassDB.instantiate("AhbVideoTexture")
	if inst == null:
		return
	# We hold a strong reference; the instance lives as long as LiveVideoView.
	_ahb_texture = inst as Texture2D
	print("[LiveVideo] AhbVideoTexture instantiated (zero-copy AHB path armed)")


func _process(_delta: float) -> void:
	# [opt 10] Once the AhbVideoTexture's native side reports ready
	# (first VkImage successfully imported), swap it into the shader
	# in place of plan B's three L8 textures. After this swap the
	# per-frame work in _on_video_yuv_frame_ready is skipped — the
	# AHB path updates the texture content from native code.
	if _ahb_texture and not _ahb_bound_to_shader and _shader_material:
		var ready: bool = false
		if _ahb_texture.has_method("is_ready"):
			ready = bool(_ahb_texture.call("is_ready"))
		if ready:
			_shader_material.set_shader_parameter("use_yuv", false)
			_shader_material.set_shader_parameter("video_texture", _ahb_texture)
			_ahb_bound_to_shader = true
			_receiving_video = true
			print("[LiveVideo] AhbVideoTexture bound; AHB zero-copy path is now live")
	# The two YUV-mode call sites apply the stereo layout (Plan B's GPU YUV
	# path + the legacy image-update path); the AHB path bypasses both, so
	# the shader was stuck on the default `stereo_layout=true, content_ratio=0.5`
	# side-by-side split for mono streams. Apply it on every _process tick
	# so a later `configure_video_stream({stereo: ...})` is picked up too.
	if _ahb_bound_to_shader and _video_layout_stereo != _desired_stereo_layout:
		_apply_video_layout(_desired_stereo_layout)

	# Cheap idempotent check; flips visibility on the frame after
	# `_receiving_video` (or `show_video_panel`) changes — keeps the panel
	# hidden until the robot is actually streaming and the user opted in.
	_update_panel_visibility()
	_update_latency_hud()

	# Once the AHB path is live, the YUV-frame-ready signal stops firing
	# (Kotlin is in Surface mode), so the regular per-second stats line
	# never prints. Sample the AHB texture's decoded_ns once a second to
	# get a real post-decode latency number for comparison vs the Plan-B
	# baseline (~50 ms total_avg from CPU YUV upload).
	if _ahb_bound_to_shader and _ahb_texture and _ahb_texture.has_method("get_latest_info"):
		# `decoded_ns` from native is wall-clock ns (System.currentTimeMillis
		# * 1e6) — match it via Time.get_unix_time_from_system() for a
		# meaningful subtraction.
		var now_ns := int(Time.get_unix_time_from_system() * 1_000_000_000.0)
		if now_ns - _last_latency_log_ns >= 1_000_000_000:
			_last_latency_log_ns = now_ns
			var info: Dictionary = _ahb_texture.call("get_latest_info")
			var dec_ns: int = int(info.get("decoded_ns", 0))
			var n: int = int(info.get("frames", 0))
			if dec_ns > 0:
				var post_decode_ms := float(now_ns - dec_ns) / 1_000_000.0
				var rx_to_ahb_ms := -1.0
				var bridge_to_ahb_ms := -1.0
				var import_fps := -1.0
				var rx_samples := 0
				var bridge_samples := 0
				var timing_map := 0
				if _video_decoder:
					var stats: Dictionary = _video_decoder.call("get_ahb_latency_stats")
					if not stats.is_empty():
						rx_to_ahb_ms = _stat_ms(stats, "rx_to_ahb_avg_ms", "rx_to_ahb_count")
						bridge_to_ahb_ms = _stat_ms(stats, "bridge_to_ahb_avg_ms", "bridge_to_ahb_count")
						import_fps = float(stats.get("import_fps", -1.0))
						rx_samples = int(stats.get("rx_to_ahb_count", 0))
						bridge_samples = int(stats.get("bridge_to_ahb_count", 0))
						timing_map = int(stats.get("timing_map", 0))
				print("[LiveVideo] AHB stats: frames=%d post_decode=%.1f ms rx_to_ahb=%s bridge_to_ahb=%s import_fps=%s samples=%d/%d timing_map=%d" % [
					n,
					post_decode_ms,
					_fmt_ms(rx_to_ahb_ms),
					_fmt_ms(bridge_to_ahb_ms),
					_fmt_fps(import_fps),
					rx_samples,
					bridge_samples,
					timing_map,
				])

	if _initialized and _display_mesh and _xr_camera:
		if follow_camera or not _panel_placement_initialized:
			_place_panel_in_front_of_camera(follow_distance)
		else:
			_sync_sidecar_transform()
	else:
		_sync_sidecar_transform()


## Refresh the compact performance sidecar. It intentionally reports only
## values available for every supported transport: displayed FPS, local
## receive-to-display latency, local/transport drops, and displayed frames.
func _update_latency_hud() -> void:
	if _panel_sidecar == null:
		return
	var now_ns := VideoLatencyTracker.now_ns()
	if now_ns - _last_hud_update_ns < _HUD_UPDATE_INTERVAL_NS:
		return
	_last_hud_update_ns = now_ns

	if not _receiving_video:
		_fps_sample_ns = 0
		_fps_sample_frames = 0
		_set_performance_metrics(0.0, 0.0, _total_drop_count(), 0)
		return

	var displayed_frames: int = _presented_frame_count
	if _ahb_bound_to_shader and _ahb_texture and _ahb_texture.has_method("get_latest_info"):
		var info: Dictionary = _ahb_texture.call("get_latest_info")
		displayed_frames = int(info.get("frames", displayed_frames))
		var decoded_ns := int(info.get("decoded_ns", 0))
		if displayed_frames > _last_ahb_frame_count:
			_record_local_latency(_take_latest_ahb_packet(displayed_frames), decoded_ns)
	_update_display_fps(now_ns, displayed_frames)

	_set_performance_metrics(
		_display_fps,
		_smoothed_local_latency_ms,
		_total_drop_count(),
		displayed_frames,
	)


func _record_local_latency(packet: Dictionary, completed_ns: int) -> void:
	var receive_ns := int(packet.get("receive_ns", 0))
	if receive_ns <= 0 or completed_ns < receive_ns:
		return
	var sample_ms := float(completed_ns - receive_ns) / 1_000_000.0
	_smoothed_local_latency_ms = sample_ms if _smoothed_local_latency_ms < 0.0 else _ewma(
		_smoothed_local_latency_ms, sample_ms
	)


func _total_drop_count() -> int:
	var drops := _stale_dropped_count + _decoder_busy_count
	if (
		bool(_last_video_packet.get("transport_loss_available", true))
		and _packet_source != null
		and _packet_source.has_method("get_drop_count")
	):
		drops += maxi(0, int(_packet_source.call("get_drop_count")))
	return drops


func _update_display_fps(now_ns: int, displayed_frames: int) -> void:
	if _fps_sample_ns == 0 or displayed_frames < _fps_sample_frames:
		_fps_sample_ns = now_ns
		_fps_sample_frames = displayed_frames
		return
	var elapsed_ns := now_ns - _fps_sample_ns
	if elapsed_ns < 1_000_000_000:
		return
	_display_fps = float(displayed_frames - _fps_sample_frames) / (float(elapsed_ns) / 1_000_000_000.0)
	_fps_sample_ns = now_ns
	_fps_sample_frames = displayed_frames


static func _ewma(prev: float, sample: float) -> float:
	return prev * (1.0 - _LATENCY_EWMA_ALPHA) + sample * _LATENCY_EWMA_ALPHA


static func _fmt_ms(v: float) -> String:
	# Fixed-width " 12.3 ms" / "100.5 ms" / "   -- ms" — 8 chars.
	if v < 0.0 or is_nan(v) or is_inf(v):
		return "   -- ms"
	return "%5.1f ms" % v


static func _fmt_fps(v: float) -> String:
	if v < 0.0 or is_nan(v) or is_inf(v):
		return "--"
	return "%.1f" % v


static func _fmt_compact_fps(v: float) -> String:
	if v < 0.0 or is_nan(v) or is_inf(v):
		return "0.0"
	return "%.1f" % v


static func _fmt_compact_ms(v: float) -> String:
	if v < 0.0 or is_nan(v) or is_inf(v):
		return "0.0 ms"
	return "%.1f ms" % v


static func _stat_ms(stats: Dictionary, value_key: String, count_key: String) -> float:
	if int(stats.get(count_key, 0)) <= 0:
		return -1.0
	var v := float(stats.get(value_key, -1.0))
	if is_nan(v) or is_inf(v):
		return -1.0
	return v


## Configure the incoming video stream and start the decoder plugin if it exists.
func configure_video_stream(feed: Dictionary) -> void:
	if not _initialized:
		initialize()

	var width := int(feed.get("width", 1280))
	var height := int(feed.get("height", 720))
	var stereo := bool(feed.get("stereo", false))
	# The robot always advertises "h264" or "hevc" in the descriptor; default to
	# h264 so pre-codec robots keep working.
	var codec_raw := String(feed.get("codec", "h264")).to_lower()
	var codec := "hevc" if codec_raw in ["hevc", "h265", "x265"] else "h264"

	var decoder_size_changed := width != _configured_width or height != _configured_height
	var layout_changed := stereo != _desired_stereo_layout
	var codec_changed := codec != _configured_codec

	var decoder_running := _decoder_is_running()

	if not decoder_size_changed and not layout_changed and not codec_changed and decoder_running:
		return

	_configured_width = width
	_configured_height = height
	_configured_codec = codec
	_desired_stereo_layout = stereo
	_pending_access_unit = PackedByteArray()
	_submitted_video_packets.clear()

	if not _ensure_video_decoder(width, height):
		if decoder_size_changed or layout_changed or codec_changed:
			print("[LiveVideo] Video decoder unavailable; keeping placeholder texture")
		return

	if (decoder_size_changed or codec_changed) and decoder_running:
		_decoder_call_void("stop_decoder")
		decoder_running = false

	if not decoder_running:
		# Always call the codec-aware overload. We can't gate on
		# has_method("start_decoder_with_codec") because Godot 4's Kotlin-plugin
		# reflection does NOT populate has_method() for @UsedByGodot methods even
		# when they're perfectly callable — gating on a false reading would
		# silently downgrade HEVC streams to the AVC MediaCodec. The plugin ships
		# in the same APK as this script, so the 3-arg method is guaranteed
		# present and call-by-name dispatches correctly.
		var started := bool(_video_decoder.call("start_decoder_with_codec", width, height, codec))
		if not started:
			print("[LiveVideo] Warning: failed to start video decoder")
			return

	if decoder_size_changed or layout_changed or codec_changed:
		print("[LiveVideo] Video stream configured: %dx%d stereo=%s codec=%s" % [width, height, stereo, codec])


## Convenience API for projects that do not use Teleoperate-Anything feed dictionaries.
func configure_h264_stream(width: int, height: int, stereo: bool = false) -> void:
	configure_video_stream({
		"width": width,
		"height": height,
		"stereo": stereo,
	})


func _decoder_is_running() -> bool:
	if _video_decoder == null:
		return false
	# Try has_method() first; fall back to a direct call which works even
	# when reflection misses the @UsedByGodot binding.
	if _video_decoder.has_method("is_running"):
		return bool(_video_decoder.is_running())
	var result: Variant = _video_decoder.call("is_running")
	return bool(result) if result != null else false


func _decoder_call_void(method_name: String) -> void:
	if _video_decoder == null:
		return
	_video_decoder.call(method_name)


func _create_placeholder_texture() -> void:
	# Create a simple checkerboard placeholder texture.
	var img := Image.create(512, 256, false, Image.FORMAT_RGB8)

	# Fill with solid blue so the placeholder is unmistakably distinct
	# from any decoded video frame (which is RGB and won't be solid blue).
	for y in range(256):
		for x in range(512):
			img.set_pixel(x, y, Color(0.0, 0.2, 1.0))

	# Draw a center dividing line (stereo separator).
	for y in range(256):
		img.set_pixel(255, y, Color(0.3, 0.3, 0.4))
		img.set_pixel(256, y, Color(0.3, 0.3, 0.4))

	# Draw L/R markers for left/right eye regions.
	for i in range(-10, 11):
		# Left eye cross at (128, 128)
		if 128 + i >= 0 and 128 + i < 256:
			img.set_pixel(128 + i, 128, Color(0.4, 0.6, 0.4))
			img.set_pixel(128, 128 + i, Color(0.4, 0.6, 0.4))
		# Right eye cross at (384, 128)
		if 384 + i >= 0 and 384 + i < 512:
			img.set_pixel(384 + i, 128, Color(0.6, 0.4, 0.4))
			img.set_pixel(384, 128 + i, Color(0.6, 0.4, 0.4))

	_placeholder_texture = ImageTexture.create_from_image(img)


func _setup_material() -> void:
	if not _display_mesh:
		return

	# Load shader.
	var shader := load("res://addons/live_video/stereo_display.gdshader") as Shader
	if not shader:
		print("[LiveVideo] Warning: Could not load stereo_display.gdshader")
		return

	_shader_material = ShaderMaterial.new()
	_shader_material.shader = shader
	_shader_material.set_shader_parameter("video_texture", _placeholder_texture)
	_shader_material.set_shader_parameter("content_ratio", 0.5)
	_shader_material.set_shader_parameter("visible_ratio", 1.0)
	_shader_material.set_shader_parameter("opacity", 0.9)
	_shader_material.set_shader_parameter("stereo_layout", true)

	_display_mesh.material_override = _shader_material


func _ensure_video_decoder(width: int, height: int) -> bool:
	if not Engine.has_singleton(decoder_singleton_name):
		if not _video_decoder_warning_logged:
			print("[LiveVideo] Android video decoder plugin not available")
			_video_decoder_warning_logged = true
		return false

	var decoder := Engine.get_singleton(decoder_singleton_name)
	if not decoder:
		if not _video_decoder_warning_logged:
			print("[LiveVideo] Android video decoder singleton unavailable")
			_video_decoder_warning_logged = true
		return false

	_video_decoder = decoder

	if not _video_decoder_connected:
		# Decoder runs on a worker thread; defer callbacks to the main thread.
		_video_decoder.connect(
			"frame_ready",
			Callable(self, "_on_video_frame_ready"),
			CONNECT_DEFERRED
		)
		# Plan B: GPU YUV->RGB. Prefer this path; the RGBA frame_ready
		# signal stays connected as a fallback for the placeholder code.
		if _video_decoder.has_signal("yuv_frame_ready"):
			_video_decoder.connect(
				"yuv_frame_ready",
				Callable(self, "_on_video_yuv_frame_ready"),
				CONNECT_DEFERRED
			)
		_video_decoder.connect(
			"decoder_error",
			Callable(self, "_on_video_decoder_error"),
			CONNECT_DEFERRED
		)
		_video_decoder_connected = true

	return true


func _on_video_decoder_error(message: String) -> void:
	print("[LiveVideo] Video decoder error: %s" % message)


func _exit_tree() -> void:
	# The decoder is an Engine singleton, so it outlives this node. Dropping
	# the view on a mode switch would otherwise leave MediaCodec holding a
	# hardware decoder instance and keep our deferred callbacks wired to a
	# node that is no longer in the tree. Godot only auto-disconnects signals
	# when a node is *freed*, not when it merely leaves the tree, so release
	# both explicitly. _ensure_video_decoder() re-arms everything the next
	# time a stream is configured.
	_release_video_decoder()


func _release_video_decoder() -> void:
	if _video_decoder == null:
		return
	if _decoder_is_running():
		_decoder_call_void("stop_decoder")
	if _video_decoder_connected:
		_disconnect_decoder_signal("frame_ready", "_on_video_frame_ready")
		_disconnect_decoder_signal("yuv_frame_ready", "_on_video_yuv_frame_ready")
		_disconnect_decoder_signal("decoder_error", "_on_video_decoder_error")
		_video_decoder_connected = false
	_video_decoder = null
	# The next view to bind this singleton starts from an unbound shader.
	_ahb_bound_to_shader = false


func _disconnect_decoder_signal(signal_name: String, method_name: String) -> void:
	if _video_decoder == null or not _video_decoder.has_signal(signal_name):
		return
	var callable := Callable(self, method_name)
	if _video_decoder.is_connected(signal_name, callable):
		_video_decoder.disconnect(signal_name, callable)


var _frame_diag_count: int = 0
var _shader_video_bound_logged: bool = false

# Plan B: GPU YUV path. We keep three reusable ImageTextures (Y full
# size, U/V at half size) and call .update() each frame to push only
# the new pixels into the GPU. The fragment shader does the YUV->RGB.
var _y_texture: ImageTexture = null
var _u_texture: ImageTexture = null
var _v_texture: ImageTexture = null
# [plan C] Reusable Image objects so the per-frame call only does
# set_data() instead of allocating fresh Image instances.
var _y_image: Image = null
var _u_image: Image = null
var _v_image: Image = null
var _yuv_size: Vector2i = Vector2i.ZERO
var _yuv_path_logged: bool = false
# [opt 10] When libahb_decoder.so is loaded and Vulkan AHB import
# succeeds, this holds the AhbVideoTexture instance that the shader
# samples directly. Its underlying VkImage is rebound from the
# Kotlin decoder's HardwareBuffer every frame — zero CPU work in
# the GDScript path. Stays null on builds without the .so or when
# the import fails (e.g. GLES driver), in which case Plan B's
# 3-plane upload remains the active code path.
var _ahb_texture: Texture2D = null
var _ahb_bound_to_shader: bool = false


# [plan C] Throttle the per-frame Video latency log to ~1 Hz; print()
# to logcat is non-trivial (string format + JNI write) and at 30 fps
# was visible in flame graphs.
var _last_latency_log_ns: int = 0
# Per-second running stats so we can still see actual displayed fps
# even with the per-frame log throttled.
var _stats_window_start_ns: int = 0
var _stats_frame_count: int = 0
var _stats_total_ms: float = 0.0
var _stats_decode_ms: float = 0.0
var _stats_present_ms: float = 0.0


func _take_latest_ahb_packet(frame_count: int) -> Dictionary:
	if frame_count <= _last_ahb_frame_count:
		return _last_video_packet
	var delta: int = frame_count - _last_ahb_frame_count
	_last_ahb_frame_count = frame_count

	var packet: Dictionary = {}
	for i in range(delta):
		if _submitted_video_packets.is_empty():
			break
		packet = _submitted_video_packets.pop_front()

	return packet if not packet.is_empty() else _last_video_packet


func _on_video_yuv_frame_ready(
		width: int,
		height: int,
		decoded_ns: int,
		y_bytes: PackedByteArray,
		u_bytes: PackedByteArray,
		v_bytes: PackedByteArray,
	) -> void:
	# [opt 10] When the AHB zero-copy path is bound, the Kotlin
	# decoder skips emitting yuv_frame_ready in favour of calling
	# nativeImportAhb directly — but we keep this guard in case both
	# paths fire for a frame (e.g. during the initial swap window).
	# Just drop the planes; the AHB path already updated the texture.
	if _ahb_bound_to_shader:
		return
	if _video_decoder and not _decoder_is_running():
		return
	if width <= 0 or height <= 0:
		return
	if y_bytes.size() < width * height:
		print("[LiveVideo] YUV Y plane size mismatch: %d for %dx%d" % [y_bytes.size(), width, height])
		return
	var cw := width / 2
	var ch := height / 2
	if u_bytes.size() < cw * ch or v_bytes.size() < cw * ch:
		print("[LiveVideo] YUV UV plane size mismatch: u=%d v=%d for %dx%d" % [
			u_bytes.size(), v_bytes.size(), cw, ch,
		])
		return

	_frame_diag_count += 1

	# [plan C] Reuse the same Image instances across frames. set_data()
	# replaces the pixel bytes in place; the GPU upload that
	# ImageTexture.update() does next reads from the same Image. Saves
	# 3 allocations + 3 GC handles per frame at the cost of three
	# pre-allocated Image objects.
	var size := Vector2i(width, height)
	if _y_texture == null or _yuv_size != size:
		_y_image = Image.create_from_data(width, height, false, Image.FORMAT_L8, y_bytes)
		_u_image = Image.create_from_data(cw, ch, false, Image.FORMAT_L8, u_bytes)
		_v_image = Image.create_from_data(cw, ch, false, Image.FORMAT_L8, v_bytes)
		_y_texture = ImageTexture.create_from_image(_y_image)
		_u_texture = ImageTexture.create_from_image(_u_image)
		_v_texture = ImageTexture.create_from_image(_v_image)
		_yuv_size = size
	else:
		_y_image.set_data(width, height, false, Image.FORMAT_L8, y_bytes)
		_u_image.set_data(cw, ch, false, Image.FORMAT_L8, u_bytes)
		_v_image.set_data(cw, ch, false, Image.FORMAT_L8, v_bytes)
		_y_texture.update(_y_image)
		_u_texture.update(_u_image)
		_v_texture.update(_v_image)

	if not _shader_material:
		return

	# Switch shader to YUV mode and bind the three planes. The texture
	# parameters are set once on the first frame and re-bound only if
	# we re-allocated the textures (i.e. resolution changed) — saves 3
	# set_shader_parameter calls per frame.
	if not _yuv_path_logged:
		_shader_material.set_shader_parameter("use_yuv", true)
		_shader_material.set_shader_parameter("y_texture", _y_texture)
		_shader_material.set_shader_parameter("u_texture", _u_texture)
		_shader_material.set_shader_parameter("v_texture", _v_texture)
		_yuv_path_logged = true
		print("[LiveVideo] GPU YUV path active: %dx%d (chroma %dx%d)" % [width, height, cw, ch])
	elif _yuv_size != size:
		_shader_material.set_shader_parameter("y_texture", _y_texture)
		_shader_material.set_shader_parameter("u_texture", _u_texture)
		_shader_material.set_shader_parameter("v_texture", _v_texture)

	if _video_layout_stereo != _desired_stereo_layout:
		_apply_video_layout(_desired_stereo_layout)

	_receiving_video = true
	_presented_frame_count += 1

	# [plan C] Latency log was per-frame. At 30 fps that's 30
	# print()-to-logcat calls per second, each requiring a string
	# format pass. Throttle to ~1 Hz: emit only when we've crossed a
	# 1-second boundary, plus any latency outliers (>200 ms total).
	# Pop the matching submitted packet to keep the inflight queue
	# accurate.
	var packet: Dictionary = {}
	if not _submitted_video_packets.is_empty():
		packet = _submitted_video_packets.pop_front()
	elif not _last_video_packet.is_empty():
		packet = _last_video_packet
	if packet.is_empty():
		return

	_last_video_packet = packet
	if decoded_ns > 0:
		_last_video_packet["decoded_ns"] = decoded_ns
	var present_ns := VideoLatencyTracker.now_ns()
	_last_video_packet["present_ns"] = present_ns
	_record_local_latency(_last_video_packet, present_ns)

	# Update per-second running stats so we can summarise fps + median
	# latency even when the verbose per-frame log is throttled.
	if _stats_window_start_ns == 0:
		_stats_window_start_ns = present_ns
	_stats_frame_count += 1
	var receive_ns: int = int(_last_video_packet.get("receive_ns", 0))
	if receive_ns > 0 and present_ns >= receive_ns:
		_stats_total_ms += float(present_ns - receive_ns) / 1_000_000.0
	if decoded_ns > 0 and receive_ns > 0 and decoded_ns >= receive_ns:
		_stats_decode_ms += float(decoded_ns - receive_ns) / 1_000_000.0
	if decoded_ns > 0 and present_ns >= decoded_ns:
		_stats_present_ms += float(present_ns - decoded_ns) / 1_000_000.0

	var window_ns: int = present_ns - _stats_window_start_ns
	if window_ns >= 1_000_000_000:
		var window_s: float = float(window_ns) / 1_000_000_000.0
		var fps: float = float(_stats_frame_count) / window_s
		var avg_total: float = _stats_total_ms / float(_stats_frame_count)
		var avg_decode: float = _stats_decode_ms / float(_stats_frame_count)
		var avg_present: float = _stats_present_ms / float(_stats_frame_count)
		print("[LiveVideo] stats: %.1f fps  decode_avg=%.1f ms  present_avg=%.1f ms  total_avg=%.1f ms (n=%d in %.2fs)" % [
			fps, avg_decode, avg_present, avg_total, _stats_frame_count, window_s,
		])
		_stats_window_start_ns = present_ns
		_stats_frame_count = 0
		_stats_total_ms = 0.0
		_stats_decode_ms = 0.0
		_stats_present_ms = 0.0

	var should_log: bool = present_ns - _last_latency_log_ns >= 1_000_000_000
	if not should_log:
		if receive_ns > 0 and present_ns - receive_ns > 200_000_000:
			should_log = true
	if should_log:
		_last_latency_log_ns = present_ns
		print("[LiveVideo] Video latency: %s" % VideoLatencyTracker.format_packet(_last_video_packet, _clock_offset_ns, _clock_samples))


func _on_video_frame_ready(
		width: int = -1,
		height: int = -1,
		decoded_ns: int = 0,
		rgba: PackedByteArray = PackedByteArray()
	) -> void:
	if _video_decoder and not _decoder_is_running():
		return

	if width <= 0 or height <= 0 or rgba.is_empty():
		if _video_decoder == null:
			return
		var frame: Dictionary = _video_decoder.call("get_latest_frame")
		if frame.is_empty():
			return
		width = int(frame.get("width", 0))
		height = int(frame.get("height", 0))
		rgba = frame.get("rgba", PackedByteArray())
		decoded_ns = int(frame.get("decoded_ns", frame.get("timestamp_ns", 0)))

	if width <= 0 or height <= 0 or rgba.is_empty():
		return
	if rgba.size() != width * height * 4:
		print("[LiveVideo] Video frame size mismatch: %d bytes for %dx%d" % [rgba.size(), width, height])
		return

	# Diagnostic: every 60 frames sample pixels and dump mesh state.
	_frame_diag_count += 1
	if _frame_diag_count % 60 == 1:
		var sample_count := 16
		var r_sum := 0
		var g_sum := 0
		var b_sum := 0
		var step := maxi(4, (rgba.size() / 4 / sample_count) * 4)
		var taken := 0
		var off := 0
		while off + 2 < rgba.size() and taken < sample_count:
			r_sum += int(rgba[off])
			g_sum += int(rgba[off + 1])
			b_sum += int(rgba[off + 2])
			off += step
			taken += 1
		var t := maxi(1, taken)
		# First 4 RGBA bytes (one pixel) so we can tell if conversion is sane.
		var first_pixel := "[%d,%d,%d,%d]" % [
			int(rgba[0]) if rgba.size() > 0 else -1,
			int(rgba[1]) if rgba.size() > 1 else -1,
			int(rgba[2]) if rgba.size() > 2 else -1,
			int(rgba[3]) if rgba.size() > 3 else -1,
		]
		var mesh_visible: bool = _display_mesh != null and _display_mesh.is_visible_in_tree()
		var mat_ok: bool = _display_mesh != null and _display_mesh.material_override == _shader_material
		var mesh_pos: Vector3 = Vector3.ZERO
		if _display_mesh:
			mesh_pos = _display_mesh.global_transform.origin
		var bound_id: int = -1
		if _shader_material:
			var bound: Variant = _shader_material.get_shader_parameter("video_texture")
			if bound != null:
				bound_id = bound.get_instance_id()
		var ph_id: int = -1
		if _placeholder_texture:
			ph_id = _placeholder_texture.get_instance_id()
		var vid_id: int = -1
		if _video_texture:
			vid_id = _video_texture.get_instance_id()
		print("[LiveVideo] DIAG f=%d size=%dx%d avgRGB=(%d,%d,%d) px0=%s mesh=%s mat=%s pos=%s stereo=%s shader_bound=%d placeholder=%d video_tex=%d" % [
			_frame_diag_count, width, height,
			r_sum / t, g_sum / t, b_sum / t,
			first_pixel,
			mesh_visible, mat_ok, mesh_pos, _video_layout_stereo,
			bound_id, ph_id, vid_id,
		])

	var image := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, rgba)
	if image.get_width() <= 0 or image.get_height() <= 0:
		return

	# Diagnostic: dump every 120th decoded frame to disk so we can pull it
	# via adb and visually verify what the YUV->RGB conversion produced.
	if _frame_diag_count % 120 == 1:
		var path := "user://decoded_frame_%d.png" % _frame_diag_count
		var err := image.save_png(path)
		print("[LiveVideo] DIAG saved decoded frame to %s err=%d (= %s)" % [
			path, err, ProjectSettings.globalize_path(path),
		])

	var packet: Dictionary = _submitted_video_packets.pop_front() if not _submitted_video_packets.is_empty() else _last_video_packet
	update_video_texture(image, packet, decoded_ns)


## Update the video texture and print a full latency summary.
func update_video_texture(image: Image, packet: Dictionary = {}, decoded_ns: int = 0) -> void:
	if image.get_width() <= 0 or image.get_height() <= 0:
		return

	if not _shader_material:
		return

	if _video_layout_stereo != _desired_stereo_layout:
		_apply_video_layout(_desired_stereo_layout)

	var texture := _update_video_texture(image)
	if texture:
		# Switch shader back to the legacy RGBA branch — only matters
		# if Plan B's GPU YUV path was active and we now want to fall
		# back to a single-texture frame (e.g. placeholder).
		_shader_material.set_shader_parameter("use_yuv", false)
		_shader_material.set_shader_parameter("video_texture", texture)
		_receiving_video = true
		_presented_frame_count += 1
		# One-shot confirmation that the shader is actually sampling the
		# video texture, not the placeholder.
		if not _shader_video_bound_logged:
			var bound: Variant = _shader_material.get_shader_parameter("video_texture")
			print("[LiveVideo] First video texture bound: instance_id=%d size=%s placeholder_id=%d" % [
				bound.get_instance_id() if bound else -1,
				_video_texture_size,
				_placeholder_texture.get_instance_id() if _placeholder_texture else -1,
			])
			_shader_video_bound_logged = true

	var timing := packet if not packet.is_empty() else _last_video_packet
	if timing.is_empty():
		return

	_last_video_packet = timing.duplicate(true)
	if decoded_ns > 0:
		_last_video_packet["decoded_ns"] = decoded_ns
	elif int(_last_video_packet.get("decoded_ns", 0)) <= 0:
		_last_video_packet["decoded_ns"] = VideoLatencyTracker.now_ns()
	var present_ns := VideoLatencyTracker.now_ns()
	_last_video_packet["present_ns"] = present_ns
	_record_local_latency(_last_video_packet, present_ns)
	print("[LiveVideo] Video latency: %s" % VideoLatencyTracker.format_packet(_last_video_packet, _clock_offset_ns, _clock_samples))


func _update_video_texture(image: Image) -> ImageTexture:
	var size := Vector2i(image.get_width(), image.get_height())
	# In Godot 4 on mobile Vulkan, ImageTexture.update() can occasionally
	# fail to push new pixels to the GPU, which leaves the shader sampling
	# from the original placeholder. Recreating the texture each frame is
	# wasteful but reliable. Once we move to Surface-based decoding this
	# will go away.
	_video_texture = ImageTexture.create_from_image(image)
	_video_texture_size = size
	return _video_texture


func _apply_video_layout(stereo_layout: bool) -> void:
	_video_layout_stereo = stereo_layout
	if _shader_material:
		_shader_material.set_shader_parameter("stereo_layout", stereo_layout)
		_shader_material.set_shader_parameter("content_ratio", 0.5 if stereo_layout else 1.0)


## Hard cap on how many in-flight access-unit packets we remember.
##
## Tradeoff: small cap = honest low latency but visible frame drops
## when the GDScript main thread is busy; big cap = no drops but the
## queue lag dominates `decode=` and total end-to-end latency.
##
## We chose 3:
##   - cap=3 measured: decode median 50 ms, total 100 ms, ~19 fps shown
##   - cap=12 measured: decode median 340 ms, total 400 ms, ~25 fps shown
## For a teleoperation use case we'd rather drop the occasional frame
## than show a noticeably-old one. The stale-NAL guard from [opt 2]
## already discards anything older than 100 ms upstream of this queue.
##
## If the dropped-frame perception is the dominant complaint, the
## right fix is to remove the deferred-callback bottleneck (e.g. the
## item 10 AHB import path), not to enlarge this queue.
# Metadata queue used to correlate decoder output with packet timestamps.
# MediaCodec can report a sizeable output delay, so keep a few seconds of
# packet timing metadata. This does not queue video frames in GDScript.
const MAX_INFLIGHT_PACKETS: int = 96


## Inspect an Annex-B access unit and return true if it contains a NAL the
## decoder must not lose: for H.264 an IDR (5), SPS (7) or PPS (8); for HEVC an
## IRAP slice (16..21) or VPS (32) / SPS (33) / PPS (34). We never drop those
## even if they're "old".
func _access_unit_has_keyframe(access_unit: PackedByteArray) -> bool:
	# Annex B: NAL units are separated by 0x00 00 00 01 (or 0x00 00 01). The
	# byte(s) after the start code are the NAL header. H.264 puts the type in
	# the low 5 bits of byte 0; HEVC's header is 2 bytes and the type is bits
	# 6..1 of byte 0 ((byte >> 1) & 0x3F).
	var hevc := _configured_codec == "hevc"
	var n := access_unit.size()
	if n < 5:
		return false
	var i := 0
	while i + 4 < n:
		var is_4byte := access_unit[i] == 0 and access_unit[i + 1] == 0 \
				and access_unit[i + 2] == 0 and access_unit[i + 3] == 1
		var is_3byte := access_unit[i] == 0 and access_unit[i + 1] == 0 \
				and access_unit[i + 2] == 1
		if is_4byte:
			if _is_key_nal(access_unit[i + 4], hevc):
				return true
			i += 4
		elif is_3byte:
			if _is_key_nal(access_unit[i + 3], hevc):
				return true
			i += 3
		else:
			i += 1
	return false


## True if the NAL header byte names a must-keep NAL for the given codec.
func _is_key_nal(header_byte: int, hevc: bool) -> bool:
	if hevc:
		var t: int = (header_byte >> 1) & 0x3F
		# IRAP slices (BLA/IDR/CRA = 16..21) + VPS/SPS/PPS (32/33/34).
		return (t >= 16 and t <= 21) or t == 32 or t == 33 or t == 34
	var nal_type: int = header_byte & 0x1F
	return nal_type == 5 or nal_type == 7 or nal_type == 8


func _submit_video_access_unit(access_unit: PackedByteArray, packet: Dictionary) -> bool:
	if access_unit.is_empty():
		return false
	if _video_decoder == null:
		return false
	if not _decoder_is_running():
		return false

	# Evict oldest entries before adding the new one. We must keep the
	# total count strictly below MAX_INFLIGHT_PACKETS-1 so that after the
	# append we are at the cap, not over.
	while _submitted_video_packets.size() >= MAX_INFLIGHT_PACKETS:
		_submitted_video_packets.pop_front()

	# [plan C] Don't deep-copy the packet — we hand a reference into the
	# inflight queue. The caller (report_video_packet) mints a fresh
	# packet Dictionary per NAL it receives, so the only way the
	# reference here could be mutated externally is if some other code
	# kept its own reference and rewrote it, which we don't do.
	_submitted_video_packets.append(packet)
	# Use call() to avoid relying on Godot's reflection of @UsedByGodot methods.
	var receive_ns: int = int(packet.get("receive_ns", 0))
	var send_ns: int = int(packet.get("send_ns", 0))
	var accepted := bool(_video_decoder.call(
		"submit_access_unit_timed_with_clock",
		access_unit,
		receive_ns,
		send_ns,
		_clock_offset_ns,
		_clock_samples,
	))
	if accepted:
		return true

	_submitted_video_packets.pop_back()
	return false


## Submit one complete Annex-B H.264 access unit from any source.
## The optional packet dictionary may include timing fields used by the HUD.
func submit_h264_access_unit(access_unit: PackedByteArray, packet: Dictionary = {}) -> bool:
	if access_unit.is_empty():
		return false
	if packet.is_empty():
		packet = {
			"frame_id": -1,
			"nal_index": 0,
			"nal_count": 1,
			"receive_ns": VideoLatencyTracker.now_ns(),
			"nal_data": access_unit,
		}
	elif not packet.has("receive_ns"):
		packet = packet.duplicate(true)
		packet["receive_ns"] = VideoLatencyTracker.now_ns()

	_last_video_packet = packet
	return _submit_video_access_unit(access_unit, packet)


## Skip non-keyframe access units that are already this many ms behind
## by the time the access unit is fully reassembled. Bounds the
## end-to-end latency upper bound: any pipeline stall (Wi-Fi reconnect,
## GC pause, app backgrounding) gets discarded instead of decoded.
const STALE_NAL_BUDGET_MS: int = 100

# Stats so we can spot stale-drop patterns from the latency log.
var _stale_dropped_count: int = 0
var _stale_dropped_log_at: int = 0
# Frames the decoder couldn't accept (queue full / not running). Surfaced
# on the HUD next to stale drops so we can tell a hot Wi-Fi link
# (UDP reassembly drops) from a CPU-starved decoder (queue full).
var _decoder_busy_count: int = 0


## Report a received video packet before decoding.
func report_video_packet(packet: Dictionary) -> void:
	if packet.is_empty():
		return

	_last_video_packet = packet.duplicate(true)

	var nal_index: int = int(_last_video_packet.get("nal_index", 0))
	var nal_count: int = int(_last_video_packet.get("nal_count", 1))
	var nal_data: PackedByteArray = _last_video_packet.get("nal_data", PackedByteArray())

	if nal_index == 0:
		_pending_access_unit = PackedByteArray()

	_pending_access_unit.append_array(nal_data)
	if nal_index + 1 < nal_count:
		return

	var access_unit := _pending_access_unit
	_pending_access_unit = PackedByteArray()

	# Stale-drop guard. The receive timestamp on the packet was stamped
	# in tcp_handler when the bytes came off the socket. If reassembly +
	# scheduling has already burned more than STALE_NAL_BUDGET_MS we
	# would just be making the latency worse by feeding the decoder.
	# Exception: keyframes (NAL type 5) are kept regardless because
	# without an IDR the H.264 decoder cannot recover from a drop.
	var receive_ns: int = int(_last_video_packet.get("receive_ns", 0))
	if receive_ns > 0 and not _access_unit_has_keyframe(access_unit):
		var age_ms: float = float(VideoLatencyTracker.now_ns() - receive_ns) / 1_000_000.0
		if age_ms > float(STALE_NAL_BUDGET_MS):
			_stale_dropped_count += 1
			# Log at most every 30 drops so we don't drown the latency
			# stream but can still see the rate.
			if _stale_dropped_count - _stale_dropped_log_at >= 30:
				_stale_dropped_log_at = _stale_dropped_count
				print("[LiveVideo] stale-NAL drops: %d total, latest age=%.1f ms (frame %d)" % [
					_stale_dropped_count, age_ms, int(_last_video_packet.get("frame_id", -1)),
				])
			return

	var decoder_running := _decoder_is_running()

	if _submit_video_access_unit(access_unit, _last_video_packet):
		return

	if _video_decoder and decoder_running:
		_decoder_busy_count += 1
		print("[LiveVideo] Video decoder busy, dropping frame %d" % int(_last_video_packet.get("frame_id", -1)))
		return

	# If no decoder is available, keep the old latency logging path.
	if int(_last_video_packet.get("decoded_ns", 0)) <= 0:
		_last_video_packet["decoded_ns"] = VideoLatencyTracker.now_ns()
	_last_video_packet["present_ns"] = VideoLatencyTracker.now_ns()
	print("[LiveVideo] Video latency: %s" % VideoLatencyTracker.format_packet(_last_video_packet, _clock_offset_ns, _clock_samples))


## Backward-compatible alias used by older hooks.
func report_video_frame(packet: Dictionary) -> void:
	report_video_packet(packet)


## Clear decoder state and restore the placeholder texture.
func clear_video_stream() -> void:
	_pending_access_unit = PackedByteArray()
	_submitted_video_packets.clear()
	_last_ahb_frame_count = 0
	_display_fps = 0.0
	_fps_sample_ns = 0
	_fps_sample_frames = 0
	_presented_frame_count = 0
	_smoothed_local_latency_ms = -1.0
	_stale_dropped_count = 0
	_stale_dropped_log_at = 0
	_decoder_busy_count = 0
	_last_video_packet.clear()
	_receiving_video = false
	_configured_width = 0
	_configured_height = 0
	_configured_codec = "h264"
	_desired_stereo_layout = true
	_apply_video_layout(true)
	_video_texture = null
	_video_texture_size = Vector2i.ZERO
	# Plan B: drop the GPU YUV textures so a future stream rebuilds them.
	_y_texture = null
	_u_texture = null
	_v_texture = null
	_yuv_size = Vector2i.ZERO
	_yuv_path_logged = false
	# The shader parameter below is reset to the placeholder, so the AHB
	# texture is no longer what the panel samples -- drop the bound flag to
	# match. Leaving it true wedges the view permanently: _process() only
	# rebinds the AHB texture while `not _ahb_bound_to_shader`, and
	# _on_video_yuv_frame_ready() returns early while it is true, so after any
	# disconnect/reconnect neither the zero-copy path nor the Plan B YUV
	# fallback could ever draw again and the panel would stay on placeholder.
	_ahb_bound_to_shader = false

	if _video_decoder:
		_decoder_call_void("stop_decoder")

	if _shader_material and _placeholder_texture:
		_shader_material.set_shader_parameter("use_yuv", false)
		_shader_material.set_shader_parameter("video_texture", _placeholder_texture)
	_update_panel_visibility()


## Set the content ratio (how much of width each eye uses).
func set_content_ratio(ratio: float) -> void:
	if _shader_material:
		_shader_material.set_shader_parameter("content_ratio", ratio)


## Set the visible ratio (for border cropping).
func set_visible_ratio(ratio: float) -> void:
	if _shader_material:
		_shader_material.set_shader_parameter("visible_ratio", ratio)


## Set display opacity.
func set_opacity(value: float) -> void:
	if _shader_material:
		_shader_material.set_shader_parameter("opacity", value)


## Check if display is receiving video.
func is_receiving_video() -> bool:
	return _receiving_video
