extends RefCounted

const CASE_ID := "teleop.pico_body_tracking_availability"
const BodyPoseProviderScript := preload(
	"res://scripts/robot_constraint/body_pose_provider.gd"
)


class InvalidPicoBridge:
	extends RefCounted

	func get_status() -> Dictionary:
		return {
			"pico_body_tracking2_extension": true,
			"bd_body_tracking_supported": true,
		}

	func sample_body_joints() -> Dictionary:
		return {
			"active": true,
			"supported": true,
			"status": 0,
			"message": 0,
			"all_tracked": false,
			"joints": [
				{
					"joint": 0,
					"flags": 2,
					"position": {"x": 0.0, "y": 1.0, "z": 0.0},
				}
			],
		}


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var provider := BodyPoseProviderScript.new()
	provider.pico_unavailable_grace_s = 0.0
	provider.configure(null, InvalidPicoBridge.new())
	var unavailable: Array = []
	provider.tracking_unavailable.connect(
		func(source: String, reason: String) -> void: unavailable.append([source, reason])
	)

	provider.call("_sample_pico", 1_000)
	t.eq(unavailable.size(), 1, "invalid Pico body state emits an unavailable event")
	if not unavailable.is_empty():
		t.eq(unavailable[0][0], "pico", "unavailable event identifies Pico")
		t.eq(
			unavailable[0][1],
			"body_state_not_ready",
			"unavailable event reports the invalid body state"
		)

	provider.call("_sample_pico", 2_000)
	t.eq(unavailable.size(), 1, "persistent invalid state emits only once")

	provider.set_enabled(false)
	provider.set_enabled(true)
	provider.call("_sample_pico", 3_000)
	t.eq(unavailable.size(), 2, "a new tracking session can report unavailability again")
