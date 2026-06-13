# retargeting — motion retargeting toolkit (C++)

A modular C++ toolkit for retargeting tracked human motion onto robot joint
configurations, built for VR teleoperation. It is structured in **two layers**
so that the teleoperation *use case* and the underlying *algorithm* evolve
independently, and so it can be driven from a Godot GDExtension that feeds the
headset's body/hand poses in each frame.

The first algorithm is a C++ port of **GMR** (General Motion Retargeting),
carried over from the validated standalone port. Its output is **byte-for-byte
identical** to that port on both kinematics backends, and therefore aligned with
the original Python (`mink` + MuJoCo) reference to ~1e-13.

## Two layers

```
                 SkeletonFrame  (VR body/hand poses, keyed by joint name)
                        │
   ┌────────────────────┴─ business layer (include/retargeting/retargeter.hpp)
   │   WholeBodyRetargeter │ UpperBodyRetargeter │ HandRetargeter
   │   - picks an algorithm by name + builds a ScenarioSpec
   │   - drives the per-frame protocol (begin → solve → end)
   │
   └────────────────────┬─ algorithm layer (include/retargeting/algorithm.hpp)
                        │   RetargetingAlgorithm  (interface)
                        │     └─ gmr::GmrAlgorithm  ──▶  gmr::GmrSolver
                        │   AlgorithmRegistry  (factory by name; "gmr", ...)
                        ▼
                 robot qpos  (MuJoCo convention)
```

### Business layer — `src/business/`, `include/retargeting/retargeter.hpp`
Distinguishes the three teleoperation scenarios. Each owns an algorithm and a
`ScenarioSpec` and exposes a single `step(SkeletonFrame) -> qpos`:

| Retargeter            | Scenario    | Specialization                                   |
|-----------------------|-------------|--------------------------------------------------|
| `WholeBodyRetargeter` | whole-body  | nothing locked; full robot is driven             |
| `UpperBodyRetargeter` | upper-body  | floating base + lower body held fixed (qpos lock)|
| `HandRetargeter`      | hand        | finger/hand pose → dexterous-hand joints         |

The scenario differences are expressed as **data** (`ScenarioSpec`), not as
algorithm subclasses, so any algorithm can serve any scenario.

### Algorithm layer — `src/algorithms/`, `include/retargeting/algorithm.hpp`
`RetargetingAlgorithm` is the extension point. Adding an algorithm is a new
folder under `src/algorithms/<name>/` implementing the interface, plus one line
in `src/algorithms/builtins.cpp` to register a factory. The business layer never
changes.

- `algorithms/gmr/` — GMR.
  - `gmr_solver.{hpp,cpp}` — the validated numerical core (QP-based differential
    IK; lie ops + box-QP solver in `src/core/`).
  - `gmr_algorithm.{hpp,cpp}` — adapts the solver to `RetargetingAlgorithm`.

### Shared kinematics core — `src/core/`
Carried over verbatim from the validated GMR port:
- `lie.{hpp,cpp}`, `box_qp.{hpp,cpp}` — SE3 lie ops + box-constrained QP.
- `kinematics_backend.hpp` — pluggable FK / Jacobian / integration interface.
- `pinocchio_backend.{hpp,cpp}` — **Pinocchio** backend (no MuJoCo runtime
  dependency; the VR/Android target).
- `mujoco_backend.{hpp,cpp}` — **MuJoCo** backend (desktop reference cross-check;
  optional via `-DRETARGETING_WITH_MUJOCO=OFF`).

## Test data — `data/`

The toolkit is self-contained: it ships the test data the demo needs.

```
data/
├── robot/unitree_g1/g1_mocap_29dof.xml      # target robot (MJCF)
├── ik_configs/quest3_upper_to_g1.json       # GMR mapping/config
└── reference/qpos_*_f200_fps30_h1.75.csv     # golden output (Pinocchio == Python ~1e-13)
```

