class_name SyntheticTeleopSource
extends TrackingProvider
## Headless, human-free TrackingProvider that plays a canned right-controller
## teleop trajectory. Lets CI drive the REAL teleop command path (ControlMode →
## CommandSender → xr-bridge → adapter → lerobot plugin → arm) with no headset
## and no operator.
##
## It is a drop-in for the OpenXR-backed TrackingProvider: it exposes the same
## getters ControlMode/CommandSender read, but sources every value from a scripted
## motion instead of XR. Because it extends TrackingProvider the typed
## `CommandSender.tracking_provider` field and every `is TrackingProvider` check
## keep holding.
##
## Only active when teleop_controller is launched with the synthetic intent
## extra; a normal build never instantiates it, so shipping it is inert.
##
## Trajectory (relative to `engage()`), matching the SO-101 descriptor
## (right_grip→enable deadman, right_controller_pose→end_effector,
## right_trigger→gripper, invert+offset so released=open):
##
##   [0, SETTLE)          grip released, pose at baseline  (arm holds at home)
##   [SETTLE, SETTLE+RAMP) grip squeezed, pose held         (robot seeds its
##                                                            retarget reference)
##   [SETTLE+RAMP, RELEASE) grip held, pose sweeps a smooth  (arm tracks; robot
##                          bounded path + trigger pulses      clamps per step)
##   [RELEASE, ∞)         grip released, pose frozen        (arm must HOLD)

## Seconds of neutral hold before the deadman is squeezed. Gives connect +
## descriptor + the plugin's home slew time to finish before motion starts.
const SETTLE_SEC := 2.0
## Seconds squeezed-but-still so the robot-side PoseMapper captures a clean
## baseline reference at the squeeze instant before the sweep begins.
const RAMP_SEC := 1.0
## Baseline right-controller position in metres (absolute value is irrelevant —
## the robot retargets relative to the squeeze pose — but it must be stable).
const BASE_POS := Vector3(0.0, 1.15, -0.35)
## Peak Cartesian excursion of the sweep, metres. Kept small; the robot also
## clamps per-step motion via --robot.max_relative_target.
const SWEEP_POS := Vector3(0.08, 0.05, 0.06)
## Full sweep period (s) of the primary sinusoid.
const SWEEP_PERIOD := 6.0
## Stable synthetic head height (operator_frame source).
const HEAD_POS := Vector3(0.0, 1.40, 0.0)

var _engaged := false
var _t := 0.0
var _release_at := INF  # seconds after engage() at which the grip releases

var _grip := 0.0
var _trigger := 0.0
var _button_b := 0.0
var _pos: Vector3 = BASE_POS
var _rot: Quaternion = Quaternion.IDENTITY


## Skip TrackingProvider._ready — we must NOT run OpenXR node discovery.
func _ready() -> void:
	pass


## Begin playback. `hold_sec` is the total engaged duration; the grip releases
## HOLD_TAIL_SEC before the end so the "released → arm holds" phase is exercised.
const HOLD_TAIL_SEC := 1.5
func engage(hold_sec: float) -> void:
	_t = 0.0
	_release_at = maxf(SETTLE_SEC + RAMP_SEC + 0.5, hold_sec - HOLD_TAIL_SEC)
	_engaged = true
	_recompute(0.0)
	print("[SyntheticTeleopSource] engaged hold=%.1fs release_at=%.1fs" % [hold_sec, _release_at])


func is_engaged() -> bool:
	return _engaged


## Seconds elapsed since engage() (0 until engaged).
func elapsed() -> float:
	return _t if _engaged else 0.0


# Advance in _process (render rate) to match CommandSender, which now samples at
# render rate: this keeps the synthetic pose fresh on every send instead of only
# every 60Hz physics tick, so the synthetic path exercises the same higher-rate
# delivery the real controller does.
func _process(delta: float) -> void:
	if not _engaged:
		return
	_t += delta
	_recompute(_t)


## Pure function of elapsed time → the synthetic input/pose state.
func _recompute(t: float) -> void:
	if t < SETTLE_SEC:
		_grip = 0.0
		_trigger = 0.0
		_button_b = 0.0
		_pos = BASE_POS
		_rot = Quaternion.IDENTITY
		return

	# Deadman engaged (unless we've entered the release tail).
	_grip = 0.0 if t >= _release_at else 1.0

	# Sweep phase progress (0 during the squeeze-and-settle ramp).
	var sweep_t := maxf(0.0, t - (SETTLE_SEC + RAMP_SEC))
	var w := TAU * sweep_t / SWEEP_PERIOD
	# Freeze the pose at the last commanded point once released so the arm has a
	# stable target to hold at.
	if t < _release_at:
		var off := Vector3(
			SWEEP_POS.x * sin(w),
			SWEEP_POS.y * sin(w * 0.5),
			SWEEP_POS.z * (1.0 - cos(w)) * 0.5,
		)
		_pos = BASE_POS + off
		# A gentle wrist roll so rotation is exercised too.
		_rot = Quaternion(Vector3.UP, 0.25 * sin(w))
		# Trigger pulses (gripper open/close). Descriptor inverts+offsets, so this
		# is just a 0..1 drive.
		_trigger = 0.5 * (1.0 + sin(w * 0.5))
	# button_b (reset) intentionally left unpressed during the run.


# --- TrackingProvider getter overrides ---------------------------------------

func is_controller_mode_active(hand: int) -> bool:
	return hand == 1  # right controller only, always "active"


func get_controller_input(hand: int) -> Dictionary:
	if hand != 1:
		return {}
	return {
		"trigger": _trigger,
		"trigger_click": 0.0,
		"grip": _grip,
		"grip_click": _grip,
		"grip_force": _grip,
		"select_button": 0.0,
		"primary": Vector2.ZERO,
		"joystick": Vector2.ZERO,
		"primary_x": 0.0,
		"primary_y": 0.0,
		"primary_click": 0.0,
		"ax_button": 0.0,
		"by_button": _button_b,
		"menu_button": 0.0,
	}


func get_controller_pose(hand: int) -> Dictionary:
	if hand != 1:
		return {"is_active": false}
	return {
		"position": _pos,
		"rotation": _rot,
		"is_active": true,
	}


func get_head_pose() -> Dictionary:
	return {
		"position": HEAD_POS,
		"rotation": Quaternion.IDENTITY,
		"timestamp_ns": Time.get_ticks_usec() * 1000,
	}


func get_hand_joints(_hand: int) -> Array[Dictionary]:
	var empty: Array[Dictionary] = []
	return empty
