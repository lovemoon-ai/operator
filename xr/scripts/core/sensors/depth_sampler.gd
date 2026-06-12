extends Node
class_name DepthSampler

@export var request_interval_sec := 0.2

var writer: Object
# WP4: canonical-frame sink (default: FrameWriterShim over `writer`).
var _frame_sink: Object
var _extension: Object
var _timer := 0.0
var _started := false
var _request_pending := false
var _xr_time_offset_ns := 0
var _xr_time_offset_resolved := false
var _callback_count := 0
var _frame_count := 0
var _callback_us := 0
var _convert_us := 0
var _native_convert_plugin: Object
var _native_convert_checked := false
var _capture_provider: Object
var _platform: Object
var _extension_name := ""
var _drop_count := 0
var _last_drop_reason := ""
var _empty_callback_count := 0
var _non_dictionary_count := 0
var _missing_image_count := 0
var _null_image_count := 0
var _empty_conversion_count := 0


func pop_metrics() -> Dictionary:
	var metrics := {
		"callbacks": _callback_count,
		"frames": _frame_count,
		"callback_ms": _callback_us / 1000.0,
		"convert_ms": _convert_us / 1000.0,
		"drops": _drop_count,
		"last_drop": _last_drop_reason
	}
	_callback_count = 0
	_frame_count = 0
	_callback_us = 0
	_convert_us = 0
	_drop_count = 0
	_last_drop_reason = ""
	return metrics


func configure(p_writer: Object, p_capture_provider: Object = null, p_platform: Object = null) -> void:
	writer = p_writer
	_frame_sink = FrameWriterShim.new(writer) if writer != null else null
	_capture_provider = p_capture_provider
	# WP2: vendor singleton probing moved to the platform layer (same probe
	# order as before — see QuestPlatformAdapter.DEPTH_SINGLETONS).
	_platform = p_platform if p_platform != null else PlatformRegistry.shared()
	var info: Dictionary = _platform.depth_extension_info()
	if not info.is_empty():
		_extension = info.get("extension")
		_extension_name = str(info.get("name", ""))
		print("DepthSampler bound %s" % _extension_name)


func set_frame_sink(sink: Object) -> void:
	_frame_sink = sink


func _resolve_xr_time_offset_ns() -> int:
	if _xr_time_offset_resolved:
		return _xr_time_offset_ns
	var plugin := _capture_provider
	if plugin == null and _platform != null:
		plugin = _platform.fallback_capture_provider()
	if plugin == null:
		return 0
	# Skip `has_method()` checks here: Godot's Android singleton wrapper does
	# not always reflect Kotlin `@UsedByGodot` methods through `has_method`,
	# even though `plugin.call(...)` invokes them just fine. Call directly and
	# fall back to 0 if the bridge returns null. Only cache once we get a
	# non-zero offset back, because the plugin returns 0 before its
	# `configureSessionInternal` has captured the clock anchors.
	var raw: Variant = plugin.call("getXrTimeToGodotTicksOffsetNs")
	if raw == null:
		return 0
	var value := int(raw)
	if value == 0:
		return 0
	_xr_time_offset_ns = value
	_xr_time_offset_resolved = true
	print("DepthSampler resolved XR time offset (ns): %d" % value)
	return _xr_time_offset_ns


func start() -> void:
	if _extension == null or _started:
		return

	var supported := bool(_extension.call("is_environment_depth_supported"))
	if supported:
		_timer = 0.0
		_extension.call("start_environment_depth")
		_started = true
		print("DepthSampler started %s" % _extension_name)
	else:
		_mark_drop("unsupported", {"extension": _extension_name})


func stop() -> void:
	if _extension == null or not _started:
		return

	if _extension.call("is_environment_depth_started"):
		_extension.call("stop_environment_depth")
	_started = false


func pump(delta: float) -> void:
	if _frame_sink == null or _extension == null or not _started or _request_pending:
		return

	if not _extension.has_method("get_environment_depth_map_async"):
		_mark_drop("missing_async_api", {"extension": _extension_name})
		return

	_timer += delta
	if _timer < request_interval_sec:
		return

	_timer = 0.0
	_request_pending = true
	_extension.call("get_environment_depth_map_async", Callable(self, "_on_depth_map"))


