class_name LiveFeedMode
extends "res://scripts/app/modes/capture_app_base.gd"
## v2 app/modes (WP6): thin scene-lifecycle entry point for the live-feed
## mode (feature: operator_feature_mode_live_feed).
##
## Live feed is the capture scene with `capture_sink = "server"`.
## scenes/live_feed_app.tscn attaches this v2 mode script; the composed stack
## comes from app/composition/live_feed_composition.gd. This subclass pins the
## sink choice for the named v2 module surface.


func _init() -> void:
	capture_sink = "server"
