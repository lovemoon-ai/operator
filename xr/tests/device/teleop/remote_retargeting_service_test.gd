extends RefCounted
## Device conformance probe: Inside Robot remote retargeting, end-effector path.
##
## Runs the real `RemoteRetargeter` on the headset against a live pyoperator
## retargeting service, so the whole seam is exercised on target: Godot
## WebSocketPeer -> pyoperator protocol/service -> retargeting Python solver ->
## joint positions back into XR.

const CASE_ID := "teleop.remote_retargeting_service"
const Probe := preload("res://tests/device/teleop/remote_retargeting_probe.gd")
const PROFILE_ID := "so101"


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var profile := RobotProfileRegistry.get_profile(PROFILE_ID)
	if not t.is_true(not profile.is_empty(), "so101 profile is registered"):
		return

	var probe := Probe.new()
	var failure := probe.open(profile)
	if not t.is_true(failure.is_empty(), "connects to the retargeting service: %s" % failure):
		probe.close()
		return

	t.eq(
		str(probe.service_profile.get("profile_id", "")),
		PROFILE_ID,
		"handshake echoes the negotiated profile"
	)
	t.eq(
		str(probe.service_profile.get("output_type", "")),
		str(profile.get("output_type", "")),
		"service output type matches the headset profile"
	)

	# The home end-effector pose is the one target whose solution is known
	# exactly, so a wrong frame or quaternion convention cannot pass unnoticed.
	var result := probe.solve(
		{
			"position": profile.get("home_ee_position", []),
			"orientation_wxyz": profile.get("home_ee_orientation_wxyz", []),
		}
	)
	if not t.is_true(not result.is_empty(), "service solves the home pose%s" % probe.fault_suffix()):
		probe.close()
		return

	t.eq(str(result.get("profile_id", "")), PROFILE_ID, "result carries the profile id")
	t.eq(str(result.get("status", "")), "converged", "home pose converges on the service")
	var q: Array = result.get("q", [])
	t.eq(q.size(), int(profile.get("expected_q_size", 0)), "result has the profile joint count")
	t.eq(
		(result.get("joint_names", []) as Array).size(),
		q.size(),
		"end-effector profile names every joint it reports"
	)
	var metrics: Dictionary = result.get("metrics", {})
	t.is_true(float(metrics.get("pos_err_m", INF)) < 0.001, "service solved the home position")
	t.is_true(int(result.get("solve_time_us", -1)) >= 0, "service reports its solve time")

	probe.reset_session()
	t.is_true(probe.faults.is_empty(), "no transport or protocol fault was reported")
	t.log_line(
		"eepose remote retargeting verified (%d joints, %d us)"
		% [q.size(), int(result.get("solve_time_us", 0))]
	)
	probe.close()