func _on_depth_map(data: Array) -> void:
	_request_pending = false
	if _frame_sink == null or not _started:
		return

	var cb_start := Time.get_ticks_usec()
	_callback_count += 1
	var callback_ticks_ns := cb_start * 1000
	if data.is_empty():
		_empty_callback_count += 1
		_mark_drop("empty_callback", {"count": _empty_callback_count})
		_callback_us += Time.get_ticks_usec() - cb_start
		return

	for i in range(data.size()):
		if not (data[i] is Dictionary):
			_non_dictionary_count += 1
			_mark_drop("non_dictionary_item", {"index": i, "count": _non_dictionary_count})
			continue
		var item: Dictionary = data[i]
		if not item.has("image"):
			_missing_image_count += 1
			_mark_drop("missing_image", {"index": i, "keys": item.keys(), "count": _missing_image_count})
			continue

		var image := item["image"] as Image
		if image == null:
			_null_image_count += 1
			_mark_drop("null_image", {"index": i, "keys": item.keys(), "count": _null_image_count})
			continue

		var eye := "left" if i == 0 else "right"
		if eye != "left":
			continue

		# Prefer the OpenXR runtime display time when the patched Vendors
		# wrapper exposes it. Quest's XR runtime returns XrTime in
		# CLOCK_MONOTONIC nanoseconds, which is the same clock as
		# Time.get_ticks_usec(), so we can place it directly into the Godot
		# ticks domain used by RGB and pose. Fall back to the callback time
		# otherwise so the stream is still usable on unpatched builds.
		var runtime_display_variant: Variant = _nonnegative_int_or_null(item.get("runtime_display_time_ns"))
		var timestamp_ns: int = callback_ticks_ns
		var timestamp_source: String = "godot_async_callback_ticks"
		if runtime_display_variant != null and int(runtime_display_variant) > 0:
			# OpenXR XrTime is CLOCK_MONOTONIC ns since boot; Godot ticks ns is
			# measured from process start. Apply the Android plugin's captured
			# offset so the depth PTS sits in the same domain as RGB and pose.
			timestamp_ns = int(runtime_display_variant) + _resolve_xr_time_offset_ns()
			timestamp_source = "openxr_runtime_display_time"
		var metadata := {
			"source": "XR_META_environment_depth",
			"timestamp_source": timestamp_source,
			"timestamp_ns": timestamp_ns,
			"callback_godot_ticks_ns": callback_ticks_ns,
			"image_format": image.get_format(),
			"sample_storage": _depth_sample_storage(image.get_format()),
			"depth_encoding": "openxr_window_depth_normalized",
			"depth_metric_conversion": "inverse_projection_view",
			"depth_projection_view_columns": _projection_to_columns(item.get("depth_projection_view")),
			"depth_inverse_projection_view_columns": _projection_to_columns(item.get("depth_inverse_projection_view")),
			"near_z": _finite_float_or_null(item.get("near_z")),
			"far_z": _finite_float_or_null(item.get("far_z")),
			"runtime_display_time_ns": runtime_display_variant,
			"fov_tangent": _fov_tangent_record(item),
			"local_from_depth_eye": _transform_to_record(item.get("local_from_depth_eye"))
		}
		var convert_start := Time.get_ticks_usec()
		var depth_u16_mm: PackedByteArray = _convert_with_native_or_fallback(image, metadata)
		_convert_us += Time.get_ticks_usec() - convert_start
		if depth_u16_mm.is_empty():
			_empty_conversion_count += 1
			_mark_drop("empty_conversion", {
				"format": image.get_format(),
				"width": image.get_width(),
				"height": image.get_height(),
				"count": _empty_conversion_count
			})
			continue
		_frame_sink.on_frame(DepthFrame.build(timestamp_ns, eye, image.get_width(), image.get_height(), metadata, depth_u16_mm))
		_frame_count += 1
	_callback_us += Time.get_ticks_usec() - cb_start


func _mark_drop(reason: String, details: Dictionary = {}) -> void:
	_drop_count += 1
	_last_drop_reason = reason
	if _drop_count <= 3 or _drop_count % 30 == 0:
		print("DepthSampler drop: %s %s" % [reason, JSON.stringify(details)])


