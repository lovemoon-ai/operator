class_name TeleopMode
extends "res://scenes/main.gd"
## v2 app/modes (WP6): thin scene-lifecycle entry point for the teleop mode
## (feature: operator_feature_mode_teleop).
##
## scenes/teleop_main.tscn keeps scenes/main.gd attached directly for
## behavior compatibility; the command-emission stack it builds comes from
## app/composition/teleop_composition.gd. This subclass is the named v2
## module surface and adds no behavior.
