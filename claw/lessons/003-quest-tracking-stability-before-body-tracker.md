# Quest Tracking Stability Before Body Tracker

## Symptom

Launching ego capture with `operator.body_pose_debug=true` on Quest can bring
up a Guardian/system dialog before the Operator app becomes interactive.
Observed logs included:

- `Launch is blocked because: a Guardian dialog is currently showing`
- `TrackingService: Notifying idle due to no 6dof tracking for an extended time`
- `XR_ERROR_INITIALIZATION_FAILED` from early body pose sampling

## Cause

Quest may still report no reliable 6DoF head tracking for a few seconds after
process launch. Starting body pose debug, body tracking, RGB camera, or audio in
that window can make vrshell/Guardian take focus, which pauses Operator and can
prevent the debug overlay from ever showing.

This was already known in the e2e harness: `cicd/02_ego_record.sh` injects a
CI-only wait for head-pose tracking confidence before auto-starting capture.

## Fix

Production auto-start paths now wait for the XR head pose to report tracking
confidence other than `NONE` for 0.75s before starting sensitive capture/debug
resources. The wait times out after 15s and skips the automatic start instead of
starting while tracking is still lost.

Keep the `AUTO_START_FOR_DEVICE_TEST` source branch text stable unless the test
script is updated too; that script still patches the branch directly.

## Validation Note

If a plain ego-mode launch, with no body-pose debug and no recording, still
gets preempted by `GuardianDialogActivity` while logs repeat
`Checking 0 existing guardian data`, the remaining blocker is the headset's
Guardian/boundary state. Clear or complete that dialog in-headset before
attributing the focus loss to Operator body/camera initialization.
