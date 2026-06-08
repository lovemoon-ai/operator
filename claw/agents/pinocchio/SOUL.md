# SOUL — Pinocchio subsystem

You are feature owner of `pinocchio` GDExtension addon.
Read this end-to-end before changing code in `xr/native/pinocchio/`,
`xr/addons/pinocchio/`, or `xr/makefiles/Makefile.pinocchio`.
It costs ten minutes and saves days of wrong assumptions.

---

## 1. What this is

A Godot 4 GDExtension that wraps
[stack-of-tasks/pinocchio](https://github.com/stack-of-tasks/pinocchio)
(C++ rigid-body kinematics & dynamics) and exposes a curated subset
to GDScript on **Android arm64-v8a only**. Pinocchio itself is
cross-compiled via
[DuinoDu/pinocchio-android](https://github.com/DuinoDu/pinocchio-android),
which drives vcpkg to produce arm64-android builds of Eigen3 and
Boost.

The addon currently ships **four classes**:

| Class | Role | Headers |
|---|---|---|
| `PinocchioRuntime` | Version probe + smoke. First call in any scene that uses the addon. | `pinocchio_runtime.{h,cpp}` |
| `PinocchioModel` | Hand-built rigid-body tree (revolute / prismatic joints, frames, inertias, gravity, joint limits). No URDF parser — URDFDom is intentionally disabled (§5). | `pinocchio_model.{h,cpp}` |
| `PinocchioData` | Algorithms keyed off `(model, q[, v, a, τ])`: FK, frame Jacobian (LOCAL / WORLD / LOCAL_WORLD_ALIGNED), damped-least-squares IK, RNEA, generalized gravity, ABA, CRBA, centroidal momentum. | `pinocchio_data.{h,cpp}` |
| `PinocchioMultiTaskSolver` | Weighted-QP IK that drives multiple end-effectors (pose / position-only / orientation-only) plus scalar joint targets in **one LDLT factorization per inner iteration**, with posture + smoothness regularization. | `pinocchio_multitask_solver.{h,cpp}` |

All four inherit `RefCounted` — no manual `free()` required from
GDScript.

Total C++ surface area: **~1960 LoC** across 10 files (incl. the
shared `eigen_godot.h` conversion helpers).

---

## 2. Why it exists

The operator XR client needs on-device inverse kinematics for two
distinct paths:

1. **Robot teleop** — single-arm IK on a known target pose.
   `PinocchioData.solve_ik_dls(target, frame_id, q0, ...)` is the
   fit-for-purpose entry point: damped least-squares, one frame, one
   pose. Runs its own inner loop.
2. **Upper-body retargeting** — RFC-003. A human body-tracking source
   drives an H2 + Sharpa humanoid, which requires multi-task QP:
   two wrist poses + two elbow positions + waist yaw + posture +
   smoothness, all in **one solve**. Running tasks serially makes
   later tasks overwrite earlier ones' torso joints; needing all
   tasks active simultaneously is why `PinocchioMultiTaskSolver` exists.
   It assembles all tasks into a single weighted normal system and
   solves with Eigen LDLT per inner iteration.

> **Note**: the retargeter consumer (`xr/scripts/retargeting/`) is
> **not yet on `main`** as of this writing. It lives as untracked
> work-in-progress on branch `3776d7`. The addon itself is fully
> landed on `main` and ready for consumers.

---

## 3. Layout

```
xr/native/pinocchio/                   ← C++ source for the wrapper
├── CMakeLists.txt                     ← builds libpinocchio_gd.so
├── build.sh                           ← driver script; called by Makefile.addons
└── src/
    ├── register_types.cpp             ← GDExtension entry point + ClassDB registrations
    ├── pinocchio_runtime.{h,cpp}      ← PinocchioRuntime
    ├── pinocchio_model.{h,cpp}        ← PinocchioModel (manual tree builder)
    ├── pinocchio_data.{h,cpp}         ← PinocchioData (kinematics + dynamics)
    ├── pinocchio_multitask_solver.{h,cpp}  ← PinocchioMultiTaskSolver (multi-task QP IK)
    └── eigen_godot.h                  ← Vector3/Transform3D <-> Eigen + SE3 helpers

xr/addons/pinocchio/                   ← shipped to APK
├── pinocchio.gdextension              ← manifest. Registers .so for android.arm64
├── libpinocchio_gd.so                 ← thin wrapper, ~1.1 MB (gitignored, built artifact)
├── libpinocchio_default.so            ← upstream pinocchio core, ~6.1 MB (gitignored)
└── README.md                          ← end-user reference for the four classes

xr/makefiles/Makefile.pinocchio        ← Stage 1 build of upstream pinocchio + Eigen + Boost
xr/makefiles/Makefile.addons           ← Stage 2 target (build-pinocchio-gdext)

claw/issues/012-pinocchio-addon-multi-task-qp.md   ← PinocchioMultiTaskSolver spec
claw/rfcs/003-upper-body-human-to-humanoid-retargeting.md  ← retargeting motivation
```

Built `.so` artifacts duplicate to two locations: `addons/pinocchio/`
(for Godot's GDExtension loader) and `android/build/libs/<abi>/` (for
gradle's JNI packaging). The wrapper `build.sh` handles both copies
automatically.

---

## 4. Build pipeline

Two stages. **Stage 1 is slow on first run (~10–20 min)** because
vcpkg has to cross-compile Eigen3 and Boost for `arm64-android`.
Re-runs are sentinel-gated and take seconds.

### Stage 1 — `make -C xr build-pinocchio`

Produces:
```
$(OPERATOR_DEPS_CACHE_ROOT)/build/pinocchio-android/<abi>/src/build/android/<abi>/install/
├── include/pinocchio/...    ← headers Stage 2 consumes via find_package
├── lib/libpinocchio_default.so
└── lib/cmake/pinocchio/pinocchioConfig.cmake
```

This is the heavy lift. Driven by upstream scripts in
`pinocchio-android/scripts/{fetch-pinocchio,bootstrap-vcpkg-android,build-android}.sh`.

### Stage 2 — `make -C xr build-pinocchio-gdext`

Produces `libpinocchio_gd.so` (~1.1 MB) by compiling the C++ files in
`xr/native/pinocchio/src/` against the Stage 1 install + godot-cpp.
Installs to both `addons/pinocchio/` and `android/build/libs/<abi>/`.

**`build-pinocchio-gdext` is opt-in**: it's NOT in `build-quest` /
`build-pico` / `build-androidxr`. Any consumer that actually uses
the addon at runtime needs to either run the gdext make target
manually before APK build, or wire it into their project's Makefile.
See `examples/pinocchio_demo/Makefile` for the worked example.

### Required environment

```bash
ANDROID_NDK=$ANDROID_HOME/ndk/27.1.12297006     # r26+ tested
VCPKG_ROOT=$HOME/ws/vcpkg                       # needed for Stage 1 only
```

NDK r25b is too old (clang+Eigen breakage). r27 tested fine. The
wrapper compiles cleanly at clang-18 NDK r27.

### Sharing the cache across worktrees

`OPERATOR_DEPS_CACHE_ROOT` defaults to `<worktree>/.deps`. **Point
it at a shared location** to avoid rebuilding Stage 1 every time you
switch worktrees:

```bash
export OPERATOR_DEPS_CACHE_ROOT=~/.cache/operator/deps
```

This is the design intent — Makefile.pinocchio's header explicitly
documents the pattern. Concretely useful when you have many parallel
branches checked out under `.conductor/worktrees/`.

---

## 5. Kinematics & dynamics primitives (`PinocchioRuntime` / `Model` / `Data`)

See `xr/addons/pinocchio/README.md` §5 for the full GDScript-facing
reference. The high-level contract:

- `PinocchioModel` is a tree builder. After `PinocchioData.initialize(model)`
  the model is **immutable** — adding joints/frames invalidates the
  Data's pre-allocated nq/nv buffers and crashes. Create a fresh
  `PinocchioData` if you need to mutate the model.
- `PinocchioData` algorithms always re-run FK under the hood, so a
  call to `compute_frame_jacobian(q, ...)` also primes the internal
  frame placements for a subsequent `get_frame_transform()`.
- Joint position vector `q` is double-precision (`PackedFloat64Array`).
  Godot's `Vector3` is float32 in stock builds, which is why centroidal
  momentum returns both `_raw` (PackedFloat64Array) and Vector3
  flavors — float32 truncates angular momentum below ~1.2e-7 to bit-
  exact zero, breaking identity checks.

### Intentionally unimplemented features

| Feature | Off | Reason |
|---|---|---|
| URDF / SDF parsing | `PINOCCHIO_WITH_URDFDOM=0` | urdfdom not in vcpkg for arm64-android. Workaround: hand-build models or generate from your own format. |
| Collision queries (Coal/HPP-FCL) | `PINOCCHIO_WITH_HPP_FCL=0` | hpp-fcl not in vcpkg for arm64-android. |
| Python bindings | n/a | XR client is C++/GDScript. |
| CasADi / autodiff / codegen | n/a | Off-target. |
| OpenMP | n/a | Android NDK toolchain doesn't bundle libomp out of the box; pinocchio algorithms run single-threaded. |
| Free-floating (6-DoF root) joints | binding layer | Only 1-DoF scalar joints (revolute, prismatic) are exposed. `nq == nv` always. Adding a free-floating root means swapping the IK retract from `q += dq` to `pinocchio::integrate(...)` against a real Lie-group retraction. |
| `<pinocchio/algorithm/joint-configuration.hpp>` | clang+NDK r27 disagrees with the `tangentMapProduct` explicit-instantiation declarations | Reimplement `neutral()` / `integrate()` inline for scalar joints. |

These constraints are load-bearing for the build to compile. Don't
flip them without taking the whole toolchain story along.

---

## 6. Multi-task QP IK (`PinocchioMultiTaskSolver`)

Spec: `claw/issues/012-pinocchio-addon-multi-task-qp.md`.

### Math

Per inner iteration:

```
A = (λ² + w_post² + w_smooth²) · I
b = 0

for each active task:
    err = error_function(task, q, target)            # 1, 3, or 6 rows
    Jrows = relevant_rows(compute_frame_jacobian(...))
    A += w² · Jrowsᵀ · Jrows
    b += w² · Jrowsᵀ · err

b += w_post²    · (q_home - q)
b += w_smooth² · dq_prev

dq = LDLT(A).solve(b)
q = clamp(q + step·dq,  q_lower, q_upper)
```

LDLT is the right factorization: A is symmetric positive-definite by
construction (sum of `JᵀJ` blocks plus `diag_reg·I` with `diag_reg > 0`).
Eigen's `LDLT` is in-place, O(n³/3), stable.

### API contract (the important bits)

```gdscript
solver.initialize(model, config_dict)               # one-time
solver.add_pose_task("left_wrist", frame_id)        # one-time per task
solver.set_posture(q_home)                          # one-time

var sol = solver.solve(q0, targets_dict, dq_prev)   # per frame
```

- `solve()` is **pure** — no internal `q` / `dq_prev` state. Warm-start
  is the caller's responsibility (thread the previous `sol["q"]` back
  in as the next `q0`).
- A task whose key is **absent from the targets dict** contributes
  zero rows that frame — degrades gracefully when a body-tracking
  source drops a joint.
- A task whose **weight is 0** behaves identically — skipped that
  frame, useful for quality-scaled weights without restructuring the
  dict.
- Free-floating roots rejected at `initialize()` (same `nq == nv`
  limit as the rest of the addon — see §5).
- Orientation targets are re-orthogonalised with `HouseholderQR` on
  entry. Defends against accumulated Godot `Basis` drift; cheap (3×3).

### Performance baseline

Verified on Quest 3 (Adreno 740, OpenXR Vulkan, single-threaded):

| Model | Tasks | Iters to converge | µs/solve |
|---|---|---|---|
| 2-DOF planar arm | 1 pose (pos only) | 16 | **370 µs** |

The Issue's stretch target for the H2 19-DoF + 4-task L6 benchmark is
`< 2000 µs / solve`. The 2-DOF run gives roughly 10× headroom against
the worst-case (more tasks = more `JᵀJ` accumulation, more iters
typically needed; LDLT cost scales O(nv³) ≈ 6800 vs 8 here so it's
the wall when nv climbs).

---

## 7. How to develop

### Round-trip after a C++ change

```bash
# 1. Rebuild the wrapper (Stage 2 only; Stage 1 doesn't change)
make -C xr build-pinocchio-gdext

# 2. Rebuild + install APK (assumes a consumer scene exists)
make -C xr build-install-quest      # or build-install-pico

# 3. Launch + capture filtered logcat
make -C xr ship-quest               # or ship-pico
```

`ship-quest` chains `build-install-quest` + `ship-fast`. `ship-fast`
force-stops, clears logcat, launches the app, tails logs filtered by
`godot|Operator|RobotView|TcpHandler|KotlinVideo|AhbVideo|OpenXR`.
GDScript `print()` lands in the `godot` tag so addon test output is
captured; C++ warnings from the addon land in `W/PinocchioGD` tag
(must add that to the grep filter when chasing C++-side bugs).

### Round-trip after a GDScript-only change

Skip Stage 2 — only re-export the APK:

```bash
make -C xr build-install-quest
```

The `.so`s on disk are already current; Godot's exporter just
re-bundles the changed scripts.

### Editor work on desktop

```bash
make -C xr godot      # opens the project in the Godot editor
```

But **the addon classes are NOT registered on desktop** — only
arm64-android. ClassDB calls like `ClassDB.class_exists("PinocchioModel")`
return false in the editor. The CMakeLists has `if(NOT ANDROID) message(FATAL_ERROR)`
exactly to enforce this. So Godot-side scenes that touch Pinocchio
must guard their `_ready()` with a feature check or only run on
Android. Same constraint as ahb_decoder / pico_openxr.

---

## 8. On-device testing pattern

There is no permanent on-device smoke test for `PinocchioMultiTaskSolver`
in this branch. `PinocchioRuntime` / `Model` / `Data` have one in
`examples/pinocchio_demo/` (gitignored, regenerable — see
`xr/addons/pinocchio/README.md §7`); the multi-task solver was
verified during landing via a temporary scene that was deleted
post-merge.

**The pattern when you need to verify the addon on device** (e.g. after
bumping pinocchio, NDK, or godot-cpp):

1. Write a minimal scene + script that auto-runs in `_ready()`:
   ```gdscript
   extends Node
   func _ready() -> void:
       if not ClassDB.class_exists("PinocchioMultiTaskSolver"):
           push_error("addon not loaded — check libpinocchio_gd.so in APK")
           return
       # ... build tiny model, exercise the API, assert with print() ...
   ```
2. Flip `run/main_scene` in `xr/project.godot` to point at it.
3. `make -C xr build-install-quest`
4. `adb logcat -c && adb shell am start -n com.lovemoon.operator/com.godot.game.GodotApp && sleep 6 && adb logcat -d | grep -E "godot|PinocchioGD"`
5. Read PASS/FAIL output, fix, repeat. Restore `main_scene` when done.

The Issue 012 verification followed this pattern and exercised 7
layers: class registration → instantiate → model build → initialize →
task registration (incl. duplicate-key + out-of-range rejection) → IK
convergence → weight=0 skip semantics → bad q0 size handling. All
PASS on Quest 3.

If the multi-task solver grows enough downstream consumers that an
on-device regression suite makes sense, the right home is
`examples/pinocchio_multitask_demo/` (gitignored, regenerable),
matching the existing `pinocchio_demo/` pattern.

---

## 9. Conventions & gotchas

### Type marshalling

All conversions live in `eigen_godot.h`:

| What | Helper |
|---|---|
| `Vector3 → Eigen::Vector3d` | `to_eigen(v)` |
| `Eigen::Vector3d → Vector3` | `to_godot(v)` |
| `Transform3D → pinocchio::SE3` | `to_pinocchio(xform)` |
| `pinocchio::SE3 → Transform3D` | `to_godot(se3)` |
| `PackedFloat64Array ↔ Eigen::VectorXd` | `to_eigen(arr)` / `to_godot(v)` |
| `Eigen::MatrixXd → row-major PackedFloat64Array` | `to_godot_rowmajor(M)` |

**Don't roll your own** — Godot's `Basis` is row-major (`basis[i][j] = R(i,j)`)
but its `Basis(x_axis, y_axis, z_axis)` constructor takes columns,
which has bitten everyone who reached for it. The helpers wrap the
ambiguity once and forever.

### Logcat tag

C++ side uses `__android_log_print(ANDROID_LOG_WARN, "PinocchioGD", ...)`
via the `LOGW` macro defined per-TU. The tag is **`PinocchioGD`**, not
`PinocchioModel` or any per-class variant — keeping a single tag means
`adb logcat -s PinocchioGD:W` shows everything from the addon's C++ in
one stream.

### Friend access to `PinocchioModel::native_model()`

`PinocchioModel` keeps its `pinocchio::Model` private and grants
friend access to `PinocchioData` and `PinocchioMultiTaskSolver`.
Adding any new class that needs to call algorithms against the raw
model means adding a `friend class …` line in `pinocchio_model.h`.
This is deliberate — preventing public access stops consumers from
mutating the model after a Data/Solver has bound to it (which would
corrupt the Data's pre-allocated buffers).

### The `joint-configuration.hpp` ban

```cpp
// xr/native/pinocchio/src/pinocchio_data.cpp
// joint-configuration.hpp is intentionally NOT included — see the matching
// note in pinocchio_model.cpp. For 1-DOF scalar joints, integrate(q, v) is
// just element-wise q + v.
```

Clang+NDK r27 chokes on the `tangentMapProduct` explicit-instantiation
declarations in that header. If you reach for `pinocchio::integrate`
or `pinocchio::neutral` (for free-floating support), you'll hit this.
The fix is non-trivial: patch upstream or migrate the build to a
newer Pinocchio that drops those declarations.

### gdextension manifest quirks

`pinocchio.gdextension` declares the .so for `android.arm64`, NOT
`android.arm64-v8a` — the latter silently no-matches and the .so
never lands in the APK. Same for the `[dependencies]` block:
`{ "res://..." : "" }` works, bare `"res://..."` triggers an empty
"configuration errors:" with no message. Both quirks are documented
inline in the manifest.

---

## 10. Open work / known limitations

| Item | Why it's not done | Where it belongs |
|---|---|---|
| `PinocchioJlog6` correction in `solve_ik_dls` | Better convergence near singularities | `pinocchio_data.cpp` |
| `computeJointJacobian` binding | Some control schemes prefer joint-frame J | `pinocchio_data.{h,cpp}` |
| Free-floating root + proper `integrate` | Required for full humanoids / mobile bases | Cross-cutting: `PinocchioModel` + `PinocchioData` + `PinocchioMultiTaskSolver` retract |
| Hierarchical QP priorities on `PinocchioMultiTaskSolver` | Safety constraints as hard rows, not large weights | `pinocchio_multitask_solver.cpp` (add `priority` arg to `add_*_task`) |
| Self-collision constraints | Coal/FCL turned off upstream | Requires `PINOCCHIO_WITH_HPP_FCL=1` + hpp-fcl in vcpkg |
| URDF parsing | URDFDom not in vcpkg | Requires urdfdom in vcpkg for arm64-android |
| H2 retargeter refactor to use `PinocchioMultiTaskSolver` | Owned by retargeting subsystem, not addon | `xr/scripts/retargeting/h2_pinocchio_retargeter.gd` (currently on branch 3776d7, not yet on main) |
| L8/L9 retargeter smoke tests | Same — retargeter-side work | `xr/scripts/retargeting/tests/pinocchio_smoke_test.gd` |

The last two are explicit non-goals of Issue 012's addon scope —
they're tracked in the issue's §"Acceptance criteria" #3, #4, #5 but
are consumer-side work.

---

## 11. References

| Source | Relevance |
|---|---|
| `xr/addons/pinocchio/README.md` | End-user API reference. Read after this doc. |
| `claw/issues/012-pinocchio-addon-multi-task-qp.md` | `PinocchioMultiTaskSolver` spec — every API decision is justified here. |
| `claw/rfcs/003-upper-body-human-to-humanoid-retargeting.md` | Why the multi-task solver exists. §"Retargeting Formulation" and §"Objective". |
| `xr/native/pinocchio/src/pinocchio_data.h` | Kinematics + dynamics algorithm surface declarations + contract notes. |
| `xr/native/pinocchio/src/pinocchio_multitask_solver.h` | Multi-task solver declarations. |
| `xr/native/pinocchio/src/eigen_godot.h` | All type marshalling helpers. |
| `xr/makefiles/Makefile.pinocchio` | Stage 1 build wiring. Header comment is a small RFC unto itself. |
| `xr/native/pinocchio/build.sh` | Stage 2 build driver. Has the CMake invocation + cache-sharing logic. |
| Pinocchio docs: <https://stack-of-tasks.github.io/pinocchio/master/> | Upstream API reference. We're on tagged release 4.0.0. |
| pinocchio-android: <https://github.com/DuinoDu/pinocchio-android> | Android cross-build of upstream pinocchio. Pinned by `scripts/sync_deps.sh`. |
| Eigen LDLT: <https://eigen.tuxfamily.org/dox/group__LDLT.html> | Multi-task solver inner-loop factorization reference. |

---

## 12. Cheat sheet

```bash
# First-time build (slow Stage 1)
export ANDROID_NDK=$HOME/Library/Android/sdk/ndk/27.1.12297006
export VCPKG_ROOT=$HOME/ws/vcpkg
make -C xr deps                              # sync godot-cpp + pinocchio-android
make -C xr build-pinocchio                   # Stage 1 — slow first run
make -C xr build-pinocchio-gdext             # Stage 2 — seconds

# Subsequent edits (C++)
make -C xr build-pinocchio-gdext

# Ship to Quest 3
make -C xr ship-quest                        # build + install + tail logcat

# Ship to Pico
make -C xr ship-pico

# Filter device logs
adb logcat -d | grep -E "godot|PinocchioGD"

# Editor on desktop (addon won't load there — expected)
make -C xr godot

# Reuse Stage 1 across worktrees
export OPERATOR_DEPS_CACHE_ROOT=~/.cache/operator/deps
```

When in doubt: addon classes registering as `false` from `ClassDB.class_exists`
on device means the `.so` isn't in the APK. Check
`unzip -l build/quest/Operator.apk | grep libpinocchio` — both
`libpinocchio_gd.so` and `libpinocchio_default.so` must be under
`lib/arm64-v8a/`. README §8 has the full troubleshooting table.
