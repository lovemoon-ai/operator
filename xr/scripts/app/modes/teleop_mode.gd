class_name TeleopMode
extends "res://scripts/app/modes/teleop_controller.gd"
## v2 app/modes (WP6): thin scene-lifecycle entry point for the teleop mode
## (feature: operator_feature_mode_teleop).
##
## scenes/teleop_main.tscn attaches this v2 mode script. It inherits the
## legacy base scene controller for behavior compatibility; the
## command-emission stack it builds comes from app/composition/teleop_composition.gd.
