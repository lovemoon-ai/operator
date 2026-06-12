class_name LiveFeedMode
extends "res://scripts/capture_app.gd"
## v2 app/modes (WP6): thin scene-lifecycle entry point for the live-feed
## mode (feature: operator_feature_mode_live_feed).
##
## Live feed is the capture scene with `capture_sink = "server"` (today set
## as a scene override in scenes/live_feed_app.tscn, which keeps
## capture_app.gd attached directly for behavior compatibility). The
## composed stack comes from app/composition/live_feed_composition.gd.
## This subclass pins the sink choice for the named v2 module surface.


func _init() -> void:
	capture_sink = "server"
