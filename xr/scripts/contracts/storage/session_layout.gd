class_name SessionLayout
extends RefCounted
## v2 contracts/storage (WP5): on-disk session directory layout constants.
## A recording is self-contained beneath <capture_root>/<session_id>/ so it
## can be copied, uploaded, or deleted as one unit. Readers still accept the
## historical sibling MP4 layout for existing recordings.

const DEFAULT_CAPTURE_ROOT := "/sdcard/DCIM/SpatialMP4"

const POSES_DIR := "poses"
const BODY_MOTION_DIR := "body_motion"
const DEPTH_DIR := "depth"
const DEPTH_RAW_DIR := "depth/raw"

const MANIFEST_FILENAME := "manifest.json"
const ANDROID_TIMEBASE_JSON := "android_timebase.json"
const LEFT_CAMERA_CHARACTERISTICS_JSON := "left_camera_characteristics.json"
const RIGHT_CAMERA_CHARACTERISTICS_JSON := "right_camera_characteristics.json"
const LEFT_CAMERA_FRAMES_JSONL := "left_camera_frames.jsonl"
const RIGHT_CAMERA_FRAMES_JSONL := "right_camera_frames.jsonl"
const HEAD_JSONL := "poses/head.jsonl"
const CONTROLLERS_JSONL := "poses/controllers.jsonl"
const HANDS_JSONL := "poses/hands.jsonl"
const BODY_JOINTS_JSONL := "body_motion/body_joints.jsonl"
const MOTION_TRACKERS_JSONL := "body_motion/motion_trackers.jsonl"
const DEPTH_FRAMES_JSONL := "depth/frames.jsonl"

## Every fixed-name opt-in JSON/JSONL mirror. SessionSpoolWriter inventories
## these in manifest.json and EgoUploader uploads the ones that are present.
## Raw depth dumps are intentionally excluded because they are an unbounded
## directory of binary diagnostic frames rather than sidecar metadata.
const DEBUG_SIDECAR_ARTIFACTS := [
	{"kind": "android_timebase", "filename": ANDROID_TIMEBASE_JSON},
	{"kind": "left_camera_characteristics", "filename": LEFT_CAMERA_CHARACTERISTICS_JSON},
	{"kind": "right_camera_characteristics", "filename": RIGHT_CAMERA_CHARACTERISTICS_JSON},
	{"kind": "left_camera_frames", "filename": LEFT_CAMERA_FRAMES_JSONL},
	{"kind": "right_camera_frames", "filename": RIGHT_CAMERA_FRAMES_JSONL},
	{"kind": "head_pose", "filename": HEAD_JSONL},
	{"kind": "controller_pose", "filename": CONTROLLERS_JSONL},
	{"kind": "hand_joints_sidecar", "filename": HANDS_JSONL},
	{"kind": "body_joints_sidecar", "filename": BODY_JOINTS_JSONL},
	{"kind": "motion_trackers_sidecar", "filename": MOTION_TRACKERS_JSONL},
	{"kind": "depth_frames_sidecar", "filename": DEPTH_FRAMES_JSONL},
]

## Filenames within <capture_root>/<session_id>/.
const FINAL_MP4_PATTERN := "%s.mp4"
const PARTIAL_MP4_PATTERN := "%s.partial.mp4"
const DEPTH_RAW_FRAME_PATTERN := "frame_%05d.u16"


static func final_mp4_name(session_id: String) -> String:
	return FINAL_MP4_PATTERN % session_id


static func partial_mp4_name(session_id: String) -> String:
	return PARTIAL_MP4_PATTERN % session_id


static func final_mp4_path(session_dir: String, session_id: String) -> String:
	return session_dir.path_join(final_mp4_name(session_id))


static func partial_mp4_path(session_dir: String, session_id: String) -> String:
	return session_dir.path_join(partial_mp4_name(session_id))
