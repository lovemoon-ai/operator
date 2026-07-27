# SOP: How To Make A New Robot

This SOP explains how to add a new robot body model to Operator and make it
usable by the XR Godot client and the MuJoCo-facing asset pipeline.

The short version: add a pinned generator under `scripts/make-robot/`, keep
third-party source in `$OPERATOR_DEPS_CACHE_ROOT/src`, generate self-contained
URDF meshes under `xr/assets/robots/<robot>/`, generate a Godot-only GLB
overlay, generate a loadable MuJoCo XML, then verify every path and exported
asset.

## Scope

There are two different levels of "robot simulation" in this repo:

1. Robot body assets for XR and smoke loading.

   This is what `scripts/make-robot/` produces today:

   - a URDF with local mesh references;
   - a static GLB visual overlay for Godot;
   - a MuJoCo XML proxy with matching body/joint names;
   - copied or converted mesh files under `xr/assets/robots/<robot>/`.

   The generated MuJoCo XML is intended to be loadable and name-compatible. It
   is not a high-fidelity dynamics model unless you replace the proxy geoms,
   inertials, actuator gains, contacts, sensors, and constraints with
   robot-specific values.

2. A controllable teleop simulator.

   This requires robot-side work in `robot/`, usually a driver, descriptor, and
   config. The existing SO-101 simulator is the pattern. Do not assume a new
   URDF/XML asset is enough for end-to-end teleop control.

## Current File Map

Robot asset generation:

- `scripts/make-robot/README.md` - generated robot asset inventory.
- `scripts/make-robot/make_<robot>.sh` - one shell entry point per robot.
- `scripts/make-robot/urdf_to_godot_assets.py` - shared URDF parser, mesh
  localizer, Godot GLB exporter, and MuJoCo proxy writer.

Generated XR assets:

- `xr/assets/robots/<robot>/<robot>.urdf` - self-contained URDF metadata.
- `xr/assets/robots/<robot>/<robot>.glb` - Godot-only static visual overlay.
- `xr/assets/robots/<robot>/meshes/` - local URDF meshes.
- `xr/assets/robots/<robot>/meshes/.source` - upstream URL, commit, and path.
- `xr/assets/mujoco/<robot>.xml` - MuJoCo-loadable proxy XML.

Packaging:

- `xr/export_presets.cfg` - Android export include filters. New robot asset
  layouts must be included here or the APK will miss meshes at runtime.

Optional XR integration:

- `xr/scripts/robot_constraint/robot/` - robot-specific XR visual/constraint
  overlays. Only add code here if the app needs a named robot overlay, body
  mapping, or UI selection.

Controllable simulator integration:

- `robot/configs/*.yaml` - adapter runtime config.
- `robot/configs/*descriptor*.yaml` - controls, joints, and feeds advertised to
  XR.
- `robot/crates/robot-adapter/src/control/drivers/` - concrete control driver.
- `robot/crates/robot-adapter/src/devices/mod.rs` - `device_type` dispatch.
- `robot/crates/robot-adapter/src/config.rs` - config schema and defaults.

## Naming And Layout

Use stable names that separate human-readable folders from code identifiers.

- Folder slug: `xr/assets/robots/<robot-slug>/`, for example
  `dexmate-vega-u`.
- Robot name: snake case for generated files and XML model names, for example
  `dexmate_vega_u`.
- Shell script: `scripts/make-robot/make_<robot_name>.sh`.
- Output files:

  ```text
  xr/assets/robots/<robot-slug>/<robot_name>.urdf
  xr/assets/robots/<robot-slug>/<robot_name>.glb
  xr/assets/robots/<robot-slug>/meshes/
  xr/assets/mujoco/<robot_name>.xml
  ```

Do not put third-party source checkouts in this repo. Put them under:

```bash
OPERATOR_DEPS_CACHE_ROOT="${OPERATOR_DEPS_CACHE_ROOT:-$HOME/.cache/operator/deps}"
DEPS_SRC_DIR="${DEPS_SRC_DIR:-$OPERATOR_DEPS_CACHE_ROOT/src}"
```

## Source Selection

Before writing code, identify the upstream robot model and pin it:

1. Prefer an official vendor repository over mirrors.
2. Record the exact commit SHA in the script.
3. Use sparse checkout when the source repo is large.
4. Save the upstream URL, commit, and source path to `meshes/.source`.
5. Check the source license before generating and committing derived assets.

