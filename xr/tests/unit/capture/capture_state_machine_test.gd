extends RefCounted
## WP7 unit test: CaptureState legal-transition table — every legal edge
## accepted, a sample of illegal edges rejected, and the controller never
## crashes on illegal requests.

const CASE_ID := "capture.state_machine"

const LEGAL_EDGES := [
	[CaptureState.IDLE, CaptureState.REQUESTING_PERMISSION],
	[CaptureState.IDLE, CaptureState.READY],
	[CaptureState.REQUESTING_PERMISSION, CaptureState.READY],
	[CaptureState.REQUESTING_PERMISSION, CaptureState.ERROR],
	[CaptureState.READY, CaptureState.STARTING],
	[CaptureState.STARTING, CaptureState.RUNNING],
	[CaptureState.STARTING, CaptureState.ERROR],
	[CaptureState.RUNNING, CaptureState.STOPPING],
	[CaptureState.RUNNING, CaptureState.ERROR],
	[CaptureState.RUNNING, CaptureState.RECOVERING],
	[CaptureState.RECOVERING, CaptureState.RUNNING],
	[CaptureState.RECOVERING, CaptureState.ERROR],
	[CaptureState.STOPPING, CaptureState.STOPPED],
	[CaptureState.STOPPING, CaptureState.ERROR],
	[CaptureState.STOPPED, CaptureState.IDLE],
	[CaptureState.ERROR, CaptureState.IDLE],
]

const ILLEGAL_EDGES := [
	[CaptureState.IDLE, CaptureState.RUNNING],
	[CaptureState.IDLE, CaptureState.STOPPING],
	[CaptureState.READY, CaptureState.RUNNING],
	[CaptureState.RUNNING, CaptureState.IDLE],
	[CaptureState.RUNNING, CaptureState.STARTING],
	[CaptureState.STOPPED, CaptureState.RUNNING],
	[CaptureState.ERROR, CaptureState.RUNNING],
	[CaptureState.RECOVERING, CaptureState.STOPPING],
	[CaptureState.STOPPING, CaptureState.RUNNING],
]


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	for edge in LEGAL_EDGES:
		t.is_true(CaptureState.legal(edge[0], edge[1]),
			"legal edge rejected: %s -> %s" % [
				CaptureState.state_name(edge[0]), CaptureState.state_name(edge[1])])
	for edge in ILLEGAL_EDGES:
		t.is_false(CaptureState.legal(edge[0], edge[1]),
			"illegal edge accepted: %s -> %s" % [
				CaptureState.state_name(edge[0]), CaptureState.state_name(edge[1])])

	# Exhaustive count: the table above must cover every legal edge.
	var legal_count := 0
	for from_state in range(CaptureState.RECOVERING + 1):
		for to_state in range(CaptureState.RECOVERING + 1):
			if CaptureState.legal(from_state, to_state):
				legal_count += 1
	t.eq(legal_count, LEGAL_EDGES.size(), "legal-transition table size matches contract")

	# Controller-level behavior: illegal requests are error results, not
	# crashes, and stop() from IDLE refuses politely.
	var controller := CaptureSessionController.new()
	controller.configure({"writer_adapter": FakeCaptureWriterAdapter.new()})
	var stop_result := controller.request_stop()
	t.is_false(bool(stop_result.get("ok", true)), "stop from IDLE must return an error result")
	t.eq(controller.state(), CaptureState.IDLE, "illegal stop leaves state unchanged")
	t.is_false(controller.notify_pause(), "pause outside RUNNING is rejected")
	t.is_false(controller.notify_resume(), "resume outside RECOVERING is rejected")
