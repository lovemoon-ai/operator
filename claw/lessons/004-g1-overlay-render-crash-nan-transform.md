# G1 Overlay Render-Thread Crash (NaN Transform)

Date: 2026-06-17

## Symptom

While the in-headset G1 retarget overlay (`xr/scripts/robot_constraint/robot/
g1_overlay.gd`) was shown and driven by live body tracking, the app crashed
**intermittently** — uptime at crash varied widely (~10s to ~600s). Every
tombstone was the same native Vulkan render-thread fault:

```
Fatal signal 11 (SIGSEGV), fault addr 0x68, tid=VkThread
Cause: null pointer dereference
  VkThread.run -> onVkDrawFrame -> GodotLib_step -> (deep 3-function
  recursive scene-cull traversal) -> null deref
```

`libgodot_android.so` is stripped (0 symbols), so the frames could not be
resolved to function names.

## Cause

The signature — **intermittent**, on the **render thread**, in the **scene-cull
traversal**, **null deref** — is the textbook symptom of a non-finite (NaN/inf)
transform poisoning the renderer's spatial structure:

1. Live body tracking occasionally yields degenerate/missing joints.
2. The frozen-base GMR IK solver can diverge on a bad input frame and return a
   **non-finite qpos**.
3. `_apply_qpos` wrote that straight into a GLB link node's `Transform3D`, so the
   node's AABB became NaN.
4. A NaN AABB corrupts the renderer's cull tree (BVH/octree). The crash then
   happens on a **later** draw frame when traversal reaches the bad node — which
   is exactly why the time-to-crash varied so much (it depends on when a bad
   tracking frame occurs, not on the draw that crashes).

The earlier qpos joint-mapping off-by-one (see "Related") produced *wrong but
finite* angles and was a separate (pose) bug, not the crash source.

## Fix

Never let a non-finite value reach a node transform:

- `_apply_qpos`: if any qpos entry is non-finite, **drop the whole frame**
  (`for v in qpos: if not is_finite(v): return`).
- `_canonical_pose`: reject non-finite tracking samples at read time so NaN/inf
  cannot enter the IK targets either.
- Secondary mitigation: overlay meshes set `cast_shadow = SHADOW_CASTING_SETTING_
  OFF` (an overlay should not cast shadows anyway; this also drops the
  shadow-mesh render path, another common source of this crash class).

After these changes the G1 overlay was toggled on/off repeatedly over several
minutes of live use with **0 crashes**.

## Diagnostic method (reusable)

What unblocked this was reproducing the on-device render path **offline**, with
no device and no XR:

- Godot's glTF import is deterministic, so a throwaway headless project
  (`godot --headless -s probe.gd`) that `load()`s the same GLB and reads each
  node's `transform` reproduces exactly what the overlay sees at runtime. This
  let us confirm Godot's imported link transforms match the raw glTF (and later
  replicate the full `_parse_mocap_joints` + `_apply_qpos` FK and diff it against
  MuJoCo) entirely offline. This is the fastest way to debug "renders wrong on
  device but the numbers are right" without the reship→headset loop.
- Stripped release `libgodot_android.so` cannot be symbolicated; do not burn time
  on addr2line. Reason from the crash *signature* instead.
- A dump written in a node's `_ready` lands **before** its first render frame, so
  it survives a later render crash — but Godot `user://` on Android is the
  app-internal dir and is **not** reachable by a plain `adb pull`. Write debug
  dumps to an external path (e.g. `/sdcard/DCIM/...`) instead.
- `Basis` has no `get_column()` in Godot 4.5.1 GDScript; use `basis.x/.y/.z`
  (the column vectors).

## Caveats

- The original crash was intermittent up to ~600s, so a few minutes of no-crash
  is strong but not absolute proof. A 10-minute+ soak under live retargeting is
  worth running before calling it fully closed.
- Several changes shipped together (NaN guards, `cast_shadow` off, the qpos
  off-by-one fix), so the crash fix is not isolated to a single line with
  certainty. The NaN guard is the highest-confidence cause/fix by mechanism.

## Related

Same investigation also fixed a qpos joint-mapping off-by-one: `_parse_mocap_
joints` scanned the whole MJCF and counted the `<default>` block's `<joint>`
template (no enclosing `<body>`), yielding 30 joints instead of 29 and shifting
every `qpos[7+i]` by one (tilted torso / flailing arms). Fix: only parse joints
inside a `<body>` (non-empty body stack). Verified in headless Godot: torso
orientation vs MuJoCo went to 0.0000°, and on-device logs report `29 qpos
joints`.