Two MJCFs ship: the original `g1_mocap_29dof.xml` and a **meshless**
`g1_mocap_29dof_nomesh.xml` (mesh assets + geoms stripped). Retargeting only
needs the kinematic tree, so neither backend needs the 52MB STL meshes —
Pinocchio builds its model from the MJCF directly, and MuJoCo loads the meshless
MJCF. The reference CSV is the per-frame robot `qpos` and is the contract both
the desktop and on-device runs verify against (PASS tolerance 1e-6; actual
residual ~5e-14).

## Build & validate (desktop)

Requires Eigen3, nlohmann-json, Pinocchio, and (optionally, for the cross-check)
the MuJoCo dylib.

```bash
./build_desktop.sh 200 30 1.75
```

Builds `libretargeting.a` + `upper_body_demo`, runs the synthetic Quest3
upper-body source through `UpperBodyRetargeter`, and verifies against the
checked-in reference:

```
[run] backend=pinocchio ...
VERIFY: max abs diff vs reference = 0  -> PASS ✓
```

## Build & run on device (Android / NDK)

The Android target uses the **MuJoCo** backend. MuJoCo loads MJCF natively,
whereas the `pinocchio-android` build is core-only (no MJCF parser), so it
cannot construct the model on device. MuJoCo for Android is built by the
`mujoco-android` wrapper (see `make -C xr build-mujoco-android`). Eigen is
header-only (host), nlohmann-json is vendored under `third_party/` — so the
on-device build needs neither Pinocchio nor vcpkg.

```bash
export ANDROID_NDK=$ANDROID_NDK_HOME          # NDK r26+
make -C xr build-mujoco-android               # once: builds libmujoco.so for arm64-v8a
./build_android.sh                            # build + push + run + verify on device
# ./build_android.sh --no-run                 # build only
```

`build_android.sh` cross-compiles the demo (`-DRETARGETING_WITH_PINOCCHIO=OFF
-DRETARGETING_WITH_MUJOCO=ON`), stages `libmujoco.so` + `libc++_shared.so` +
`data/`, pushes to `/data/local/tmp/retargeting`, and runs with the meshless
MJCF. Verified on a physical arm64 device:

```
scenario=upper_body algorithm=gmr nq=36
VERIFY: max abs diff vs reference = 4.92661e-14  -> PASS ✓
```

i.e. the arm64 device reproduces the desktop/Python result to machine precision.

### Backends

| | Pinocchio | MuJoCo |
|---|---|---|
| Desktop | ✅ default (`find_package`, homebrew) | ✅ cross-check (GMR `.venv` wheel) |
| Android | ❌ core-only build lacks MJCF parser | ✅ `mujoco-android` (`libmujoco.so`) |

Toggle with `-DRETARGETING_WITH_PINOCCHIO=ON/OFF` and
`-DRETARGETING_WITH_MUJOCO=ON/OFF` (at least one required). The Android
`libmujoco.so` is produced by the **mujoco-android** wrapper
(<https://github.com/DuinoDu/mujoco-android>), synced into
`.deps/src/mujoco-android` by `make -C xr deps` and built by
`xr/makefiles/Makefile.mujoco-android` (`make -C xr build-mujoco-android`) —
mirroring exactly how `pinocchio-android` is integrated.

## Toward Godot / VR

The toolkit is intentionally free of any Godot dependency. The integration is a
thin GDExtension wrapper (separate `build.sh`, like the sibling `pinocchio`
module) that:
1. converts the headset's body/hand tracking into a `SkeletonFrame`,
2. holds a `*Retargeter` for the active scenario, and
3. calls `step()` per frame and pushes the resulting `qpos` to the robot / sim.

Because the algorithms register through `AlgorithmRegistry` and the business
layer is data-driven, the GDExtension chooses scenario + algorithm by string at
runtime. Note: when linking the static lib into a shared object, force the
algorithm TUs in (`-Wl,-force_load` / `--whole-archive`) or call
`retargeting::register_builtin_algorithms()` — the business-layer factories
already call it for you.

## Status

- whole-body / upper-body: working on GMR; upper-body validated against the
  Python reference via the GMR port.
- hand: wired through the same interface; needs a dexterous-hand MJCF +
  hand `ik_config` (and likely a hand-specific algorithm) to produce motion.
