extends RefCounted
const CASE_ID := "contracts.tracking_interlocks"
const InsideTarget := preload("res://scripts/teleop/targets/inside_robot_target.gd")

class BodySource:
	extends Node
	var tracking_ready := true
	var output := true
	func is_tracking_ready() -> bool:
		return tracking_ready
	func tracking_status() -> Dictionary:
		return {"allowed": tracking_ready, "phase": "ready" if tracking_ready else "required"}
	func set_output_enabled(value: bool) -> void:
		output = value

class StateTransport:
	extends TcpHandler
	var closes := 0
	func disconnect_from_robot() -> void:
		closes += 1


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var body := BodySource.new()
	var target := InsideTarget.new()
	target.profile = {"requires_body_tracking": true}
	target.set("state", 2) # READY; no robot assets or native simulation created.
	target.set("_body_provider", body)
	target.set_control_enabled(true)
	t.is_true(target.control_enabled and body.output, "ready body can enable retargeting")
	body.tracking_ready = false
	target.call("_process", 0.02)
	t.is_false(target.control_enabled or body.output, "loss stops both control and canonical-frame output")
	body.tracking_ready = true
	target.set_control_enabled(true)
	t.is_false(target.control_enabled or body.output, "restoring tracking cannot automatically resume Inside control")
	t.is_true(target.is_tracking_interlocked(), "explicit restart/re-arm is required")
	target.set("_body_provider", null)
	body.free()
	target.free()

	var transport := StateTransport.new()
	var sender := XrStateSender.new()
	sender.tcp_handler = transport
	sender.set("_sending", true)
	sender.set("_has_published_tracking", true)
	sender.call("_on_tracking_invalidated", {"phase": "required"})
	t.is_true(sender.is_tracking_interlocked(), "SDK sender latches loss immediately")
	sender.call("_disconnect_for_tracking", {"phase": "required"})
	t.eq(transport.closes, 1, "SDK host receives transport loss, not fabricated valid robot poses")
	sender.configure({"streams": ["body"]})
	t.is_true(sender.is_tracking_interlocked(), "reconfiguring another body request does not re-arm")
	sender.configure({"streams": ["head", "controllers"]})
	t.is_false(sender.is_tracking_interlocked(), "a head/controller-only request is not blocked by an old body latch")
	sender.rearm_tracking()
	t.is_false(sender.is_tracking_interlocked(), "explicit re-arm resets the SDK latch")
	sender.free()
	transport.free()