func _store_image_bytes(path: String, image: Image) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_buffer(image.get_data())
		file.close()


func _resolve_native_convert_plugin() -> Object:
	if _native_convert_checked:
		return _native_convert_plugin
	_native_convert_checked = true
	if _capture_provider != null:
		_native_convert_plugin = _capture_provider
	elif _platform != null:
		var plugin: Object = _platform.fallback_capture_provider()
		if plugin != null:
			_native_convert_plugin = plugin
	return _native_convert_plugin


func _convert_with_native_or_fallback(image: Image, metadata: Dictionary) -> PackedByteArray:
	# Prefer the Kotlin implementation (JVM primitives, ~100× faster than the
	# GDScript inner loop). Without it depth conversion alone consumes
	# 750-950 ms of main-thread CPU per second on Quest 3, which strangles
	# the XR render rate. The Kotlin path needs the inverse-projection-view
	# row 3 and the format must be FORMAT_RH (the OpenXR D16 swapchain).
	if image.get_format() == Image.FORMAT_RH:
		var plugin := _resolve_native_convert_plugin()
		if plugin != null:
			var rows: Array = _projection_rows_from_columns(metadata.get("depth_inverse_projection_view_columns", []))
			if rows.size() == 4:
				var row3: Array = rows[3]
				var packed_row := PackedFloat64Array()
				packed_row.resize(4)
				for k in range(4):
					packed_row[k] = float(row3[k])
				var result: Variant = plugin.call(
					"convertOpenxrDepthRhToU16Mm",
					image.get_data(),
					image.get_width(),
					image.get_height(),
					packed_row
				)
				if result is PackedByteArray and (result as PackedByteArray).size() > 0:
					return result
	return _convert_openxr_depth_to_u16_mm(image, metadata)


func _convert_openxr_depth_to_u16_mm(image: Image, metadata: Dictionary) -> PackedByteArray:
	if image.get_format() != Image.FORMAT_RH:
		push_warning("Unsupported depth image format for live raw1 conversion: %s" % image.get_format())
		return PackedByteArray()
	var width: int = image.get_width()
	var height: int = image.get_height()
	if width <= 0 or height <= 0:
		return PackedByteArray()
	var raw: PackedByteArray = image.get_data()
	if raw.size() < width * height * 2:
		push_warning("Depth payload is shorter than expected: %d < %d" % [raw.size(), width * height * 2])
		return PackedByteArray()

	var inverse_rows: Array = _projection_rows_from_columns(metadata.get("depth_inverse_projection_view_columns", []))
	var near_z: Variant = metadata.get("near_z")
	var far_z: Variant = metadata.get("far_z")
	if inverse_rows.is_empty() and near_z == null:
		push_warning("Depth frame has no inverse projection-view matrix or near/far planes.")
		return PackedByteArray()

	var out := PackedByteArray()
	out.resize(width * height * 2)
	for index in range(width * height):
		var raw_offset: int = index * 2
		var normalized: float = float(int(raw[raw_offset]) | (int(raw[raw_offset + 1]) << 8)) / 65535.0
		var meters := 0.0
		if is_finite(normalized) and normalized >= 0.0 and normalized <= 1.0:
			if not inverse_rows.is_empty():
				var x: int = index % width
				var y: int = int(index / width)
				var clip := [
					2.0 * ((float(x) + 0.5) / float(width)) - 1.0,
					2.0 * ((float(y) + 0.5) / float(height)) - 1.0,
					2.0 * normalized - 1.0,
					1.0
				]
				var row: Array = inverse_rows[3]
				var homogeneous_w: float = float(row[0]) * float(clip[0]) + float(row[1]) * float(clip[1]) + float(row[2]) * float(clip[2]) + float(row[3]) * float(clip[3])
				meters = 1.0 / homogeneous_w if homogeneous_w > 0.0 else 0.0
			else:
				meters = _openxr_window_depth_to_linear_z(normalized, float(near_z), far_z)
		var mm := 0
		if is_finite(meters) and meters > 0.0:
			mm = int(clampf(round(meters * 1000.0), 0.0, 65535.0))
		out[raw_offset] = mm & 0xff
		out[raw_offset + 1] = (mm >> 8) & 0xff
	return out


