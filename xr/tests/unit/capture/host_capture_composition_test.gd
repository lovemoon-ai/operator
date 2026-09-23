extends RefCounted
## HostCaptureComposition: a host session only records locally when the host
## declared a `record` task. Found on a Quest 3: lightnav declares no local
## tasks, yet the composition started "push + record", blocked on the
## shared-storage permission, never started the camera and still told the
## host its streams were active.

const CASE_ID := "capture.host_capture_composition"
const HostCaptureScript := preload("res://scripts/app/composition/host_capture_composition.gd")

const DECLARATION := {
	"schema_version": 1,
	"streams": [{"name": "rgb.hevc", "max_hz": 4, "eye": "left"}],
}


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var composition := HostCaptureScript.new()
	composition._config = DECLARATION
	composition._planner.plan_host(
		DECLARATION, ["rgb.hevc"], {"camera": "allow", "xr_state": "allow"}, "controllers")
	t.is_true(composition._planner.media_up_running(), "a granted rgb stream runs media_up")
	t.is_false(composition._record_running(),
		"without a declared record task the session only pushes, never records locally")

	var with_record := DECLARATION.duplicate(true)
	with_record["local_tasks"] = [{"kind": "record"}]
	composition._config = with_record
	t.is_true(composition._record_running(), "a declared record task records alongside the push")
	composition._record_wanted = false
	t.is_false(composition._record_running(), "StreamsControl can stop the declared record task")
	composition.free()