Examples in this repo:

- Unitree H2 Plus source is `unitreerobotics/unitree_ros`, pinned in
  `make_unitree_h2_sharpa.sh`.
- Dexmate Vega U source is `dexmate-ai/dexmate-urdf`, pinned in
  `make_dexmate_vega_u.sh`.

## Required Generator Behavior

Each `make_<robot>.sh` should do the following:

1. Resolve repo paths and cache paths.

   ```bash
   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
   OPERATOR_DEPS_CACHE_ROOT="${OPERATOR_DEPS_CACHE_ROOT:-$HOME/.cache/operator/deps}"
   DEPS_SRC_DIR="${DEPS_SRC_DIR:-$OPERATOR_DEPS_CACHE_ROOT/src}"
   DEPS_BUILD_DIR="${DEPS_BUILD_DIR:-$OPERATOR_DEPS_CACHE_ROOT/build}"
   ```

2. Clone or sync the upstream source into `$DEPS_SRC_DIR`.

   Refuse to overwrite tracked local changes in dependency checkouts. Ignoring
   untracked files is usually acceptable because macOS can create `.DS_Store`
   files in global cache folders.

3. Create or reuse the shared Python venv.

   Mesh conversion needs `trimesh`; DAE loading needs `pycollada`; numpy is
   used by the transform code. Even `--skip-glb` may still need `trimesh`
   because URDF mesh normalization can convert `.glb` or `.obj` to `.stl`.

4. Call `urdf_to_godot_assets.py`.

   Required arguments:

   ```bash
   "$PY" "$SCRIPT_DIR/urdf_to_godot_assets.py" \
     --source-dir "$SOURCE_DIR" \
     --source-urdf "$SOURCE_URDF" \
     --robot-name "$ROBOT_NAME" \
     --urdf-out "$URDF_OUT" \
     --mjcf-out "$MJCF_OUT" \
     --glb-out "$GLB_OUT" \
     --mesh-copy-root "$MESH_OUT_DIR" \
     --mesh-reference-prefix "meshes" \
     --mesh-source-label "<source-label>"
   ```

   `--source-urdf` can be omitted only when the upstream file is exactly
   `H2_Plus.urdf`; explicit is clearer for new robots.

5. Clean generated mesh directories before writing new output.

   This prevents stale `.glb`, `.obj`, or old folder layouts from remaining
   after a generator behavior change.

6. Support these flags:

   - `--no-sync` for local reruns against the cached upstream checkout.
   - `--skip-glb` for fast URDF/XML/mesh regeneration. Do not skip Python mesh
     dependencies if the URDF path still needs conversion.

## URDF Mesh Rules

The main URDF must be viewer-friendly and self-contained:

- Visual mesh references in URDF must be `.stl` or `.dae`.
- Collision mesh references should also be `.stl` or `.dae`.
- `.glb` is only for the generated Godot overlay file.
- `.obj` and `.glb` source meshes must be converted to `.stl` before being
  referenced by URDF.
- All URDF mesh paths must be relative to the generated URDF directory.
- Every generated URDF mesh reference must resolve on disk.

Why this matters:

- Some web URDF viewers only support STL/DAE and will silently show an empty
  robot if URDF visual meshes point at GLB or OBJ.
- Godot can use a single GLB overlay more reliably than many loose URDF visual
  mesh files.
- Android export filters need predictable relative asset paths.

For a generated URDF at:

```text
xr/assets/robots/dexmate-vega-u/dexmate_vega_u.urdf
```

mesh references should look like:

```xml
<mesh filename="meshes/vega_1u/meshes/visual/base_link.stl" />
```

not:

```xml
<mesh filename="../../hands/f5d6_hand/meshes/visual/base_link.glb" />
```

## Handling Upstream Paths

Upstream URDFs often contain awkward paths:

- `package://...`
- `../other_robot/meshes/...`
- `../../hands/...`
- direct `meshes/...`

The generator must rewrite those into local, self-contained paths. Use
`--mesh-source-label` to avoid collisions when a source URDF references both
local meshes and sibling package meshes.

Example:

```text
source: ../vega_1/meshes/visual/head_l1.glb
output: meshes/vega_1/meshes/visual/head_l1.stl
```

For robots that reference sibling packages, sparse checkout must include every
referenced mesh folder, not only the folder containing the selected URDF.

