# Pico Body-Hand Bridge Known Issue

Status: fixed

Date noted: 2026-06-12
Date fixed: 2026-06-13

## Context

`web/app/scripts/spatialmp4_to_rrd.py` now preserves Quest/Godot body-track
`HAND`, `PALM`, and `WRIST` endpoints and adds an extra visual bridge from
body-track endpoints to the dedicated OpenXR hand-joint stream.

The current bridge map is specific to the Godot XRBodyTracker 87-joint body
skeleton used by Quest/Meta captures:

- left body wrist/palm ids: `24`, `23`
- right body wrist/palm ids: `51`, `50`
- OpenXR hand stream wrist/palm ids: `1`, `0`

## Issue

The bridge logger is currently called for all body skeletons. Pico BD-24 uses a
different joint-id table, where body joint id `23` is `RIGHT_HAND`, not
`LEFT_PALM`. If the Godot/Quest bridge map runs on Pico BD-24 captures, it can
draw an incorrect connector from the Pico right-hand endpoint to the left-hand
OpenXR stream.

## Impact

Quest 3 / Quest 3S captures are not affected because they use the Godot/Meta
87-joint skeleton that matches the bridge map.

Pico captures can show misleading body-to-hand connector lines in Rerun if both
body tracking and hand tracking are present.

## Proposed Fix

Gate body-to-hand bridge logging by the active body skeleton:

- enable `GODOT_XR_BODY_TO_HAND_BRIDGES` only for the Godot/Meta 87-joint
  skeleton
- use an empty bridge map for Pico BD-24 unless a Pico-specific mapping is
  added

A clean implementation would make `_body_skeleton_for_manifest()` return the
bridge map alongside `(joint_names, bones, hidden_hand_joint_ids)`, then pass
that active bridge map into the bridge logger.

## Notes

Fixed by making `_body_skeleton_for_manifest()` return the active body-to-hand
bridge map with the selected body skeleton. Godot/Meta 87-joint captures keep
`GODOT_XR_BODY_TO_HAND_BRIDGES`; Pico BD-24 captures use an empty bridge map.
