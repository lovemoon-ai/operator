extends RefCounted
const CASE_ID := "blueprint.controller_workflow"
const Runtime := preload("res://scripts/blueprint/blueprint_runtime.gd")
const Shell := preload("res://scripts/blueprint/system_menu_host.gd")
const Router := preload("res://scripts/ui/settings_interaction_router.gd")

class TimedBinding:
	extends "res://scripts/blueprint/controller_input_binding.gd"
	var now_us := 1000000
	var feedback: Array[String] = []
	func _now_us() -> int:
		return now_us
	func _play_feedback(pattern: String) -> void:
		feedback.append(pattern)


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var origin := XROrigin3D.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(origin)
	var camera := XRCamera3D.new()
	origin.add_child(camera)
	camera.position = Vector3(0, 1.6, 0)
	var trackers: Array[XRPositionalTracker] = []
	var controllers: Array[XRController3D] = []
	for side in ["left", "right"]:
		var tracker := XRPositionalTracker.new()
		tracker.name = "operator_test_workflow_" + side
		tracker.profile = "/interaction_profiles/bytedance/pico4s_controller"
		tracker.type = XRServer.TRACKER_CONTROLLER
		XRServer.add_tracker(tracker)
		trackers.append(tracker)
		var controller := XRController3D.new()
		controller.tracker = StringName(tracker.name)
		controller.pose = &"default"
		origin.add_child(controller)
		controllers.append(controller)
		tracker.set_pose(&"default", Transform3D(Basis.IDENTITY, Vector3(-0.2 if side == "left" else 0.2, 1.0, -0.5)),
			Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	_test_acknowledgement(origin, controllers, trackers, t)
	_test_system_scope(origin, camera, controllers, trackers, t)
	origin.free()
	for tracker in trackers:
		XRServer.remove_tracker(tracker)


func _test_acknowledgement(origin: Node3D, controllers: Array[XRController3D], trackers: Array[XRPositionalTracker], t: OperatorTestAssertions) -> void:
	var binding := TimedBinding.new()
	binding.configure({"gesture": "dual_trigger_hold", "hold_seconds": 1.0}, controllers[0], controllers[1])
	origin.add_child(binding)
	binding.set_active(true)
	var requests: Array[String] = []
	binding.action_triggered.connect(func(_action: StringName, request: Variant) -> void: requests.append(str(request)))
	_step(binding, trackers, 1000000, 0, 0)
	_hold(binding, trackers, 1100000)
	t.eq(requests.size(), 1, "continuous dual trigger hold creates one request")
	if requests.is_empty():
		binding.free()
		return
	var first := requests[0]
	t.eq(first.length(), 32, "request has a fresh opaque identity")
	t.eq(binding.feedback.size(), 0, "one-second hold alone does not vibrate success")
	_step(binding, trackers, 2200000, 1, 1, "old-request", true, false)
	t.eq(binding.feedback.size(), 0, "unmatched acknowledgements cannot vibrate")
	_step(binding, trackers, 2300000, 1, 1, first, false, true)
	t.eq(binding.feedback, ["error"], "failed reset produces failure feedback only")
	_step(binding, trackers, 2400000, 1, 1, first, true, false)
	t.eq(binding.feedback.size(), 1, "replayed acknowledgement cannot become success")
	_step(binding, trackers, 2500000, 0, 0)
	_hold(binding, trackers, 2600000)
	t.eq(requests.size(), 2, "releasing both and holding again allows a new request")
	var second := requests.back()
	t.ne(second, first, "request identity changes between resets")
	_step(binding, trackers, 3700000, 1, 1, second, true, false)
	t.eq(binding.feedback, ["error", "success"], "matching successful host ack triggers confirmation once")
	_step(binding, trackers, 3800000, 1, 1, second, true, false)
	t.eq(binding.feedback.size(), 2, "duplicate state cannot repeat vibration")
	_step(binding, trackers, 3900000, 0, 0)
	_hold(binding, trackers, 4000000)
	var third := requests.back()
	binding.set_active(false)
	binding.set_active(true)
	_step(binding, trackers, 5100000, 1, 1, third, true, false)
	t.eq(binding.feedback.size(), 2, "ack after suspension cannot vibrate")
	for index in range(1, 12):
		_step(binding, trackers, 5100000 + index * 100000, 1, 1)
	t.eq(requests.size(), 3, "held controls after resume cannot issue another reset")
	_step(binding, trackers, 6400000, 0, 0)
	_hold(binding, trackers, 6500000)
	var fourth := requests.back()
	binding.now_us = 11000000
	binding.set_bound_state(true, false, "", false, "", binding.now_us)
	binding.sample_input()
	t.eq(binding.feedback.back(), "error", "missing ack times out with error feedback")
	var feedback_count := binding.feedback.size()
	_step(binding, trackers, 11100000, 1, 1, fourth, true, false)
	t.eq(binding.feedback.size(), feedback_count, "late acknowledgement after timeout is ignored")
	t.is_true(binding.ui_status()["required"], "timed out reset remains uncertain, not green")
	_step(binding, trackers, 11200000, 0, 0)
	_hold(binding, trackers, 11300000)
	var fifth := requests.back()
	trackers[1].invalidate_pose(&"default")
	_step(binding, trackers, 12400000, 1, 1, fifth, true, false)
	t.eq(binding.feedback.size(), feedback_count, "tracking loss before acknowledgement cannot vibrate success")
	t.is_true(binding.ui_status()["required"], "lost acknowledgement context cannot leave a ready green state")
	trackers[1].set_pose(&"default", Transform3D(Basis.IDENTITY, Vector3(0.2, 1.0, -0.5)), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	var count_before := requests.size()
	_step(binding, trackers, 12500000, 0, 0)
	binding.target_ready = func(_id: String) -> bool: return false
	_hold(binding, trackers, 12600000)
	t.eq(requests.size(), count_before, "unready model cannot submit a reset request")
	t.eq(binding.feedback.back(), "error", "blocked one-second hold is not silently ignored")
	binding.free()


func _step(binding: TimedBinding, trackers: Array[XRPositionalTracker], now: int, left: float, right: float,
		ack: String = "", success: bool = false, required: bool = true) -> void:
	binding.now_us = now
	trackers[0].set_input(&"trigger", left)
	trackers[1].set_input(&"trigger", right)
	binding.set_bound_state(true, required, ack, success, "", now)
	binding.sample_input()


func _hold(binding: TimedBinding, trackers: Array[XRPositionalTracker], start: int) -> void:
	for tick in range(11):
		_step(binding, trackers, start + tick * 100000, 1, 1)


func _test_system_scope(origin: XROrigin3D, camera: XRCamera3D, controllers: Array[XRController3D], trackers: Array[XRPositionalTracker], t: OperatorTestAssertions) -> void:
	var remote := Runtime.new()
	remote.configure(origin, camera, controllers[0], controllers[1], null)
	origin.add_child(remote)
	var shell := Shell.new()
	origin.add_child(shell)
	shell.configure(origin, camera, controllers[0], controllers[1], null, remote)
	var connections: Array = []
	var remote_events: Array = []
	shell.connection_requested.connect(func(wanted: bool) -> void: connections.append(wanted))
	remote.event_emitted.connect(func(event: Dictionary) -> void: remote_events.append(event))
	shell.update_context(false, false, true)
	var menu: Node3D = shell.menu
	t.is_true(menu != null, "system menu exists before a remote Blueprint")
	var buttons: Dictionary = menu.get("_buttons")
	t.eq(buttons.size(), 2, "system menu has connect/disconnect and recenter, not reset")
	var connection_row: Dictionary = shell.runtime.menu_entries()[0]
	t.eq(
		str(connection_row["text"]),
		str(TranslationServer.translate("UI_CONNECT_ROBOT")),
		"disconnected, the connection row asks the operator to connect a robot"
	)
	t.is_true(
		bool(connection_row["available"]),
		"the row stays clickable so it can lead the operator to Settings"
	)
	shell.runtime.dispatch_menu(connection_row["token"], false)
	t.eq(connections, [true], "connect is dispatched locally; the owner routes it to Settings")
	t.eq(remote_events.size(), 0, "system actions are not sent to the robot")
	shell.update_context(true, false, true)
	shell.runtime.dispatch_menu(shell.runtime.menu_entries()[0]["token"], true)
	t.eq(connections, [true, false], "same button disconnects the real session through local owner")
	remote.clear()
	shell.update_context(false, false, true)
	t.is_true(shell.runtime.has_blueprint(), "disconnect clears robot scope but keeps the system Blueprint")
	t.eq(shell.menu, menu, "disconnect does not destroy the reconnect menu")
	trackers[0].set_input(&"menu_button", false)
	menu.call("update_presentation", "controllers", true, {}, Transform3D.IDENTITY, null, 0.02)
	trackers[0].set_input(&"menu_button", true)
	menu.call("update_presentation", "controllers", true, {}, Transform3D.IDENTITY, null, 0.02)
	t.is_true(menu.visible, "left Menu opens even while disconnected")
	t.eq(Shell.indicator_state(false, false, {"required": false}), "disconnected", "old ready state cannot keep disconnected lamps green")
	t.eq(Shell.indicator_state(false, true, {}), "busy", "connecting flashes blue")
	t.eq(Shell.indicator_state(true, false, {"required": true}), "needs_reset", "uncalibrated connection is orange")
	t.eq(Shell.indicator_state(true, false, {"pending": true}), "busy", "reset hold/ack pending flashes blue")
	t.eq(Shell.indicator_state(true, false, {"required": false}), "ready", "ready connection is green")
	# A chord cancels a pending menu press instead of completing it on release.
	var router := Router.new()
	origin.add_child(router)
	router.configure(origin, camera, controllers[0], controllers[1], null)
	router.set_targets([menu])
	var rects: Dictionary = menu.get("_action_rects")
	var primary: Rect2 = rects[&"system_0"]
	menu.set("_pointer_position", primary.get_center())
	menu.call("set_feedback_input_mode", "controllers", controllers[1])
	menu.call("set_pointer_pressed", true)
	router.set("_pressed_target", menu)
	router.pointer_blocker = func() -> bool: return true
	router.update_pointer()
	menu.call("set_pointer_pressed", false)
	t.eq(connections.size(), 2, "reset chord cancellation cannot click disconnect/connect")
	t.is_true(router.is_teleop_input_captured(), "chord owns controller command input too")
	router.free()
	shell.free()
	remote.free()
