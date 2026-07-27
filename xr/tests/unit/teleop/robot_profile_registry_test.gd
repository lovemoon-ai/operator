extends RefCounted
## Unit coverage for the Inside/Outside product boundary and for asset-driven
## profile discovery. Outside descriptors remain service-owned; only Inside uses
## these bundled profiles, and only when this build actually ships their assets.

const CASE_ID := "teleop.robot_profile_registry"


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var ids := RobotProfileRegistry.ids()
	t.is_true(ids.size() > 0, "at least one Inside Robot profile ships with this build")
	t.log_line(
		"profiles offered: [%s]; withheld: %s"
		% [", ".join(ids), JSON.stringify(RobotProfileRegistry.unavailable())]
	)

	# Every offered profile must be startable: the operator can only be shown a
	# robot whose assets are present, whatever this build happens to contain.
	for profile_id in ids:
		var profile := RobotProfileRegistry.get_profile(profile_id)
		t.eq(
			str(profile.get("profile_id", "")), profile_id, "%s manifest is self-consistent" % profile_id
		)
		t.is_true(
			not str(profile.get("display_name", "")).is_empty(),
			"%s has a display name for the picker" % profile_id
		)
		t.is_true(
			int(profile.get("expected_q_size", 0)) > 0,
			"%s declares its remote joint-vector contract" % profile_id
		)
		t.contains(
			["skeleton_frame_v1", "end_effector_pose_v1"],
			str(profile.get("input_type", "")),
			"%s declares a known input contract" % profile_id
		)
		t.is_true(
			_asset_present(str(profile.get("simulation_model", ""))),
			"%s bundles an in-headset simulation model" % profile_id
		)
		for asset in profile.get("required_assets", []):
			var path := str(asset)
			t.log_line(
				"%s asset %s: loader=%s file=%s"
				% [
					profile_id,
					path,
					str(ResourceLoader.exists(path)),
					str(FileAccess.file_exists(path)),
				]
			)
			t.is_true(_asset_present(path), "%s asset is present: %s" % [profile_id, asset])
		t.is_true(
			(
				RobotProfileRegistry.supports_backend(profile_id, "native")
				or RobotProfileRegistry.supports_backend(profile_id, "remote")
			),
			"%s supports at least one retargeting backend" % profile_id
		)

	# A robot whose assets were never generated stays out of the picker rather
	# than appearing and failing at start.
	for profile_id in RobotProfileRegistry.unavailable():
		t.is_false(ids.has(profile_id), "%s is withheld while its assets are missing" % profile_id)
		t.is_true(
			RobotProfileRegistry.get_profile(profile_id).is_empty(),
			"%s resolves to nothing" % profile_id
		)
		t.is_false(
			RobotProfileRegistry.supports_backend(profile_id, "native"),
			"%s advertises no backend" % profile_id
		)

	t.is_true(
		RobotProfileRegistry.get_profile("not_a_robot").is_empty(), "unknown ids resolve empty"
	)

	if RobotProfileRegistry.has_profile("so101"):
		var so101 := RobotProfileRegistry.get_profile("so101")
		t.eq(
			str(so101.get("input_type", "")),
			"end_effector_pose_v1",
			"SO101 consumes an end-effector target"
		)
		t.eq(str(so101.get("simulation_backend", "")), "mujoco", "SO101 runs MuJoCo in the headset")
		t.is_true(
			(so101.get("local_control_descriptor", {}) as Dictionary).has("control_schema"),
			"SO101 carries the local descriptor Inside teleop binds to"
		)

	var outside_descriptor := {
		"descriptor_version": 1,
		"execution": {"kind": "outside", "environment": "simulation"},
		"device": {"name": "External simulator", "type": "humanoid"},
		"control_schema": {},
		"input_contract":
		{
			"channels": [{"name": "body", "type": "canonical_skeleton_v1"}],
		},
	}
	var parsed := DeviceDescriptorContract.parse(outside_descriptor)
	t.eq(
		(parsed.get("errors", []) as Array).size(),
		0,
		"outside execution and input contract validate without a local profile"
	)


## Imported resources (GLB) are packed as their import artifact, so the source
## path resolves through the loader rather than the filesystem.
func _asset_present(path: String) -> bool:
	return ResourceLoader.exists(path) or FileAccess.file_exists(path)
