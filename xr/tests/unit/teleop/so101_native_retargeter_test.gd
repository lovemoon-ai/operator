extends RefCounted
## Pure-GDScript verification of the headset-native SO101 IK warm start.

const CASE_ID := "teleop.so101_native_retargeter"
const HOME_POSITION := Vector3(0.2859170975, -0.0000094584, 0.0678807345)
const HOME_ROTATION := Quaternion(0.0229780849, 0.9439982080, 0.0080145896, 0.3290519067)


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var solver := So101NativeRetargeter.new()
	var result := solver.solve(HOME_POSITION, HOME_ROTATION)
	t.eq(str(result.get("status", "")), "converged", "home pose converges")
	var q: Array = result.get("q", [])
	t.eq(q.size(), 5, "SO101 native result has five arm joints")
	var metrics: Dictionary = result.get("metrics", {})
	t.is_true(float(metrics.get("pos_err_m", INF)) < 0.00001, "home FK position is aligned")
	t.is_true(float(metrics.get("ori_err_rad", INF)) < 0.0001, "home FK orientation is aligned")
