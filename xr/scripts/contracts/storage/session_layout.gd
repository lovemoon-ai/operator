class_name SessionLayout
extends RefCounted
## v2 contracts/storage (WP5): on-disk session directory layout constants.
## A recording is self-contained beneath <capture_root>/<session_id>/ so it
## can be copied, uploaded, or deleted as one unit. Readers still accept the
## historical sibling MP4 layout for existing recordings.

const DEFAULT_CAPTURE_ROOT := "/sdcard/DCIM/SpatialMP4"

const DEPTH_DIR := "depth"

const MANIFEST_FILENAME := "manifest.json"

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
