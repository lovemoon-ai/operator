# G1 Retargeting Overlay — Integration Problems & Fixes

Date: 2026-06-18

Bringing up the in-headset Unitree G1 retarget overlay
(`xr/scripts/robot_constraint/robot/g1_overlay.gd`, driven by the
`DuinoDu/retargeting` GMR toolkit via the `godot_retargeting` GDExtension)
surfaced a chain of bugs. The retargeting *result* (qpos) was repeatedly correct
offline yet the headset looked wrong — the gap was always in how the live VR pose
was fed in, how qpos was rendered, or how the solver resolved redundancy.

## Bugs and fixes (in the order they bit)

1. **Joint-slot mismatch (flailing arms).** The GMR ik_config keys
   (`LeftShoulder`, `Chest`, …) are *semantic slots*, not literal joints. The
   validated offline extractor fills `*Shoulder` from `*_upper_arm` and `Chest`
   from `upper_chest`; the overlay's `JOINT_MAP` preferred the clavicle
   (`left_shoulder`) and `chest`. The clavicle sits near the spine and collapses
   shoulder width → arm IK off by tens of degrees. Fix: match the extractor's
   candidate order (`*_upper_arm` / `upper_chest` first).

2. **qpos joint-mapping off-by-one (torso tilt / wrong pose).** `_parse_mocap_
   joints` scanned the whole MJCF and counted the `<joint>` in the `<default>`
   block (no enclosing `<body>`), yielding 30 joints not 29 and shifting every
   `qpos[7+i]` by one. Fix: only parse joints inside a `<body>` (non-empty body
   stack). See lesson 004 for how this was localized.

3. **Orientation matters even for position tasks.** The SE3 IK error couples the
   position residual to the target rotation (`v = V⁻¹(ω)·t`). Feeding identity
   quaternions gives visibly wrong arm angles, and a *position-only* skeleton
   visualization hides orientation noise. The overlay must feed real, converted +
   heading-anchored quaternions (wxyz `[0.5,0.5,-0.5,-0.5]` openxr→gmr ⊗ q).

4. **Jitter from a redundant DoF.** Smooth input → jittery qpos. The arm swivel
   (shoulder_yaw / upper-arm roll) is under-constrained by position-only
   wrist/elbow tasks, so the solver wanders. *Orientation smoothing did not help*
   (the "identity drops jitter" earlier reading was a pose artifact). Two fixes:
   - **Solver posture task** (source fix): a small null-space regularization
     toward `qpos0`. Offline: chest jitter −49%, and it also fixes the asymmetry
     below. Opt-in via ik_config `posture_weight` (default 0 keeps the original
     Python-aligned behavior + verification).
   - **dt-aware output filter** (residual): EMA toward target + per-frame velocity
     cap, using real inter-frame `dt` so offline-tuned `tau`/`vmax` transfer to
     the device's ~60 Hz. Tune live against the cyan skeleton.

5. **Symmetric input → asymmetric output.** A perfectly symmetric VR pose
   (heading seeds to 0) produced asymmetric arms — same root as the jitter: the
   redundant shoulder_yaw resolves inconsistently L/R. The posture task cut the
   gross asymmetry ~85% (shoulder-yaw L+R −194° → −28°, elbow Δ 38° → 2.5°).
   *Residual ~25° upper-arm-roll asymmetry remains* (a weakly-constrained soft
   mode that amplifies tiny numerical/orientation asymmetries; the model, the
   ik_config, and the exact box-QP are all symmetric). Accepted: it only shows in
   synthetic symmetric poses; real teleop tracks hand *positions* fine.

6. **Constant torso-yaw offset.** `heading_yaw` was seeded once from a single
   startup frame's shoulder line (arm-pose-dependent). Fix: average the
   shoulder-line direction over the first ~20 valid frames; re-seed by toggling
   the overlay while squared to forward.

7. **Feet floating.** The ground was inferred from robot height (rode with the
   world-locked pelvis). Fix: read the real floor from the XR origin (the OpenXR
   reference space is floor-referenced → floor Y = `XROrigin3D` world Y) and
   anchor the pelvis at `floor + foot-below-pelvis (0.792 m)` so the feet stand on
   the real floor.

8. **Intermittent render crash.** See lesson 004 (NaN/inf transform guards).

## Debugging methods that worked (reusable)

- **Reproduce the on-device render path offline in headless Godot.** Godot's
  glTF import is deterministic, so a throwaway project that `load()`s the same GLB
  and runs the overlay's exact `_parse_mocap_joints` + `_apply_qpos` reproduces
  the device FK without a headset. This found the off-by-one and proved the FK
  matches MuJoCo (0°). Also parse-check edited GDScript by `load()`-ing it.
- **Render the VR pose beside the robot** (cyan IK-target skeleton, same anchored
  frame). Isolates input jitter (tracking) from output jitter (solver), because
  the GLB FK is a pure function of qpos.
- **Fixed symmetric pose** to separate heading bias from downstream IK. But:
  drive it with *real* per-joint orientations — identity quats corrupt absolute
  arm angles (#3), so a fixed-pose test is only valid for *symmetry*, not
  absolute pose, unless real orientations are used.
- **Validate solver changes offline first** against the checked-in reference
  (`upper_body_demo --verify`) so Python alignment / verification is preserved;
  make new behavior opt-in via the ik_config.
- **`adb shell am broadcast -a com.oculus.vrpowermanager.prox_close`** spoofs the
  Quest proximity sensor as "worn" (`sys.hmt.mounted` → 1) so a build can be
  launched/screenshotted without wearing it. Caveat: it does **not** provide real
  6DoF tracking, so immersive overlays that gate on tracking-stable still need the
  headset actually worn.

## Gotchas

- Godot 4.5.1 GDScript `Basis` has no `get_column()`; use `basis.x/.y/.z`.
- `user://` on Android is app-internal — not reachable by plain `adb pull`. Write
  debug dumps to an external path (e.g. `/sdcard/DCIM/...`).
- Per-frame filters (EMA/velocity cap) must be dt-aware: offline data is 30 fps,
  device retargeting ~60 Hz with variable timing.
