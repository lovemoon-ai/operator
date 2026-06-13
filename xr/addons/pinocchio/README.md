# pinocchio (Godot 4 GDExtension)

Rigid-body kinematics + dynamics for the operator XR client, backed by
[stack-of-tasks/pinocchio](https://github.com/stack-of-tasks/pinocchio)
cross-compiled to Android arm64 via
[DuinoDu/pinocchio-android](https://github.com/DuinoDu/pinocchio-android).

What you get from GDScript:

- `PinocchioModel` — build a rigid-body tree by hand (no URDF parser
  needed): revolute / prismatic joints, body inertias, operation frames,
  gravity, position limits.
- `PinocchioData` — algorithms that take `(model, q[, v, a, τ])`:
  forward kinematics, frame Jacobian (LOCAL / WORLD / LOCAL_WORLD_ALIGNED),
  damped-least-squares IK, RNEA, generalized gravity, ABA, CRBA,
  centroidal momentum.
- `PinocchioRuntime` — version probe + smoke test, for verifying that
  the addon actually loaded on a device.
- `PinocchioMultiTaskSolver` — V2 multi-task weighted QP IK. Drives
  several end-effectors (pose, position-only, orientation-only) plus
  scalar joint targets in a single LDLT solve, with posture +
  smoothness regularization. See §5 below.

Verified on Meta Quest 3 (Vulkan, Adreno 740). Targets Godot 4.5.1.stable.

---

## 1. Status (V1)

V1 is intentionally a **core robotics** subset — what teleop / retargeting
actually needs first — built on a Pinocchio install that has these
features compiled **off**:

| Off in V1 | Why | Cost |
|---|---|---|
| URDF / SDF parsing | URDFDom isn't on Android in vcpkg | Models must be defined by hand or generated from your own format |
| Collision queries (Coal/HPP-FCL) | Needs urdfdom + extra deps | No `pinocchio::computeCollisions` |
| Python bindings | XR client is C++ / GDScript | n/a |
| CasADi / autodiff / codegen | Off-target for V1 | No analytical-Jacobian via CasADi |
| OpenMP | Android NDK toolchain | Single-threaded algorithms |

Free-floating (6-DoF root) joints **are not yet supported** at the
binding layer — only 1-DoF scalar joints (revolute, prismatic) are
exposed. That covers most robot arms and the bench-scale models we
care about right now; adding a free-floating root means swapping the
IK retract step from `q += dq` to `pinocchio::integrate(...)` against a
real Lie-group retraction.

---

## 2. Architecture

```
GDScript / Godot scene
        │
        ▼
addons/pinocchio/pinocchio.gdextension      ← manifest, declares android.arm64
        │  loads
        ▼
addons/pinocchio/libpinocchio_gd.so         ← ~1.7 MB wrapper (this addon)
        │  links against
        ▼
addons/pinocchio/libpinocchio_default.so    ← ~6.1 MB Pinocchio core
        │  (built once via xr/makefiles/Makefile.pinocchio)
        ▼
pinocchio-android       — pinned in scripts/sync_deps.sh
        │  (vcpkg-based: Eigen3 + Boost cross-compiled for arm64-android)
        ▼
stack-of-tasks/pinocchio (upstream)
```

Source layout:

```
xr/addons/pinocchio/
├── pinocchio.gdextension      manifest
├── libpinocchio_gd.so         wrapper (built artifact, gitignored)
└── libpinocchio_default.so    core   (built artifact, gitignored)

xr/native/godot_pinocchio/
├── CMakeLists.txt             builds libpinocchio_gd.so
├── build.sh                   thin wrapper that calls cmake
└── src/
    ├── register_types.cpp     GDExtension entry point
    ├── pinocchio_runtime.{h,cpp}   PinocchioRuntime (version + smoke probe)
    ├── pinocchio_model.{h,cpp}     PinocchioModel
    ├── pinocchio_data.{h,cpp}      PinocchioData
    └── eigen_godot.h               Vector3/Transform3D <-> Eigen + SE3

xr/makefiles/Makefile.pinocchio
                               sentinel-based build of libpinocchio_default.so
                               (mirrors Makefile.ffmpeg)

scripts/sync_deps.sh           pins DuinoDu/pinocchio-android (and friends)
```

---

## 3. Prerequisites

| Tool | Version | Why |
|---|---|---|
| Android NDK | r26 or newer (r27 tested) | C++17 + Eigen need recent clang |
| vcpkg | any recent | Cross-compiles Eigen3 + Boost for `arm64-android` |
| CMake | 3.22+ | Build system |
| Ninja | any | CMake generator used by `build-android.sh` |
| Godot | 4.5.1.stable | Demo project / GDExtension contract |
| Godot Android export templates | 4.5.1.stable | Editor → Manage Export Templates |
| adb | any | Device install / logcat |

Environment:

```bash
export ANDROID_NDK=$ANDROID_HOME/ndk/27.1.12297006   # or wherever
export VCPKG_ROOT=$HOME/ws/vcpkg                      # one-time clone + bootstrap
```

vcpkg setup (one-time, ~3 min):

```bash
git clone https://github.com/microsoft/vcpkg ~/ws/vcpkg
~/ws/vcpkg/bootstrap-vcpkg.sh -disableMetrics
```

---

## 4. Build

Two-stage. **Stage 1** cross-compiles the Pinocchio core (slow first
run, ~10–20 min because vcpkg installs Eigen3 + Boost), **stage 2**
builds the thin wrapper that Godot loads.

```bash
# One-time: pull pinned third-party checkouts (godot-cpp, pinocchio-android, etc.)
make -C xr deps

# Stage 1 — libpinocchio_default.so + headers
make -C xr build-pinocchio

# Stage 2 — libpinocchio_gd.so wrapper (this addon)
make -C xr build-pinocchio-gdext
```

Both targets are idempotent; re-runs are seconds.

Outputs (both `xr/addons/pinocchio/` and `xr/android/build/libs/arm64-v8a/`):

```
libpinocchio_default.so   ~6.1 MB
libpinocchio_gd.so        ~1.7 MB
```

The duplication is intentional: Godot's GDExtension loader needs the
`.so` under `res://addons/...` at runtime, and the gradle Android
export pipeline needs it under `android/build/libs/<abi>/` at packaging
time. The xr `build.sh` does both copies automatically.

To use this addon in a Godot project, the project's APK build just
needs both `.so` files staged into its `android/build/libs/release/arm64-v8a/`
(or symlinked). See `examples/pinocchio_demo/Makefile` for a worked
example using gradle_build.

---

## 5. API reference

All three classes inherit `RefCounted` — no manual `free()` needed.

### `PinocchioModel`

```gdscript
# Construction (returns joint id or -1 on bad input)
int  add_revolute_joint(parent_id, name, axis, placement, lower_q, upper_q)
int  add_prismatic_joint(parent_id, name, axis, placement, lower_q, upper_q)

# Returns the new frame id (or -1)
int  add_frame(parent_joint_id, name, placement)

# Attach a body to a joint (mass + COM + diag(I))
void append_body_to_joint(joint_id, mass, com: Vector3, inertia_diag: Vector3)

# Gravity is (0, 0, -9.81) by default — change with this
void set_gravity(g: Vector3)

# Queries
int  get_nq(), get_nv(), get_njoints(), get_nframes()
int  get_frame_id(name), get_joint_id(name)
int  get_frame_previous_frame(frame_id)         # parent frame index
PackedFloat64Array get_neutral_q()              # all zeros for scalar joints
PackedFloat64Array get_joint_lower_limits()
PackedFloat64Array get_joint_upper_limits()
PackedFloat64Array project_to_joint_limits(q)   # element-wise clamp
```

Notes:
- `parent_id = 0` means "root from the world frame" (Pinocchio's
  universe is joint 0).
- `axis` is auto-normalized; a zero vector returns `-1` with a logcat
  warning rather than NaNs.
- Joint indices and frame indices are independent. Every joint added
  via the wrappers above also gets a matching `JOINT_FRAME` registered
  (Pinocchio 4 dropped this auto-registration; the wrapper restores it).

### `PinocchioData`

```gdscript
bool       initialize(model: PinocchioModel)     # call this once

# Kinematics — call forward_kinematics first, then read transforms
void       forward_kinematics(q)
Transform3D get_frame_transform(frame_id)
Transform3D get_joint_transform(joint_id)

# 6 x nv Jacobian, flattened row-major (length 6 * nv)
PackedFloat64Array compute_frame_jacobian(
    q, frame_id,
    reference_frame := PinocchioData.LOCAL_WORLD_ALIGNED)

# Damped least-squares IK
# Returns { "q": PackedFloat64Array, "success": bool,
#           "iterations": int, "residual": float }
Dictionary solve_ik_dls(target: Transform3D, frame_id, q0,
                        max_iters := 400, eps := 1e-6, damping := 1e-3)

# Dynamics
PackedFloat64Array rnea(q, v, a)                       # tau (size nv)
PackedFloat64Array compute_generalized_gravity(q)      # g(q) (size nv)
PackedFloat64Array aba(q, v, tau)                      # ddq (size nv)
PackedFloat64Array crba(q)                             # M(q) row-major (nv*nv)

# Centroidal momentum at (q, v)
# Returns { "linear": Vector3, "angular": Vector3, "com": Vector3,
#           "linear_raw": PackedFloat64Array,    # float64 view of linear
#           "angular_raw": PackedFloat64Array,
#           "com_raw": PackedFloat64Array }
Dictionary compute_centroidal_momentum(q, v)
```

Notes:
- `reference_frame` is the bound enum: `PinocchioData.LOCAL`,
  `PinocchioData.WORLD`, `PinocchioData.LOCAL_WORLD_ALIGNED`.
- The DLS step uses α=0.5 internally (slightly conservative
  Gauss-Newton) so it converges reliably from a poor `q0`. Bump
  `max_iters` if you tighten `eps`.
- `crba()` mirrors the upper-triangular result into a fully symmetric
  matrix before returning.
- The `_raw` keys on centroidal momentum exist because Godot's `Vector3`
  is float32 in stock builds; values < ~1.2 × 10⁻⁷ round to bit-exact
  zero in the Vector3 view, which makes a numerical < ε check vacuous.
  Use the `_raw` PackedFloat64Array entries when you actually need
  double precision (control, identity checks).

### `PinocchioRuntime`

```gdscript
String get_pinocchio_version()    # "4.0.0" for the pinned upstream
int    probe_empty_model_nq()     # always 0; proves Eigen/Boost loaded
```

Useful as the very first call from a scene's `_ready()` to verify the
addon actually loaded.

### `PinocchioMultiTaskSolver` (V2)

Weighted-QP IK that solves multiple end-effector tasks simultaneously
in one LDLT factorization per inner iteration. Replaces hand-rolled
GDScript normal-equation assembly for callers that need more than a
single SE(3) target (e.g. dual-arm retargeting).

```gdscript
# 1. Construct + configure (one-time)
var solver := PinocchioMultiTaskSolver.new()
solver.initialize(model, {
    "damping":             3.0e-3,
    "max_iters":           12,
    "step":                0.6,
    "convergence_tol_m":   1.5e-3,
    "convergence_tol_rad": 3.0e-2,
    "posture_weight":      0.04,
    "smooth_weight":       0.08,
    "clamp_to_joint_limits": true,
})

# 2. Register tasks by key (one-time)
solver.add_pose_task("left_wrist",        left_wrist_frame_id)   # 6 rows
solver.add_pose_task("right_wrist",       right_wrist_frame_id)  # 6 rows
solver.add_position_task("left_elbow",    left_elbow_frame_id)   # 3 rows
solver.add_position_task("right_elbow",   right_elbow_frame_id)  # 3 rows
solver.add_joint_scalar_task("chest_yaw", waist_yaw_joint_index) # 1 row
solver.set_posture(q_home)   # PackedFloat64Array of size nq

# 3. Solve per frame (warm-start with q from previous call, dq_prev for smoothness)
var sol := solver.solve(q0, {
    "left_wrist":  { "target": lw_target_xform, "weight_pos": 1.0, "weight_rot": 0.5 },
    "right_wrist": { "target": rw_target_xform, "weight_pos": 1.0, "weight_rot": 0.5 },
    "left_elbow":  { "target": le_target_vec3,  "weight": 0.35 },
    "right_elbow": { "target": re_target_vec3,  "weight": 0.35 },
    "chest_yaw":   { "target": 0.0,             "weight": 0.4  },
}, dq_prev)
# sol = { "q", "dq", "residuals", "iterations", "converged",
#         "joint_limit_saturation", "solve_us" }
```

| Task kind | Rows | Per-frame target | Weight keys |
|---|---|---|---|
| `add_pose_task` | 6 | `Transform3D` (dict `target`) | `weight_pos`, `weight_rot` |
| `add_position_task` | 3 | `Vector3` (bare or dict `target`) | `weight` |
| `add_orientation_task` | 3 | `Transform3D` / `Quaternion` / `Basis` | `weight` |
| `add_joint_scalar_task` | 1 | `float` (bare or dict `target`) | `weight` |

Notes:
- A task whose key is **absent from the per-frame targets dict** contributes
  zero rows that frame — lets the caller degrade gracefully when a tracking
  source drops a joint.
- A task whose **weight is 0** behaves the same way (skipped that frame).
- For revolute joints the scalar task error is wrapped to `[-π, π]` via
  `atan2`-style folding, so a 359° target against a 1° current pose is a
  2° error rather than 358°.
- Orientation targets are re-orthogonalised with HouseholderQR on entry —
  cheap (3×3) protection against accumulated Godot `Basis` drift.
- `solve()` is a pure function of `(q0, targets, dq_prev)`; warm-start is
  the caller's responsibility (thread the previous result's `q` back in
  as `q0`, and `q - q0` as `dq_prev` for the smoothness term).
- The solver is stateful only in its task registration and config — there
  is no `_q` / `_dq_prev` kept inside the C++ object.
- Free-floating roots are explicitly rejected at `initialize()` (same V1
  limit: `nq` must equal `nv`).

---

## 6. Usage examples

### 6a. 2-DOF planar arm

Two revolute joints around +Z, each link 1 m, mass 1 kg.

```gdscript
extends Node

func _ready() -> void:
    var m := PinocchioModel.new()

    # Joint 1: revolute around +Z at the origin, [-π, π]
    var j1 := m.add_revolute_joint(0, "j1", Vector3.BACK,  # +Z in Godot is back
        Transform3D(), -PI, PI)
    m.append_body_to_joint(j1, 1.0, Vector3(0.5, 0, 0),
        Vector3(0.001, 0.083, 0.083))   # thin rod along x

    # Joint 2: revolute around +Z, placed 1 m forward of joint 1
    var place_j2 := Transform3D(Basis(), Vector3(1, 0, 0))
    var j2 := m.add_revolute_joint(j1, "j2", Vector3.BACK, place_j2, -PI, PI)
    m.append_body_to_joint(j2, 1.0, Vector3(0.5, 0, 0),
        Vector3(0.001, 0.083, 0.083))

    # End-effector frame, 1 m forward of joint 2
    var ee := m.add_frame(j2, "ee", Transform3D(Basis(), Vector3(1, 0, 0)))

    m.set_gravity(Vector3(0, -9.81, 0))

    var d := PinocchioData.new()
    assert(d.initialize(m), "PinocchioData failed to bind to model")

    # FK at q = (π/3, -π/6)
    var q := PackedFloat64Array([PI / 3.0, -PI / 6.0])
    d.forward_kinematics(q)
    var ee_pose := d.get_frame_transform(ee)
    print("EE @ q=", q, ": origin=", ee_pose.origin)
```

### 6b. Inverse kinematics

```gdscript
# Solve for q that puts the EE at `target` starting from a zero pose
var target := ee_pose          # reusing the previous FK result
var q0 := m.get_neutral_q()
var res := d.solve_ik_dls(target, ee, q0)

if res["success"]:
    print("IK in %d iters, residual=%f, q=%s" %
        [res["iterations"], res["residual"], res["q"]])
else:
    push_warning("IK did not converge; residual=%f" % res["residual"])
```

### 6c. Jacobian-based velocity tracking

```gdscript
var J: PackedFloat64Array = d.compute_frame_jacobian(q, ee,
    PinocchioData.LOCAL_WORLD_ALIGNED)
# J is 6 × nv row-major: rows 0..2 = linear, rows 3..5 = angular
# To map a joint velocity to EE linear velocity:
var v_x := J[0 * m.get_nv() + 0] * qdot[0] + J[0 * m.get_nv() + 1] * qdot[1]
```

### 6d. Dynamics — gravity compensation

```gdscript
# τ_gc such that the arm holds its pose against gravity at q
var tau_gc := d.compute_generalized_gravity(q)
# Equivalent to: d.rnea(q, PackedFloat64Array([0, 0]), PackedFloat64Array([0, 0]))
```

### 6e. Forward dynamics — what acceleration results from a torque?

```gdscript
var v := PackedFloat64Array([0.0, 0.0])
var tau := PackedFloat64Array([1.0, 0.0])      # 1 N·m on shoulder
var qddot := d.aba(q, v, tau)
print("Joint accelerations: ", qddot)
```

### 6f. Centroidal momentum

```gdscript
var hg := d.compute_centroidal_momentum(q, qdot)
# .linear / .angular are Vector3 (float32) for viz
# .linear_raw / .angular_raw are PackedFloat64Array for math
print("h_g = ", hg["linear_raw"], hg["angular_raw"], " at COM ", hg["com"])
```

---

## 7. Demo project

A standalone test project ships under
`examples/pinocchio_demo/` (gitignored — regenerable). It builds a 6-tier
test suite and prints results to logcat:

```
[PinocchioDemo] PASS T1 smoke / addon load — pinocchio 4.0.0, nq=2 nv=2
[PinocchioDemo] PASS T2 FK + frame transform — 3/3 origins + basis @ q=(π/2,0) + ee.previousFrame=j2
[PinocchioDemo] PASS T3 frame Jacobian — J*dq matches FD (LWA <=1e-5) + LOCAL/WORLD shape+finite
[PinocchioDemo] PASS T4 IK (damped least squares) — iters=22 residual=0.0000008285 (< eps)
[PinocchioDemo] PASS T5 RNEA / CRBA / ABA identity — M·a+g identity + M symmetric + Coriolis + ABA round-trip
[PinocchioDemo] PASS T6 centroidal + joint limits — h_g(q,0)=0 + h_g(q,v) planar+finite, COM=…, clamp ok
[PinocchioDemo] SUMMARY: 6 / 6 PASS
```

Run on a connected Android device:

```bash
# After Stage 1 + Stage 2 above
make -C examples/pinocchio_demo build install run
```

`run` tails the filtered logcat. See `game/main.gd` for the full
assertion set — it's the most up-to-date worked example of every
binding method.

---

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `ClassDB.class_exists("PinocchioRuntime")` returns `false` on device | `libpinocchio_gd.so` not in the APK | `unzip -l build/foo.apk \| grep libpinocchio` — both `.so` must be under `lib/arm64-v8a/`. Re-stage via `make -C ../../xr build-pinocchio-gdext` + rebuild APK |
| `dlopen failed: cannot locate symbol …` at app start | `libpinocchio_default.so` missing | Same fix — gradle picks up the file at `android/build/libs/release/<abi>/` |
| `instantiate()` returns `null` | Wrapper loaded but `_bind_methods` didn't run | Check that `register_types.cpp::initialize()` registers your class at `MODULE_INITIALIZATION_LEVEL_SCENE` |
| C++ build fails with `extern template … does not refer to a function template` | Clang+NDK r27 disagrees with Pinocchio's explicit-instantiation declarations | `Makefile.pinocchio` patches them out; re-run `make -C xr build-pinocchio` so the patch is reapplied to a fresh install |
| C++ build fails with `'pinocchio/collision/…' file not found` | A header pulled in the collision shim | We only include `<pinocchio/spatial/inertia.hpp>` directly. If you add a new pinocchio include and hit this, you're transitively including `<pinocchio/multibody/fcl.hpp>` — switch to a narrower header |
| IK never converges | `target` orientation unreachable for this DOF (e.g. asking a 2-DOF planar arm to match a non-Z-axis rotation) | Restrict `target.basis` to what the model can produce, or accept higher residual |
| Crash in `pinocchio::Data` constructor on first call | Model mutated after `PinocchioData.initialize()` (sizes drift) | `PinocchioData` baked in `nq` / `nv` at init; create a new `PinocchioData` after any `add_*` call |

---

## 9. Extending — adding a new method

Suppose you want to expose `pinocchio::computeJointJacobian` (joint-frame
Jacobian, distinct from the frame Jacobian we already have):

1. Declare it on `PinocchioData` in `pinocchio_data.h`.
2. Implement it in `pinocchio_data.cpp` (read `q`, call the algorithm,
   convert to `PackedFloat64Array`). Use `ENSURE_READY(...)` and
   `size_ok(...)` for input validation; both are in the same TU.
3. Bind it in `_bind_methods()` with `ClassDB::bind_method(...)` and any
   `DEFVAL(...)`s for optional args.
4. Add a smoke + correctness test in
   `examples/pinocchio_demo/game/main.gd`.
5. `make -C xr build-pinocchio-gdext && make -C examples/pinocchio_demo ship`.

Common idioms:

| What | Helper |
|---|---|
| `Vector3 → Eigen::Vector3d` | `to_eigen(v)` |
| `Eigen::Vector3d → Vector3` | `to_godot(v)` |
| `Transform3D → pinocchio::SE3` | `to_pinocchio(xform)` |
| `pinocchio::SE3 → Transform3D` | `to_godot(se3)` |
| `PackedFloat64Array → Eigen::VectorXd` | `to_eigen(arr)` |
| `Eigen::VectorXd → PackedFloat64Array` | `to_godot(v)` |
| `Eigen::MatrixXd → row-major PackedFloat64Array` | `to_godot_rowmajor(M)` |

All in `xr/native/godot_pinocchio/src/eigen_godot.h`.

Pitfall: if you reach for `<pinocchio/algorithm/joint-configuration.hpp>`,
note that we deliberately don't include it — the `tangentMapProduct`
explicit-instantiation declarations don't compile under clang+NDK r27.
For 1-DoF scalar joints, `neutral()` is zero and `integrate(q, v)` is
`q + v`; reimplement inline rather than pulling that header in.

---

## 10. Roadmap

| Priority | Feature | Why |
|---|---|---|
| Done | Multi-task weighted QP solver (`PinocchioMultiTaskSolver`) | Dual-arm + elbow-hint + scalar yaw in one LDLT (issue 012) |
| Next | Free-floating root joint + proper `integrate` | Required for full humanoids / mobile bases |
| Next | LOCAL / WORLD Jacobian test coverage in the demo | Currently shape+finite only |
| Soon | `pinocchio::Jlog6` correction in IK | Better convergence near singularities |
| Soon | `computeJointJacobian` binding | Some control schemes prefer joint-frame J |
| Soon | Hierarchical QP priorities on `PinocchioMultiTaskSolver` | Safety constraints as hard rows instead of large weights |
| Later | Re-enable URDF parsing | Requires urdfdom on Android vcpkg |
| Later | Re-enable Coal/collision | Requires hpp-fcl on Android vcpkg |
| Later | CRBA-based mass matrix inverse cache | `aba()` already gives this; rarely worth re-caching |

When you ship a feature that doesn't fit the V1 surface, update both
this README and `xr/native/godot_pinocchio/src/pinocchio_data.h` so the API
stays self-describing.

---

## 11. License

The wrapper code (`xr/native/godot_pinocchio/src/*`) is under the operator
project's license. Pinocchio itself is BSD-2-Clause; Eigen is MPL-2.0;
Boost is BSL-1.0. The shipped `.so` bundles whatever the upstream
`DuinoDu/pinocchio-android` install + vcpkg cross-builds produce.

See:

- https://github.com/stack-of-tasks/pinocchio
- https://github.com/DuinoDu/pinocchio-android