func _projection_rows_from_columns(columns: Variant) -> Array:
	if not columns is Array or columns.size() != 4:
		return []
	for column in columns:
		if not column is Array or column.size() != 4:
			return []
	var rows := []
	for row in range(4):
		rows.append([
			float(columns[0][row]),
			float(columns[1][row]),
			float(columns[2][row]),
			float(columns[3][row])
		])
	return rows


func _openxr_window_depth_to_linear_z(window_depth: float, near_z: float, far_z_value: Variant) -> float:
	if not is_finite(near_z) or near_z <= 0.0:
		return 0.0
	var x := 0.0
	var y := 0.0
	if far_z_value == null or not is_finite(float(far_z_value)) or float(far_z_value) < near_z:
		x = -2.0 * near_z
		y = -1.0
	elif float(far_z_value) == near_z:
		return 0.0
	else:
		var far_z := float(far_z_value)
		x = -2.0 * far_z * near_z / (far_z - near_z)
		y = -(far_z + near_z) / (far_z - near_z)
	var denominator := 2.0 * window_depth - 1.0 + y
	return x / denominator if denominator != 0.0 else 0.0


func _projection_to_columns(value: Variant) -> Array:
	if not value is Projection:
		return []

	var projection: Projection = value
	var columns := [
		_vector4_to_array(projection.x),
		_vector4_to_array(projection.y),
		_vector4_to_array(projection.z),
		_vector4_to_array(projection.w)
	]
	return columns if _all_finite(columns) else []


func _vector4_to_array(value: Vector4) -> Array:
	return [value.x, value.y, value.z, value.w]


func _depth_sample_storage(format: Image.Format) -> String:
	if format == Image.FORMAT_RH:
		# XR_META_environment_depth exposes a D16_UNORM swapchain. Godot
		# represents its single-channel payload as FORMAT_RH, but the copied
		# bytes remain normalized uint16 samples rather than IEEE half floats.
		return "u16_unorm_le"
	if format == Image.FORMAT_RF:
		return "f32_le"
	return "unsupported_image_format_%d" % format


func _fov_tangent_record(item: Dictionary) -> Dictionary:
	for key in ["fov_angle_left", "fov_angle_right", "fov_angle_up", "fov_angle_down"]:
		if not item.has(key) or _finite_float_or_null(item[key]) == null:
			return {}
	var tangent := {
		"left": abs(tan(float(item["fov_angle_left"]))),
		"right": abs(tan(float(item["fov_angle_right"]))),
		"top": abs(tan(float(item["fov_angle_up"]))),
		"bottom": abs(tan(float(item["fov_angle_down"])))
	}
	if not _all_finite(tangent.values()):
		return {}
	return tangent


func _transform_to_record(value: Variant) -> Dictionary:
	if not value is Transform3D:
		return {}
	var transform: Transform3D = value
	if not _transform_is_finite(transform):
		return {}
	var q := transform.basis.get_rotation_quaternion()
	var p := transform.origin
	if not _all_finite([p.x, p.y, p.z, q.x, q.y, q.z, q.w]):
		return {}
	return {
		"position": {"x": p.x, "y": p.y, "z": p.z},
		"rotation": {"x": q.x, "y": q.y, "z": q.z, "w": q.w}
	}


func _transform_is_finite(transform: Transform3D) -> bool:
	return _all_finite([
		transform.origin.x,
		transform.origin.y,
		transform.origin.z,
		transform.basis.x.x,
		transform.basis.x.y,
		transform.basis.x.z,
		transform.basis.y.x,
		transform.basis.y.y,
		transform.basis.y.z,
		transform.basis.z.x,
		transform.basis.z.y,
		transform.basis.z.z
	])


func _finite_float_or_null(value: Variant) -> Variant:
	if value == null:
		return null
	var number := float(value)
	return number if is_finite(number) else null


func _nonnegative_int_or_null(value: Variant) -> Variant:
	if value == null:
		return null
	var number := int(value)
	return number if number >= 0 else null


func _all_finite(values: Array) -> bool:
	for value in values:
		if value is Array:
			if not _all_finite(value):
				return false
		elif not is_finite(float(value)):
			return false
	return true
