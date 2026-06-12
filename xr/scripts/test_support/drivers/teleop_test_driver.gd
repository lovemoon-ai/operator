class_name TeleopTestDriver
extends ModuleTestDriver
## v2 test harness (WP7): automation driver for core/teleop. Wraps the real
## ControlMode mapper plus a FakeTrackingProvider and FakeRobotControlSink:
## commands inject synthetic input, step() collects a DeviceCommand through
## the production mapping code and stores it in the fake sink.
##
## Commands: load_descriptor, inject_controller_input, inject_pose_frame.
## Snapshot: last emitted command frame + descriptor diagnostics.

var control_mode: ControlMode
var tracking: FakeTrackingProvider
var sink: FakeRobotControlSink
var descriptor_errors: Array = []
var _descriptor_loaded := false


func module_id() -> String:
	return "core/teleop"


func supported_cases() -> Array:
	return ["descriptor_mapping", "command_output", "latest_only"]


## Fixture: a DeviceDescriptor document (optionally wrapped in
## {"descriptor": {...}}), e.g. fixtures/teleop/fake_robot_descriptor_so101.
func setup(fixture: Dictionary) -> Dictionary:
	control_mode = ControlMode.new()
	tracking = FakeTrackingProvider.new()
	sink = FakeRobotControlSink.new()
	_descriptor_loaded = false
	descriptor_errors = []
	if not fixture.is_empty():
		return command("load_descriptor", {"descriptor": fixture.get("descriptor", fixture)})
	return {"ok": true}


func command(name: String, args: Dictionary = {}) -> Dictionary:
	match name:
		"load_descriptor":
			var descriptor_v: Variant = args.get("descriptor", {})
			if typeof(descriptor_v) != TYPE_DICTIONARY:
				return {"ok": false, "error": "descriptor must be a dictionary"}
			var parsed := DeviceDescriptorContract.parse(descriptor_v as Dictionary)
			descriptor_errors = parsed.get("errors", [])
			control_mode.configure(parsed.get("descriptor", {}))
			_descriptor_loaded = true
			return {"ok": descriptor_errors.is_empty(), "errors": descriptor_errors}
		"inject_controller_input":
			var hand := _hand_index(args)
			tracking.set_controller_input(hand, args.get("input", {}))
			return {"ok": true}
		"inject_pose_frame":
			if args.has("head_pose"):
				tracking.set_head_pose(args.get("head_pose", {}))
			var hand_pose_v: Variant = args.get("controller_pose")
			if typeof(hand_pose_v) == TYPE_DICTIONARY:
				tracking.set_controller_pose(_hand_index(args), hand_pose_v as Dictionary)
			return {"ok": true}
	return {"ok": false, "error": "unknown command '%s'" % name}


## One step = one teleop tick: map the current synthetic tracking state to a
## DeviceCommand and store it in the fake sink (latest-only).
func step(_delta_s: float, ticks: int = 1) -> Dictionary:
	if not _descriptor_loaded:
		return {"ok": false, "error": "no descriptor loaded"}
	var cmd: Dictionary = {}
	for i in range(ticks):
		cmd = control_mode.collect_command(tracking)
		sink.emit_command(cmd)
	return {"ok": true, "command": cmd}


func snapshot() -> Dictionary:
	return {
		"descriptor_loaded": _descriptor_loaded,
		"descriptor_errors": descriptor_errors.duplicate(),
		"last_command": sink.latest_command.duplicate(true),
		"commands_emitted": sink.commands.size(),
	}


func assert_invariants() -> Array:
	var out: Array = []
	# Teleop command output never references unmapped controls: every axis /
	# button key in emitted commands must come from the descriptor mapping.
	var mapped_targets: Dictionary = {}
	for mapping in control_mode._descriptor.get("input_mapping", []):
		if typeof(mapping) == TYPE_DICTIONARY:
			mapped_targets[str((mapping as Dictionary).get("target", ""))] = true
	for cmd_v in sink.commands:
		var cmd := cmd_v as Dictionary
		for section in ["axes", "buttons", "poses"]:
			for key in (cmd.get(section, {}) as Dictionary).keys():
				if not mapped_targets.has(str(key)):
					out.append(OperatorTestFailure.create(
						"unmapped_control",
						"command %s key '%s' is not a descriptor target" % [section, key]))
	return out


func teardown() -> void:
	if tracking != null and is_instance_valid(tracking):
		tracking.free()
		tracking = null


static func _hand_index(args: Dictionary) -> int:
	var hand_v: Variant = args.get("hand", 1)
	if typeof(hand_v) == TYPE_STRING:
		return 0 if String(hand_v) == "left" else 1
	return int(hand_v)
