# PICO 4 Ultra Controller Profile and Pose Fallback

Date: 2026-07-17

## Bug

Quest controllers worked, but PICO 4 Ultra controllers could not drive the
Operator pointer or UI. The PICO system service reported tracked controllers
and trigger values reached Godot, yet the `XRController3D` pointer nodes stayed
inactive and untracked.

## Cause

The failure had two independent PICO compatibility gaps:

- Device model `A9210` is PICO 4 Ultra. Its OpenXR interaction profile is
  `/interaction_profiles/bytedance/pico4s_controller`, while the action map
  only declared `/interaction_profiles/bytedance/pico4_controller`.
- After adding the correct profile, the PICO runtime exposed `default` and
  `grip` poses but no `aim` pose for the controller tracker. Quest exposes both
  `default` and `aim` for the same action-map layout. Operator hardcoded its
  pointer nodes to `pose = "aim"`, so `XRController3D` remained inactive even
  though controller tracking and button input were valid.

Input arbitration made the symptom worse. It required an already tracked
pointer pose before controller input could select controller mode, and it could
interpret optical hand data with an unknown tracking source as hand mode. This
created a circular dependency: the missing `aim` pose prevented controller
selection, so valid controller input never became authoritative.

## Fix

- Add the PICO 4 Ultra `pico4s_controller` interaction profile and its pose,
  button, axis, and haptic bindings to the OpenXR action map.
- Prefer `aim` when the runtime provides it, but fall back to `default` for a
  physical controller profile when `aim` is absent. Keep hand interaction on
  `aim`.
- Use the active OpenXR interaction profile as the primary controller-versus-
  hand signal. A physical controller profile and controller input take
  precedence over ambiguous optical-hand data; `hand_interaction` remains
  authoritative for hand mode.
- Recognize button and axis evidence without first requiring a tracked pointer
  pose.
- Base controller capability and haptic routing on the interaction profile
  instead of inferring them from haptics support or hand-joint availability.

## Diagnosis

Debug the input path as separate layers instead of treating "controller does
not work" as one state:

1. Confirm the Android device model and the runtime-selected OpenXR interaction
   profile.
2. Confirm that button and axis actions receive values.
3. Inspect every relevant tracker pose with `has_pose`, `get_pose`, action
   activity, and tracking confidence.
4. Only then inspect pointer-mode arbitration and UI input routing.

On the affected device, the decisive raw pose state was:

```text
poses=d:1/2,a:-,g:1/2
```

`default` and `grip` were active with high tracking confidence, while `aim` did
not exist. At the same time, trigger values were nonzero and PICO's system
service reported controller confidence, proving this was an OpenXR pose/action
selection issue rather than lost hardware tracking.

Do not use haptic availability as a controller detector. It is a capability,
not a reliable statement about which input source currently owns the tracker.

## Validation

Built and installed the PICO APK on PICO 4 Ultra device
`PA9210BGJ3121331D`. Before the pose fallback, runtime diagnostics showed the
correct profile and trigger input but an inactive pointer:

```text
prof=pico4s_controller act=0 trk=0 trig=1.00 poses=d:1/2,a:-,g:1/2
```

After the fix, both controller pointers became active and tracked:

```text
L[act=1 trk=1 prof=pico4s_controller poses=d:1/2,a:-,g:1/2]
R[act=1 trk=1 prof=pico4s_controller poses=d:1/2,a:-,g:1/2]
```

The PICO export completed successfully, and the XR feature and test-manifest
static validators passed.

## Reusable Rule

OpenXR interaction profiles and semantic pose names are runtime-specific
contracts, not universal guarantees. Declare the exact target-device profile,
query whether a pose actually exists, and provide a deliberate fallback for
equivalent controller poses. Keep hand/controller arbitration independent from
the pose that will be selected after the mode is known.
