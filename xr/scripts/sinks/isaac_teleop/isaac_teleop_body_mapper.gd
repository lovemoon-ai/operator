class_name IsaacTeleopBodyMapper
extends RefCounted
## Normalizes Operator body frames to IsaacTeleop's 24-joint Pico BD ABI.
##
## Pico frames are re-indexed without changing their joint records. Meta body
## frames use Godot XRBodyTracker's explicit joint ids and a topology-aware
## projection. Missing targets remain present as invalid slots.

const PICO_JOINT_COUNT := 24

const SOURCE_PICO24 := "pico24"
const SOURCE_GODOT87 := "godot87"

const PICO_RUNTIME_IDS: Array[String] = [
	"pico_bd",
	"pico_bd_body_tracking",
]
const GODOT_RUNTIME_IDS: Array[String] = [
	"godot_xr_body_tracker",
	"godot_xrbodytracker",
	"meta_fb_body_tracking",
]

# Godot XRBodyTracker.Joint -> XrBodyJointBD, indexed by the BD target joint.
# This follows the topology populated by godot_openxr_vendors' Meta wrapper.
# In particular, the wrapper does not populate the extra scapula joints 77/79,
# and its hand joint aliases wrist; shoulder/upper-arm and palm preserve the
# neck -> collar -> shoulder -> elbow -> wrist -> hand chain instead.
const GODOT87_TO_PICO24: Array[int] = [
	1,  # PELVIS <- hips
	14, # LEFT_HIP <- left_upper_leg
	18, # RIGHT_HIP <- right_upper_leg
	2,  # SPINE1 <- spine
	15, # LEFT_KNEE <- left_lower_leg
	19, # RIGHT_KNEE <- right_lower_leg
	3,  # SPINE2 <- chest
	16, # LEFT_ANKLE <- left_foot
	20, # RIGHT_ANKLE <- right_foot
	4,  # SPINE3 <- upper_chest
	17, # LEFT_FOOT <- left_toes
	21, # RIGHT_FOOT <- right_toes
	5,  # NECK <- neck
	8,  # LEFT_COLLAR <- left_shoulder
	11, # RIGHT_COLLAR <- right_shoulder
	6,  # HEAD <- head
	9,  # LEFT_SHOULDER <- left_upper_arm
	12, # RIGHT_SHOULDER <- right_upper_arm
	10, # LEFT_ELBOW <- left_lower_arm
	13, # RIGHT_ELBOW <- right_lower_arm
	24, # LEFT_WRIST <- left_wrist
	51, # RIGHT_WRIST <- right_wrist
	23, # LEFT_HAND <- left_palm
	50, # RIGHT_HAND <- right_palm
]

# Godot XRBodyTracker.JointFlags. BODY v1 has only one validity bit, so both
# pose components must be valid; position-only data cannot be represented
# without incorrectly presenting an identity orientation as measured.
const GODOT_FLAG_ROTATION_VALID := 1
const GODOT_FLAG_POSITION_VALID := 4


static func to_pico24(
	joints: Array,
	runtime: String = "",
	frame_valid: bool = true,
) -> Dictionary:
	var source_kind := _classify_source(joints, runtime)
	if source_kind.is_empty():
		return {
			"ok": false,
			"reason": "unsupported_body_runtime",
			"joints": [],
		}

	var indexed := _index_joints(joints)
	if source_kind == SOURCE_PICO24:
		for source_index in indexed:
			if int(source_index) < 0 or int(source_index) >= PICO_JOINT_COUNT:
				return {
					"ok": false,
					"reason": "pico_joint_out_of_range",
					"joints": [],
				}
		return {
			"ok": true,
			"mapping": "pico24_identity",
			"mapped_joint_count": indexed.size(),
			"joints": _normalize_pico24(indexed),
		}

	var output: Array = []
	var mapped_joint_count := 0
	var valid_joint_count := 0
	for target_index in range(PICO_JOINT_COUNT):
		var source_index := GODOT87_TO_PICO24[target_index]
		var mapped: Dictionary = {
			"joint": target_index,
			"source_joint": source_index,
			"valid": false,
		}
		if indexed.has(source_index):
			mapped = (indexed[source_index] as Dictionary).duplicate(true)
			mapped["source_joint"] = source_index
			mapped["joint"] = target_index
			mapped["valid"] = frame_valid and _godot_pose_valid(mapped)
			mapped_joint_count += 1
			if bool(mapped["valid"]):
				valid_joint_count += 1
		output.append(mapped)

	return {
		"ok": true,
		"mapping": "godot87_to_pico24",
		"mapped_joint_count": mapped_joint_count,
		"valid_joint_count": valid_joint_count,
		"joints": output,
	}


static func _normalize_pico24(indexed: Dictionary) -> Array:
	var output: Array = []
	for target_index in range(PICO_JOINT_COUNT):
		if indexed.has(target_index):
			var mapped := (indexed[target_index] as Dictionary).duplicate(true)
			mapped["joint"] = target_index
			output.append(mapped)
		else:
			output.append({"joint": target_index, "valid": false})
	return output


static func _classify_source(joints: Array, runtime: String) -> String:
	var normalized_runtime := runtime.strip_edges().to_lower()
	if normalized_runtime in PICO_RUNTIME_IDS:
		return SOURCE_PICO24
	if normalized_runtime in GODOT_RUNTIME_IDS:
		return SOURCE_GODOT87

	# Preserve the old anonymous Pico path when all 24 slots are present.
	if joints.size() == PICO_JOINT_COUNT:
		var pico_shape := true
		for array_index in range(joints.size()):
			var entry_v: Variant = joints[array_index]
			if entry_v is Dictionary:
				var joint_index := int((entry_v as Dictionary).get("joint", array_index))
				if joint_index < 0 or joint_index >= PICO_JOINT_COUNT:
					pico_shape = false
					break
		if pico_shape:
			return SOURCE_PICO24

	# Sparse Godot frames still identify themselves through high joint ids.
	for array_index in range(joints.size()):
		var entry_v: Variant = joints[array_index]
		if entry_v is Dictionary:
			var joint_index := int((entry_v as Dictionary).get("joint", array_index))
			if joint_index >= PICO_JOINT_COUNT:
				return SOURCE_GODOT87
	return ""


static func _index_joints(joints: Array) -> Dictionary:
	var indexed: Dictionary = {}
	for array_index in range(joints.size()):
		var entry_v: Variant = joints[array_index]
		if not (entry_v is Dictionary):
			continue
		var entry := entry_v as Dictionary
		var joint_index := int(entry.get("joint", array_index))
		if joint_index >= 0:
			# Last record wins, matching IsaacTeleopPacketCodec.encode_joints.
			indexed[joint_index] = entry
	return indexed


static func _godot_pose_valid(joint: Dictionary) -> bool:
	var flags := int(joint.get("flags", 0))
	return (flags & GODOT_FLAG_ROTATION_VALID) != 0 \
		and (flags & GODOT_FLAG_POSITION_VALID) != 0
