extends RefCounted
## Device conformance probe: Inside Robot remote retargeting, skeleton path.
##
## Covers the other remote backend — the persistent C++ worker the service
## supervises for humanoid profiles — with a synthetic canonical skeleton, so
## the case does not depend on an operator standing in body tracking. It proves
## the headset's skeleton payload reaches the worker and a full qpos vector
## comes back.

const CASE_ID := "teleop.remote_retargeting_humanoid"
const Probe := preload("res://tests/device/teleop/remote_retargeting_probe.gd")
const PROFILE_ID := "unitree_g1"

# A neutral standing pose: enough joints for the worker's required slots.
const SKELETON := {
	"hips": [0.0, 1.0, 0.0],
	"upper_chest": [0.0, 1.4, 0.0],
	"left_upper_arm": [-0.2, 1.4, 0.0],
	"left_lower_arm": [-0.42, 1.3, -0.08],
	"left_wrist": [-0.62, 1.2, -0.16],
	"right_upper_arm": [0.2, 1.4, 0.0],
	"right_lower_arm": [0.42, 1.3, -0.08],
	"right_wrist": [0.62, 1.2, -0.16],
}


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var profile := RobotProfileRegistry.get_profile(PROFILE_ID)
	if not t.is_true(not profile.is_empty(), "unitree_g1 profile is registered"):
		return

	var probe := Probe.new()
	var failure := probe.open(profile)
	if not t.is_true(
		failure.is_empty(),
		(
			"connects to the retargeting service for a worker-backed profile "
			+ "(the host needs app/build/retargeting_worker): %s"
		)
		% failure
	):
		probe.close()
		return

	t.eq(
		str(probe.service_profile.get("input_type", "")),
		"skeleton_frame_v1",
		"humanoid profile negotiates the skeleton input"
	)

	var joints := {}
	for name in SKELETON:
		joints[name] = Probe.joint_record(SKELETON[name])
	var result := probe.solve({"frame": {"joints": joints}})
	if not t.is_true(
		not result.is_empty(), "worker solves a canonical skeleton%s" % probe.fault_suffix()
	):
		probe.close()
		return

	var q: Array = result.get("q", [])
	t.eq(str(result.get("profile_id", "")), PROFILE_ID, "result carries the profile id")
	t.eq(q.size(), int(profile.get("expected_q_size", 0)), "result is a full model qpos vector")
	var finite := true
	for value in q:
		finite = finite and is_finite(float(value))
	t.is_true(finite, "worker qpos is finite")

	probe.reset_session()
	t.is_true(probe.faults.is_empty(), "no transport or protocol fault was reported")
	t.log_line("skeleton remote retargeting verified (%d qpos values)" % q.size())
	probe.close()
