class_name MjDatasetValidator
extends RefCounted

const REQUIRED_OBSERVATION_KEYS := ["state", "rgb", "depth", "segmentation", "contact", "force"]


static func validate_episode(path: String, min_frames := 1, require_native := false) -> Dictionary:
	var data_path := "%s/data.jsonl" % path
	var metadata_path := "%s/metadata.json" % path
	var summary_path := "%s/summary.json" % path
	var errors: Array[String] = []
	var warnings: Array[String] = []
	var metadata := _read_json_file(metadata_path)
	var summary := _read_json_file(summary_path)
	if metadata.is_empty():
		errors.append("missing or invalid metadata.json")
	if summary.is_empty():
		errors.append("missing or invalid summary.json")
	if require_native:
		var native_status: Dictionary = metadata.get("native_status", {})
		if not bool(native_status.get("loaded", false)):
			errors.append("native_status.loaded is not true")
	var file := FileAccess.open(data_path, FileAccess.READ)
	if file == null:
		errors.append("missing data.jsonl")
		return _result(path, false, 0, errors, warnings, metadata, summary)
	var rows := 0
	var previous_frame := -1
	var previous_timestamp := -1
	var previous_step := -1
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty():
			continue
		var parsed = JSON.parse_string(line)
		if typeof(parsed) != TYPE_DICTIONARY:
			errors.append("row %d is not a dictionary" % rows)
			continue
		var frame_index := int(parsed.get("frame_index", -1))
		var timestamp := int(parsed.get("timestamp", -1))
		var simulation: Dictionary = parsed.get("simulation", {})
		var step_index := int(simulation.get("step_index", -1))
		if frame_index != rows:
			errors.append("row %d frame_index=%d" % [rows, frame_index])
		if previous_timestamp >= 0 and timestamp < previous_timestamp:
			errors.append("timestamp moved backwards at row %d" % rows)
		if previous_step >= 0 and step_index < previous_step:
			errors.append("simulation step moved backwards at row %d" % rows)
		var observation: Dictionary = parsed.get("observation", {})
		for key in REQUIRED_OBSERVATION_KEYS:
			if not observation.has(key):
				errors.append("row %d missing observation.%s" % [rows, key])
		if not parsed.has("action"):
			errors.append("row %d missing action" % rows)
		previous_frame = frame_index
		previous_timestamp = timestamp
		previous_step = step_index
		rows += 1
	if rows < min_frames:
		errors.append("only %d frames; expected at least %d" % [rows, min_frames])
	if int(summary.get("frames", rows)) != rows:
		warnings.append("summary.frames=%d but data rows=%d" % [int(summary.get("frames", -1)), rows])
	return _result(path, errors.is_empty(), rows, errors, warnings, metadata, summary)


static func replay_episode(path: String, max_frames := 0) -> Dictionary:
	var data_path := "%s/data.jsonl" % path
	var file := FileAccess.open(data_path, FileAccess.READ)
	if file == null:
		return {"ok": false, "frames": 0, "error": "missing data.jsonl"}
	var frames := 0
	var first_step := -1
	var last_step := -1
	var last_action := {}
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty():
			continue
		var parsed = JSON.parse_string(line)
		if typeof(parsed) != TYPE_DICTIONARY:
			return {"ok": false, "frames": frames, "error": "invalid row"}
		var simulation: Dictionary = parsed.get("simulation", {})
		var step_index := int(simulation.get("step_index", -1))
		if first_step < 0:
			first_step = step_index
		last_step = step_index
		last_action = parsed.get("action", {})
		frames += 1
		if max_frames > 0 and frames >= max_frames:
			break
	return {"ok": frames > 0, "frames": frames, "first_step": first_step, "last_step": last_step, "last_action": last_action}


static func _read_json_file(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


static func _result(path: String, ok: bool, frames: int, errors: Array[String], warnings: Array[String], metadata: Dictionary, summary: Dictionary) -> Dictionary:
	return {
		"ok": ok,
		"path": ProjectSettings.globalize_path(path),
		"frames": frames,
		"errors": errors,
		"warnings": warnings,
		"metadata": metadata,
		"summary": summary,
	}
