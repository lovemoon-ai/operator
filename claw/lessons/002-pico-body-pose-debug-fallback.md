# Pico Body Pose Debug Fallback

Date: 2026-06-12

## Bug

On Pico, the "Show VR Body Pose" debug overlay showed blue points but did not
use real Pico body pose data. Quest worked.

## Cause

There were two Pico-specific failure modes:

- The debug provider ran in `AUTO` mode. When Pico `XR_BD_body_tracking` had not
  started or returned no valid canonical joints, `BodyPoseProvider` fell back to
  `FallbackBodyAdapter`, which only renders HMD/controller-derived points. That
  made fallback data look like body tracking.
- After starting Pico body tracking, the runtime can still return 24 joints with
  `status=INVALID` and every raw joint at the same position. That renders as one
  blue point but is not real body pose data.
- The app defaulted `max_motion_trackers` to 3. PICO's basic body tracking setup
  uses two ankle trackers; requesting 3 while only two are connected leaves the
  runtime in a mismatched setup state.
- The body-pose debug path also called `request_motion_trackers`. On Pico this
  requests independent/object tracker mode, not full-body capture mode, so the
  runtime logs `object_tracking` and body joints remain invalid or fake.

Pico body pose must use the vendor body-tracking path: start body tracking and,
when needed, open the body tracking calibration app. Independent motion tracker
requests are a different mode. Quest gets body pose through Godot's
`XRBodyTracker` from the Meta runtime, so it does not need this Pico-specific
setup.

## Fix

- Use `PICO_ONLY` source mode for Pico body-pose debug overlays.
- Start Pico body tracking when the debug overlay is opened.
- Do not call `request_motion_trackers` while Pico body tracking is enabled.
  Recording disables independent motion-tracker sampling when
  `record_body_tracking` is on, keeping the runtime in full-body capture mode.
- Open Pico body-tracking setup when the runtime reports no joints, no motion
  trackers, invalid body state, or calibration/tracker-state messages.
- Accept Pico position-only joints and use identity rotation when orientation
  is missing.
- Log Pico body diagnostics from `BodyPoseProvider`, including body status,
  raw joint span, and sample raw joint positions.
- Ignore Pico samples while body state is invalid or raw joint span is collapsed
  so a single blue point is not mistaken for a real skeleton.
- Default Pico motion tracker requests to 2. Keep the internal max at 3 so an
  explicit waist-tracker configuration can still request the third tracker later.

## Validation

Built and installed the Pico APK on device `PA9210BGJ3121331D`. Logcat showed
the old false-positive state:

- `Pico body tracking started for debug overlay`
- `Pico body source online ... joints=24 ... motion_trackers=3`
- `BodyPoseDebugOverlay ... visible_points=24/86`

After adding invalid-state filtering, the same device reported the real cause:

- `status=INVALID(0)`
- `raw_span=0.0000`
- `raw_sample=[#0:Dictionary:(0.0, 1.65, 0.0), ...]`

The app now suppresses the fake single point and waits for Pico body tracking to
become `VALID` or `LIMITED` before rendering.

After changing the default request count, logcat on the Pico device showed:

- `motion_tracker_count=2`
- `requested_motion_tracker_count=2`
- still `status=INVALID(0)` and `raw_span=0.0000`

At that point the app-side tracker count was correct; any remaining failure was
on the PICO Motion Tracker calibration/body-output side rather than the overlay
or fallback path.

After removing the independent tracker request, the Pico device reported the
expected full-body path:

- PICO system logs included `tracking_mode: "full_body_tracking"` and
  `tracker_wear_mode: "2tk_basic"`.
- App status showed `motion_request_sent=false` and
  `requested_motion_tracker_count=0`.
- `BodyPoseProvider` received real Pico body data:
  `status=LIMITED(2)`, `message=TRACKING_POSE_ERROR(7)`, `joints=24`,
  `raw_span` around 1 metre.
- `BodyPoseDebugOverlay` rendered `visible_points=24/86`.

`LIMITED` plus `TRACKING_POSE_ERROR` means the runtime is producing real body
pose data but still reports a quality/calibration/posture problem. That should
be handled through the Pico body tracking calibration flow, not by switching to
independent tracker mode.