## Godot GLB Overlay

The generated GLB is a static rest-pose visual overlay for Godot. It is built
from URDF visual elements and converted into Godot coordinates.

Keep these constraints in mind:

- GLB is not the source of truth for kinematics. The URDF joint tree is.
- GLB should include named link nodes where possible for debugging.
- Broken source DAE files can have incorrect scale or bounds. The H2 pipeline
  had a DAE whose bounds were far too large, so the GLB exporter falls back to
  a same-name STL when it detects huge DAE extents.
- If the GLB loads but appears rotated or offset, inspect URDF `origin` values
  and the URDF-to-Godot axis conversion before changing asset scale manually.

## MuJoCo XML

The generated MuJoCo XML is a proxy model:

- body and joint names are preserved from URDF;
- non-fixed joints get simple position actuators;
- proxy geoms are simple boxes or spheres based on link names;
- a free joint is added to each root body.

Use this for load checks, UI plumbing, and name compatibility. For real
dynamics, write or import a robot-specific MJCF and verify:

- inertial values;
- collision meshes or primitive geoms;
- actuator types, gains, limits, gear ratios, and damping;
- contact settings;
- sensors;
- keyframes and default poses.

If the robot should be driven through `robot-adapter`, add a proper driver and
descriptor rather than relying on the generated proxy XML.

## Android Export

Generated robot assets must be included in every relevant Android preset.

Check `xr/export_presets.cfg` for include filters covering:

- `assets/mujoco/*.xml`;
- `assets/robots/*/*.glb`;
- `assets/robots/*/*.urdf`;
- nested `assets/robots/*/meshes/...` files.

Missing export filters are easy to miss locally because files exist on disk,
but the headset APK will not contain them.

## Optional XR Runtime Work

Only add XR code when the app needs to select or display the robot at runtime.

Possible files:

- `xr/scripts/robot_constraint/robot/<robot>_overlay.gd`
- `xr/scripts/robot_constraint/README.md`
- feature manifests under `xr/tests/manifests/features/`

Keep robot-specific names isolated to robot-specific modules. Do not spread
one robot's link naming across generic body tracking or platform code.

## Optional Robot Adapter Work

If the new robot needs teleop control, add a robot-side implementation.

Minimum surfaces to evaluate:

- `robot/configs/<robot>.yaml`
- `robot/configs/<robot>_descriptor.yaml`
- `robot/crates/robot-adapter/src/control/drivers/<robot>.rs`
- `robot/crates/robot-adapter/src/control/drivers/mod.rs`
- `robot/crates/robot-adapter/src/devices/mod.rs`
- `robot/crates/robot-adapter/src/config.rs`
- e2e or driver tests under `robot/crates/*/tests/`

The descriptor must match the controls and joints the XR app will send. Do not
publish a joint name in the descriptor unless the driver can apply it safely.

## Validation Checklist

Run syntax checks first:

```bash
bash -n scripts/make-robot/make_<robot>.sh
python3 -m py_compile scripts/make-robot/urdf_to_godot_assets.py
```

Run a fast generation pass:

```bash
bash scripts/make-robot/make_<robot>.sh --no-sync --skip-glb
```

Run a full generation pass at least once after adding the robot:

```bash
bash scripts/make-robot/make_<robot>.sh
```

Verify the generated URDF:

```bash
python3 - <<'PY'
from pathlib import Path
import xml.etree.ElementTree as ET

urdf = Path("xr/assets/robots/<robot-slug>/<robot_name>.urdf")
root = ET.parse(urdf).getroot()
missing = []
visual_exts = {}
all_exts = {}

for visual in root.findall(".//visual"):
    mesh = visual.find("geometry/mesh")
    if mesh is None:
        continue
    filename = mesh.get("filename") or ""
    suffix = Path(filename).suffix.lower()
    visual_exts[suffix] = visual_exts.get(suffix, 0) + 1

for mesh in root.findall(".//mesh"):
    filename = mesh.get("filename") or ""
    suffix = Path(filename).suffix.lower()
    all_exts[suffix] = all_exts.get(suffix, 0) + 1
    if filename and not (urdf.parent / filename).exists():
        missing.append(filename)

print("robot", root.get("name"))
print("visual_exts", visual_exts)
print("all_exts", all_exts)
print("missing", len(missing))
if missing:
    print("\n".join(missing[:20]))
    raise SystemExit(1)
if not set(visual_exts).issubset({".stl", ".dae"}):
    raise SystemExit("URDF visual meshes must be STL/DAE")
PY
```

