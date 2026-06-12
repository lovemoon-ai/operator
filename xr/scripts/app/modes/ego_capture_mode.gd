class_name EgoCaptureMode
extends "res://scripts/capture_app.gd"
## v2 app/modes (WP6): thin scene-lifecycle entry point for the ego-capture
## mode (feature: operator_feature_mode_ego_capture).
##
## The mode's behavior lives in:
##   - scripts/capture_app.gd        — intent-extra parsing, UI glue, the
##     AUTO_START_FOR_DEVICE_TEST patch point (its file path is
##     load-bearing for tests/02_ego_record.sh; do not retire it);
##   - app/composition/ego_capture_composition.gd — what gets composed.
##
## scenes/capture_app.tscn keeps capture_app.gd attached directly for
## behavior compatibility; this subclass is the named v2 module surface
## (mode drivers / future scene migration target). It adds no behavior.
