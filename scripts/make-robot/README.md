# make-robot

Robot asset generators for the XR Godot client.

Generated third-party source checkouts live outside the repository by default:

```bash
OPERATOR_DEPS_CACHE_ROOT="${OPERATOR_DEPS_CACHE_ROOT:-$HOME/.cache/operator/deps}"
```

Source checkouts are placed under `$OPERATOR_DEPS_CACHE_ROOT/src`, and Python
build tooling is placed under `$OPERATOR_DEPS_CACHE_ROOT/build`.

## H2 + Sharpa

Generate Unitree H2 Plus with integrated Sharpa Wave hands:

```bash
bash scripts/make-robot/make_h2_sharpa.sh
```

Outputs:

- `xr/assets/robots/h2-plus/h2_with_sharpa.glb` - static rest-pose visual overlay for Godot.
- `xr/assets/robots/h2-plus/h2_with_sharpa.urdf` - URDF metadata copy with DAE/STL mesh references.
- `xr/assets/robots/h2-plus/meshes/` - URDF mesh files, colocated for `meshes/...` references.
- `xr/assets/mujoco/h2_with_sharpa.xml` - MuJoCo-loadable proxy XML with the same body/joint names.

The source model is pinned to `unitreerobotics/unitree_ros` at
`cdf67e6eb4c98d73202f29a25e3d098e2aa3b247`, path `robots/h2_plus`.

## Unitree G1 (29-DoF)

Generate the Unitree G1 29-DoF humanoid:

```bash
bash scripts/make-robot/make_g1.sh
```

Outputs:

- `xr/assets/robots/unitree-g1/g1_29dof.glb` - static rest-pose visual overlay for Godot.
- `xr/assets/robots/unitree-g1/g1_29dof.urdf` - URDF metadata copy with STL mesh references.
- `xr/assets/robots/unitree-g1/meshes/` - URDF mesh files, colocated for `meshes/...` references.
- `xr/assets/mujoco/g1_29dof.xml` - MuJoCo-loadable proxy XML with the same body/joint names.

The source model is pinned to `unitreerobotics/unitree_ros` at
`cdf67e6eb4c98d73202f29a25e3d098e2aa3b247`, path `robots/g1_description`
(`g1_29dof.urdf`, all-STL meshes).

## Galbot G1 (Galbot One Golf)

Generate the Galbot One Golf wheeled dual-arm mobile manipulator (referred to as
"Galbot G1"; a different robot from the Unitree G1 above):

```bash
bash scripts/make-robot/make_galbot_g1.sh
```

Outputs:

- `xr/assets/robots/galbot-g1/galbot_g1.glb` - static rest-pose visual overlay for Godot.
- `xr/assets/robots/galbot-g1/galbot_g1.urdf` - URDF metadata copy with STL mesh references
  (upstream visual meshes are `.glb`, converted to `.stl` for the URDF).
- `xr/assets/robots/galbot-g1/meshes/` - URDF mesh files, colocated for `meshes/...` references.
- `xr/assets/mujoco/galbot_g1.xml` - MuJoCo-loadable proxy XML with the same body/joint names.

The source model is pinned to `GalaxyGeneralRobotics/galbot_one_golf_description`
at `4047d57816dd53ef9f9df923b57643826df80b7d`, path `urdf/galbot_one_golf.urdf`.

### Dual-arm EE-pose retargeting

The in-headset overlay `xr/scripts/robot_constraint/robot/galbot_g1_overlay.gd`
uses retargeting v0.1.1's `dual_arm_eepose` algorithm. VR wrist pose deltas are
converted to left/right TCP targets, then the native retargeter outputs a named
robot pose for the 14 arm joints. The wheeled base, leg/lift column, head,
wheels and grippers are not controlled by this overlay.

Supporting retargeting assets:

- `xr/assets/mujoco/galbot_g1.xml` - full MuJoCo proxy model with TCP bodies and
  collision proxy geoms used by `dual_arm_eepose`.
- `xr/assets/retargeting/dual_arm_eepose_galbot_g1.json` - algorithm config
  copied from `retargeting` v0.1.1; `left/right_gripper_tcp_link` track
  `LeftWrist` / `RightWrist` target poses.

Reach it in-app via the capture Settings panel → "Robot Constraint" group →
"Show Galbot G1 model", or the `--operator-galbot-debug` launch flag.

## Dexmate Vega U

Generate Dexmate Vega U upper-body robot with F5D6 dexterous hands:

```bash
bash scripts/make-robot/make_dexmate_vega_u.sh
```

Outputs:

- `xr/assets/robots/dexmate-vega-u/dexmate_vega_u.glb` - static rest-pose visual overlay for Godot.
- `xr/assets/robots/dexmate-vega-u/dexmate_vega_u.urdf` - URDF metadata copy with STL mesh references.
- `xr/assets/robots/dexmate-vega-u/meshes/` - URDF mesh files, colocated for `meshes/...` references.
- `xr/assets/mujoco/dexmate_vega_u.xml` - MuJoCo-loadable proxy XML with the same body/joint names.

URDF outputs keep visual mesh references in STL/DAE-compatible formats.
Generated `.glb` files are only for Godot visual overlays.

The source model is pinned to `dexmate-ai/dexmate-urdf` at
`5f2c4c5fdb91e59bdff2db2cb92bc91033152ea4`, path
`robots/humanoid/vega_1u/vega_1u_f5d6.urdf`.