Verify XML and GLB loadability:

```bash
python3 - <<'PY'
from pathlib import Path
import xml.etree.ElementTree as ET

for path in [
    "xr/assets/robots/<robot-slug>/<robot_name>.urdf",
    "xr/assets/mujoco/<robot_name>.xml",
]:
    root = ET.parse(path).getroot()
    print(path, root.tag, root.get("name") or root.get("model"))

with open("xr/assets/robots/<robot-slug>/<robot_name>.glb", "rb") as f:
    print("glb magic", f.read(4).decode("ascii"))
PY
```

If the shared venv exists, check the GLB scene:

```bash
$OPERATOR_DEPS_CACHE_ROOT/build/make-robot-venv/bin/python - <<'PY'
import trimesh
scene = trimesh.load(
    "xr/assets/robots/<robot-slug>/<robot_name>.glb",
    force="scene",
    process=False,
)
print("geometry", len(scene.geometry), "nodes", len(scene.graph.nodes_geometry))
if not scene.geometry:
    raise SystemExit(1)
PY
```

Run repo static checks:

```bash
python3 cicd/validate_xr_features.py
python3 cicd/validate_xr_test_manifests.py
```

Run MuJoCo static packaging check only when the expected APK exists:

```bash
bash cicd/03_godot_mujoco_static.sh
```

This script currently expects a built Quest APK. If it reports `missing APK`,
build the APK first or record that the check was blocked by missing build
output.

Run device tests only on real devices:

```bash
bash cicd/03_godot_mujoco_device.sh
```

Do not run the XR project in desktop headless mode. `godot --headless` is for
export only in this repo.

## Common Pitfalls

- URDF points at `.glb` or `.obj`.

  Many URDF viewers and importers do not support these formats. Convert them
  to `.stl` for URDF. Keep `.glb` only as the separate Godot overlay.

- Meshes exist in the cache but not beside the generated URDF.

  The generated URDF must be self-contained under `xr/assets/robots/<robot>/`.
  Do not leave URDF paths pointing into `$OPERATOR_DEPS_CACHE_ROOT`.

- Upstream URDF uses `../` paths into sibling packages.

  Include those packages in sparse checkout and rewrite the output paths into
  local `meshes/...` paths. Otherwise the generator may pass for the root
  robot folder but miss hands, grippers, or shared arm meshes.

- Stale generated files stay in `meshes/`.

  Clean generated mesh directories before rerun. Otherwise old `.glb`, `.obj`,
  or old path layouts can remain after the script changes.

- `--skip-glb` still needs mesh dependencies.

  If source URDF meshes are GLB/OBJ, converting the URDF mesh set to STL still
  needs `trimesh`, even when not rebuilding the Godot GLB.

- DAE files can be malformed or scaled incorrectly.

  Validate GLB bounds with `trimesh`. If a DAE has absurd extents, prefer a
  same-name STL fallback for the Godot overlay.

- Export filters omit nested mesh folders.

  Android builds may work on disk but fail on headset because files were not
  packaged into the APK. Update every relevant `include_filter`.

- Generated MuJoCo XML is treated as production dynamics.

  The proxy XML is loadable and name-compatible, not a physics-accurate robot.
  Add a real MJCF and driver for control work.

- The dependency checkout is dirty.

  Refuse tracked local changes in `$OPERATOR_DEPS_CACHE_ROOT/src/<repo>`.
  Untracked cache noise is usually not a reason to fail unless it blocks git
  checkout.

- Robot-specific code leaks into generic XR modules.

  Put robot-specific overlays or link mappings under robot-specific files.
  Keep generic platform, body tracking, and UI code capability-driven.

## Definition Of Done

A new robot asset is ready when:

- source repo URL, commit, and source path are pinned in the generator;
- third-party source is under `$OPERATOR_DEPS_CACHE_ROOT/src`;
- generated URDF has only STL/DAE visual mesh references;
- every URDF mesh reference resolves under `xr/assets/robots/<robot>/`;
- generated GLB loads and is reserved for Godot use;
- generated MuJoCo XML parses;
- Android export filters include the asset layout;
- static checks pass or any blocked check is explained with the missing
  prerequisite;
- docs list the source model and generated outputs.
