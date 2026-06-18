class_name SpatialCaptureContract
extends Object
# Canonical GDScript-side contract for spatial capture data passing between the
# xr_capture_provider plugin (data producer) and the spatialmp4_muxer plugin
# (consumer / writer).
#
# Hot streams (RGB packets, depth frames) flow through a Kotlin-level
# interface declared in `android_plugin/contract/` and never enter GDScript on
# the per-frame path -- there is no GDScript counterpart for them here. What
# *does* live in GDScript is the low-rate metadata (pose, hand joints,
# controller input) and the configuration dictionaries shared between the two
# plugins. This file documents and enforces those shapes.
#
# Keep this script append-only with respect to its public API: bump VERSION
# whenever a constant or helper changes signature, and provide migration
# guidance in CHANGELOG entries alongside the bump.

# Contract revision. Mirrors com.spatialmp4.contract.CONTRACT_VERSION so the
# GDScript and Kotlin sides advance in lockstep. Host code should sanity-check
# this matches the provider's reported version at startup.
const VERSION: int = 5

# Canonical timebase for every `pts_ns` value crossing the contract.
# Provider plugins are responsible for folding XR / sensor clocks into this
# single domain before emitting; consumers may assume it without offsetting.
const PTS_DOMAIN: String = "godot_ticks_ns"
const PTS_UNITS_PER_SECOND: int = 1_000_000_000


# ----- Intrinsics dictionary -------------------------------------------------
# Shape used by `XRRgbProvider.csd_ready` / `XRDepthProvider.first_metadata`
# and by `SpatialMP4Writer.configure_*`:
#   {
#     "fx": float, "fy": float, "cx": float, "cy": float,
#     "extrinsics_3x4": Array[float]  # 12 doubles, row-major (identity OK)
#     "distortion":     Array[float]  # up to 5 Brown coefficients, pad with 0
#     "width": int, "height": int,
#   }

const INTRINSICS_EXTRINSICS_LEN := 12
const INTRINSICS_DISTORTION_MAX_LEN := 5

const _IDENTITY_EXTRINSICS_3X4 := [
	1.0, 0.0, 0.0, 0.0,
	0.0, 1.0, 0.0, 0.0,
	0.0, 0.0, 1.0, 0.0,
]


static func make_intrinsics(
	fx: float, fy: float, cx: float, cy: float,
	width: int, height: int,
	extrinsics_3x4: Array = [],
	distortion: Array = []
) -> Dictionary:
	# Build an intrinsics dictionary that round-trips cleanly into the Kotlin
	# Intrinsics data class. Missing extrinsics default to identity; missing
	# distortion coefficients are zero-padded so the muxer's box writer sees a
	# stable, fixed-length list.
	var ext: Array = extrinsics_3x4 if extrinsics_3x4.size() == INTRINSICS_EXTRINSICS_LEN else _IDENTITY_EXTRINSICS_3X4.duplicate()
	var dist: Array = distortion.duplicate()
	while dist.size() < INTRINSICS_DISTORTION_MAX_LEN:
		dist.append(0.0)
	if dist.size() > INTRINSICS_DISTORTION_MAX_LEN:
		dist.resize(INTRINSICS_DISTORTION_MAX_LEN)
	return {
		"fx": fx, "fy": fy, "cx": cx, "cy": cy,
		"extrinsics_3x4": ext,
		"distortion": dist,
		"width": width, "height": height,
	}


static func validate_intrinsics(intr: Dictionary) -> bool:
	# Cheap structural check used by hosts that want to fail fast when wiring
	# an unfamiliar provider/muxer pair. Returns true iff every required key is
	# present and shaped correctly. Mostly useful in tests; production code
	# should rely on the Kotlin Intrinsics constructor's `require` checks.
	for key in ["fx", "fy", "cx", "cy", "extrinsics_3x4", "distortion", "width", "height"]:
		if not intr.has(key):
			return false
	var ext = intr.get("extrinsics_3x4")
	var dist = intr.get("distortion")
	if not (ext is Array) or ext.size() != INTRINSICS_EXTRINSICS_LEN:
		return false
	if not (dist is Array) or dist.size() > INTRINSICS_DISTORTION_MAX_LEN:
		return false
	return true


# ----- Timed metadata kinds --------------------------------------------------
# Stable identifiers the muxer's `add_timed_track` accepts. Mirroring them as
# constants gives host code one place to update when new track kinds appear.

const TRACK_KIND_RIGID_POSE := "rigid_pose"
const TRACK_KIND_HAND_JOINTS := "hand_joints"
const TRACK_KIND_CONTROLLER_INPUT := "controller_input"

const TRACK_SCHEMA_RIGID_POSE := "spatialmp4.rigid_pose.v1"
const TRACK_SCHEMA_HAND_JOINTS := "spatialmp4.hand_joints.v1"
const TRACK_SCHEMA_CONTROLLER_INPUT := "spatialmp4.controller_input.v1"
