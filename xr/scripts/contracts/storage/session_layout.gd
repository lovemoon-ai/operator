class_name SessionLayout
extends RefCounted
## v2 contracts/storage (WP5): on-disk session directory layout constants.
## Values are copied verbatim from the historical session_spool_writer.gd
## paths — changing any of them breaks offline tooling
## (SpatialMP4/scripts/godot_spool_pack.py, read_mett_pose.py, e2e tests).

const DEFAULT_CAPTURE_ROOT := "/sdcard/DCIM/SpatialMP4"

const POSES_DIR := "poses"
const BODY_MOTION_DIR := "body_motion"
const DEPTH_DIR := "depth"
const DEPTH_RAW_DIR := "depth/raw"

const MANIFEST_FILENAME := "manifest.json"
const HEAD_JSONL := "poses/head.jsonl"
const CONTROLLERS_JSONL := "poses/controllers.jsonl"
const HANDS_JSONL := "poses/hands.jsonl"
const BODY_JOINTS_JSONL := "body_motion/body_joints.jsonl"
const MOTION_TRACKERS_JSONL := "body_motion/motion_trackers.jsonl"
const DEPTH_FRAMES_JSONL := "depth/frames.jsonl"

## <capture_root>/<session_id>.mp4 (final) / <session_id>.partial.mp4
const FINAL_MP4_PATTERN := "%s.mp4"
const PARTIAL_MP4_PATTERN := "%s.partial.mp4"
const DEPTH_RAW_FRAME_PATTERN := "frame_%05d.u16"


static func final_mp4_name(session_id: String) -> String:
	return FINAL_MP4_PATTERN % session_id


static func partial_mp4_name(session_id: String) -> String:
	return PARTIAL_MP4_PATTERN % session_id
