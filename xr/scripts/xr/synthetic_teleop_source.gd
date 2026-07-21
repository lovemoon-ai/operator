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

## Thumbstick fine-adjust exercise window, as offsets from RELEASE.
## The nudge path (stick deflection, and the released-deadman branch) was
## previously never executed by CI at all -- the stick sat at zero for the whole
## run -- which is exactly how a bug that made released-grip nudging a silent
## no-op shipped with a green harness. The sweep below drives the stick while
## ENGAGED and again after RELEASE so both branches are covered.
const STICK_ENGAGED_SEC := 1.5
const STICK_RELEASED_SEC := 1.5

var _stick: Vector2 = Vector2.ZERO
var _stick_click := false
var _grip := 0.0
var _trigger := 0.0
var _button_b := 0.0
var _pos: Vector3 = BASE_POS
var _rot: Quaternion = Quaternion.IDENTITY

# Dual-arm mode. A single-arm rig is driven entirely from the right controller;
# a dual SO-101 rig runs BOTH arms at once, so the source must also present a
# live LEFT controller (pose + grip + trigger) or the left arm is never
# commanded and holds at home. It plays the SAME canned trajectory as the right
# hand -- the point is to prove both arms track, not to sweep them differently --
# baselined at a mirrored x so the two hands do not overlap in space. Enabled by
# the controller when the descriptor's device type is a dual arm; a single-arm
# run leaves this false and the left getters stay inert exactly as before.
var _dual := false
## Left baseline mirrors the right across x. Absolute value is irrelevant (the
## robot retargets relative to the squeeze pose) but the two hands must be
## distinct so the run is visibly two-handed.
const BASE_POS_LEFT := Vector3(-0.20, 1.15, -0.35)
var _pos_left: Vector3 = BASE_POS_LEFT


## Skip TrackingProvider._ready — we must NOT run OpenXR node discovery.
func _ready() -> void:
	pass


## Drive both controllers instead of only the right. Call before engage(); the
## controller sets it from the descriptor device type so the mode follows the
## robot on the fly rather than a separate launch flag.
func set_dual(enabled: bool) -> void:
	_dual = enabled
	print("[SyntheticTeleopSource] dual=%s" % str(enabled))


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
		_pos_left = BASE_POS_LEFT
		_rot = Quaternion.IDENTITY
		return

	# Deadman engaged (unless we've entered the release tail).
	_grip = 0.0 if t >= _release_at else 1.0

	# Stick sweep: a horizontal push just before release, then a vertical push
	# (click held) after release, so CI exercises the nudge in BOTH the enabled
	# and released-deadman branches.
	_stick = Vector2.ZERO
	_stick_click = false
	var engaged_from := _release_at - STICK_ENGAGED_SEC
	if t >= engaged_from and t < _release_at:
		_stick = Vector2(0.0, 1.0)          # push forward while driving
	elif t >= _release_at and t < _release_at + STICK_RELEASED_SEC:
		_stick = Vector2(0.0, 1.0)          # push again with the deadman RELEASED
		_stick_click = true                 # ...and in vertical (height) mode

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
		# The left hand tracks the same offset around its own baseline, so on a
		# dual rig both arms sweep together.
		_pos_left = BASE_POS_LEFT + off
		# A gentle wrist roll so rotation is exercised too.
		_rot = Quaternion(Vector3.UP, 0.25 * sin(w))
		# Trigger pulses (gripper open/close). Descriptor inverts+offsets, so this
		# is just a 0..1 drive.
		_trigger = 0.5 * (1.0 + sin(w * 0.5))
	# button_b (reset) intentionally left unpressed during the run.


# --- TrackingProvider getter overrides ---------------------------------------

func is_controller_mode_active(hand: int) -> bool:
	if hand == 1:
		return true  # right controller: always active
	# Left controller: active only in dual mode, where it drives the left arm.
	return hand == 0 and _dual


func get_controller_input(hand: int) -> Dictionary:
	if hand == 1:
		return {
			"trigger": _trigger,
			"trigger_click": 0.0,
			"grip": _grip,
			"grip_click": _grip,
			"grip_force": _grip,
			"select_button": 0.0,
			"primary": _stick,
			"joystick": _stick,
			"primary_x": _stick.x,
			"primary_y": _stick.y,
			"primary_click": _stick_click,
			"ax_button": 0.0,
			"by_button": _button_b,
			"menu_button": 0.0,
		}
	if hand == 0 and _dual:
		# Left arm: same deadman + gripper drive as the right. No stick nudge
		# (that path is already covered on the right hand), so joystick is zero.
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
			"primary_click": false,
			"ax_button": 0.0,
			"by_button": 0.0,
			"menu_button": 0.0,
		}
	return {}


func get_controller_pose(hand: int) -> Dictionary:
	if hand == 1:
		return {
			"position": _pos,
			"rotation": _rot,
			"is_active": true,
		}
	if hand == 0 and _dual:
		return {
			"position": _pos_left,
			"rotation": _rot,
			"is_active": true,
		}
	return {"is_active": false}


func get_head_pose() -> Dictionary:
	return {
		"position": HEAD_POS,
		"rotation": Quaternion.IDENTITY,
		"timestamp_ns": Time.get_ticks_usec() * 1000,
	}


func get_hand_joints(_hand: int) -> Array[Dictionary]:
	var empty: Array[Dictionary] = []
	return empty
