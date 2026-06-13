# godot_retargeting

Godot GDExtension bridge for the retargeting toolkit (`xr/native/retargeting`).
It exposes one class, **`GMRRetargeter`**, so a Godot XR scene can map the
headset's tracked body/hand poses onto a robot configuration each frame.

Android-only (the standalone XR target), mirroring `godot_mujoco` /
`pinocchio`. The kinematics backend is **MuJoCo** (from `mujoco-android`), which
loads MJCF natively; the Android Pinocchio build is core-only without the MJCF
parser, so it is not used here.

## Build

```bash
export ANDROID_NDK=$ANDROID_NDK_HOME
make -C xr build-mujoco-android        # once: libmujoco.so for arm64-v8a
make -C xr deps                        # syncs godot-cpp + the addon symlink
./build.sh                             # -> libgodot_retargeting.so (+ libmujoco.so)
```

Installs `libgodot_retargeting.so` + `libmujoco.so` into
`xr/addons/godot_retargeting/bin/` (loaded via the `.gdextension`) and
`xr/android/build/libs/arm64-v8a/` (packaged into the APK).

## GDScript API — `GMRRetargeter`

| Method | Description |
|---|---|
| `configure(scenario, robot_xml, ik_config, human_height=1.75, locked_qpos_prefix=0) -> bool` | Bind a robot + mapping. `scenario`: `"whole_body"` / `"upper_body"` / `"hand"`. |
| `set_pose(name, xform: Transform3D)` | Accumulate one source joint pose for the next `step()`. |
| `set_pose_pq(name, pos: Vector3, quat: Quaternion)` | Same, from position + quaternion. |
| `clear_frame()` | Drop the accumulated frame. |
| `step() -> PackedFloat64Array` | Retarget the accumulated frame → robot `qpos`. |
| `step_frame(frame: Dictionary) -> PackedFloat64Array` | Retarget `{name: Transform3D}` in one call. |
| `get_nq() -> int`, `get_scenario() -> String`, `is_configured() -> bool`, `get_last_error() -> String` | Introspection. |

### Example

```gdscript
extends Node3D

var rt := GMRRetargeter.new()

func _ready() -> void:
    # res:// is inside the APK and is not a real path; extract the model + config
    # to user:// (a real filesystem path on Android) and pass those.
    var robot := _extract("res://data/robot/unitree_g1/g1_mocap_29dof_nomesh.xml")
    var ikcfg := _extract("res://data/ik_configs/quest3_upper_to_g1.json")
    # upper-body G1: lock the floating base + 12 leg DoFs (19 qpos entries)
    if not rt.configure("upper_body", robot, ikcfg, 1.75, 19):
        push_error(rt.get_last_error())

func _process(_dt: float) -> void:
    if not rt.is_configured():
        return
    # Feed tracked poses (already in the source / GMR coordinate convention).
    rt.set_pose("Hips",  $XRBody/Hips.global_transform)
    rt.set_pose("Chest", $XRBody/Chest.global_transform)
    rt.set_pose("Head",  $XROrigin3D/XRCamera3D.global_transform)
    rt.set_pose("LeftWrist",  $XROrigin3D/LeftHand.global_transform)
    rt.set_pose("RightWrist", $XROrigin3D/RightHand.global_transform)
    # ... remaining mapped joints ...
    var qpos := rt.step()      # length get_nq(); MuJoCo-convention qpos
    # drive the robot / sim with qpos
```

See `example.gd` for a copyable script with an `_extract()` helper.

## Notes / next steps

- **Coordinate frames.** Poses are passed through as-is; the input must already
  be in the source (GMR) convention the `ik_config` expects. The Godot→GMR axis
  mapping (Y-up → Z-up, etc.) is the caller's responsibility for now and is a
  natural place for a small adapter layer later.
- **Asset loading.** The binding takes filesystem paths. On Android, extract
  res:// assets to user:// first (the `_extract()` helper). A future
  string/buffer-based `configure_from_strings()` could avoid the copy.
- **Backend.** Fixed to MuJoCo on Android. The toolkit keeps Pinocchio pluggable
  (desktop), so this stays a one-line change if an MJCF-capable Pinocchio
  Android build is added.
