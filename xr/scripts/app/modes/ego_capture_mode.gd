class_name EgoCaptureMode
extends "res://scripts/app/modes/capture_app_base.gd"
## v2 app/modes (WP6): thin scene-lifecycle entry point for the ego-capture
## mode (feature: operator_feature_mode_ego_capture).
##
## The mode's behavior lives in:
##   - scripts/app/modes/capture_app_base.gd — intent-extra parsing, UI glue,
##     and the AUTO_START_FOR_DEVICE_TEST patch point used by
##     tests/02_ego_record.sh;
##   - app/composition/ego_capture_composition.gd — what gets composed.
##
## scenes/capture_app.tscn attaches this v2 mode script. It still inherits the
## legacy base controller for behavior compatibility while composition moves
## behind app/composition.
