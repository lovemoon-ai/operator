# ScaleBFM: VR five-point control → host MuJoCo → Blueprint G1

This example runs the **real ScaleBFM checkpoint** on a host CPU or NVIDIA
GPU, executes its 29 joint targets in host-side MuJoCo, and sends the **actual
simulated joint positions and floating-base pose** to Operator XR. The headset
downloads and renders the host-owned G1; no policy, physics, or real robot runs there.

The five points are **pelvis, left/right wrist, left/right foot**, corresponding
to ScaleBridge `control_mode=4` (Root-and-End-Effector), not head + hands + feet.
Only these five body poses become control targets. The 14-link input tensor has
neutral placeholders for the other links, masked by the policy's control mode.

## Prerequisites

- Linux host, Python 3.10 or 3.11, PyTorch >=2.7. NVIDIA/CUDA inference is the
  default; select `--device cpu` explicitly for CPU inference. Tested with
  PyTorch 2.7.0+cu128 and MuJoCo 3.3.6. Missing CUDA fails visibly, without CPU fallback.
- The official raw `humanoid_transformer_m/model_22200.pt`, accompanying
  `metadata.json` (also distributed as `model_22200_tensorrt_metadata.json`),
  and `mode_table.pt`. Download from [ScaleBFM on Hugging Face](https://huggingface.co/WeishuaiZeng/ScaleBFM/tree/main).
  Keep all three together. The raw loader uses `weights_only=True` and strict
  actor/task-embedder state-dict matching; it does not load the critic/optimizer
  onto the GPU, train a substitute model, or require TensorRT.
- The real ScaleBridge G1 model and its meshes. The integration was inspected
  against upstream commit `abd6f17c02fe0baabc14709feb8d9ea4959aa621`:

  ```bash
  git clone https://github.com/zengweishuai/ScaleBFM.git /path/to/ScaleBFM
  git -C /path/to/ScaleBFM checkout abd6f17c02fe0baabc14709feb8d9ea4959aa621
  ```

- A real headset providing valid full-body 6DoF tracking, **including both feet**.
  HMD + controllers alone is insufficient. On Pico, enable/calibrate body
  tracking with the required trackers. Quest support depends on the runtime's
  available body tracking; this example does not fabricate missing legs.
  The adapter supports `pico_bd_24` and `godot_xr_body_tracker_v1` explicitly and
  checks each vendor's position/orientation validity bits, not just `active`.
- Host and headset reachable on the LAN; Operator discovery/control ports
  63900–63903 available. Stop other bridges using those ports first.

From the Operator repository root, in the policy's environment:

```bash
pip install -e ./python
pip install -r examples/scalebfm/requirements.txt
# CUDA PyTorch (omit this if compatible PyTorch is already installed):
pip install 'torch==2.7.0' --index-url https://download.pytorch.org/whl/cu128
```

The example uses the upstream exporter's inference interface; it does not require
IsaacLab, ScaleRetarget, the Xsens receiver, or Unitree's real-robot SDK at runtime.

## Build the headset app

Build/install the generic client once. **Do not run `make_robot` for this
example**: those scripts belong exclusively to Inside Robot.

```bash
cd xr
make build-pico
make install-pico
# For Quest instead: make build-quest && make install-quest
```

Use a single selected device (`ANDROID_SERIAL=...` with multiple headsets).
Always install with `--no-incremental` (the make targets already do).
**Rebuild pyoperator and the APK from this same checkout**: Blueprint negotiates
an exact spec hash; older APKs cannot display `robot_model`.

On startup the host exports its actual MuJoCo G1 visual model and articulation
to a self-contained GLB and serves it on TCP **63904** (`--asset-port`). Allow
that port through the host firewall alongside the existing Operator ports. The
headset fetches from the connected host, verifies size/SHA-256, and caches the
asset. A model change yields a new hash, not a new APK. The current profile
supports triangle meshes with solid colors and scalar joints, without textures
or external resources. No assets from `xr/assets/robots/` are read by this example.

## Run

From the repository root:

```bash
python examples/scalebfm/main.py \
  --checkpoint /path/to/models/model_22200.pt \
  --upstream /path/to/ScaleBFM \
  --model /path/to/ScaleBFM/ScaleBridge/scalebridge/data/robot/g1_29dof/g1_29dof.xml \
  --headset-ip 192.168.1.100
```

`--headset-ip` is optional when broadcast discovery works. The checkpoint is
loaded and a real warm-up inference is performed before the XR session starts.
`--backend torch --device cuda --threads 2` are the defaults. Metadata is found
beside the checkpoint; use `--metadata` or `--mode-table` to override the paths.

`main.py` also opens a **desktop MuJoCo viewer by default**, showing the same
robot state sent to VR, with a camera following the pelvis and an on-screen
tracking/calibration status. It remains responsive and shows the neutral pose
while waiting for a headset. The viewer only copies/renders state; it never
advances physics, and its mouse/UI interactions cannot alter the control state.
Closing the window stops the example and disconnects the bridge, as does Ctrl-C.
Use `--no-viewer` for SSH/headless operation or when only the headset display is
wanted. A graphical desktop (`DISPLAY`/Wayland and GLFW) is required for the window.
`benchmark.py` remains windowless.

The raw loader reads only the model/math declarations from the pinned upstream
standalone exporter, verified by SHA-256; its argparse entry point and TensorRT
compiler are not executed. FK uses the same MuJoCo-compiled joint tree as the
simulation, excluding fixed IMU leaves. Tests compare that FK with `mj_forward`.

1. In the headset choose **Teleop → Outside Robot → Operator → ScaleBFM G1**.
   “Outside” here means host-owned computation, not physical hardware. This uses
   the existing Blueprint adapter; it does not enable the separate VR app mode.
2. Stand facing the XR world's forward direction, feet apart, and approximately
   match the displayed G1 neutral stance. Hold **both controller triggers for
   one continuous second**. Keep your pose until both controllers vibrate:
   vibration confirms that the host successfully reset MuJoCo and aligned the
   five points, not merely that the buttons were held long enough. Release both
   triggers before another reset. A failed/timed-out reset leaves the lamps orange.
3. After the reference buffer fills, move your pelvis, hands and feet. The G1
   displays the simulated result, including base translation and rotation.
4. Hold both triggers for one second again to reset. Ctrl-C stops the host and clears
   the Blueprint. Tracking loss pauses physics and requires explicit
   recalibration; invalid/missing feet are reported rather than filled with zeros.

While waiting for reset, the host continues publishing its stationary simulated
robot pose so the model stays visible for alignment and recentering. Orange lamps
indicate paused input; only a reset acknowledgement can restore the ready state.
Loss of the host connection/pose stream still hides a stale model on the headset.
A one-second hold rejected because tracking or the asset is unavailable gives
error vibration and an explanation in the controller menu, not silent failure.

The **left Menu button** opens/closes a panel above the left controller. Use the
right ray to select **Connect / Disconnect** or **Reset robot position**. The
connection menu is a local system Blueprint and remains available after
disconnect. In hand mode, the same system menu opens with the left-palm gesture
and accepts right-index touch. Robot `menu_item` declarations from other services
are merged into its robot-action section, not separate panels. Recenter places the current robot two metres horizontally ahead,
preserving its height/orientation; it does not reset physics or calibration.
The robot Blueprint contains the model, input binding, ground grid, and model lighting: no reset button,
palm menu, or floating status-text row. Detailed status remains in the menu and
host console. Both controllers show virtual status lamps: grey = disconnected,
flashing blue = connecting/reset pending, orange = reset required, green = ready.

The host declares an **8 m ground grid with 0.5 m spacing** and a **key/fill
lighting rig** through Blueprint. The transparent antialiased grid remains at
ground height as the robot walks or jumps; **Reset robot position** translates
it with the robot's local placement. Lighting brightens only Blueprint robot
models, without changing the app environment or Inside Robot. Both components
are cleared on disconnect and can be hidden in Blueprint visibility settings.
Tune `size`, `spacing`, `color`, and `major_color` on `ground_grid`, or
`key_energy`, `fill_energy`, `key_color`, and `fill_color` on `model_lighting` in
`main.py::blueprint()`. No robot asset or APK rebuild is needed for these parameter
changes after deploying a client with the new primitive spec.
Tracking loss and app suspension cancel pending holds/clicks. Example reset is
separate from Pico's tracker calibration and requires an active full-body stream.

On Pico, full-body capture requires the runtime to advertise
`XR_BD_body_tracking` and **Pico OS 5.13.0 or later**, per the
[official requirements](https://developer.picoxr.com/document/native/body-tracking/).
Calibrating ankle trackers in the system UI does not
prove that this OpenXR interface is available. The native bridge logs extension
availability and body-start/sample failures under `Operator-PicoBody` in adb
logcat. An unavailable extension cannot be fixed by repeating reset.
The sender gives body tracking priority over Pico's mutually exclusive
independent/object-tracker mode; `motion_trackers` is empty in this mode even
when both streams are requested by the SDK.

Options:

| Option | Default | Meaning |
| --- | --- | --- |
| `--scale` | `0.75` | Uniform human-to-G1 displacement scale |
| `--distance` | `2` | Robot display offset along XR world's −Z, metres |
| `--asset-port` | `63904` | Host HTTP port for immutable model assets |
| `--tracking` | `global` | `global` tracks pelvis displacement; `local` uses reference root position in policy observations, like ScaleBridge `reference_forcing=True` |
| `--future-last` | `10` | Last future slot, 5–33 policy steps; reference delay is this value × 20 ms |
| `--tracking-timeout` | `0.25` | Seconds without a new valid body sample before pausing |
| `--backend` | `torch` | Raw checkpoint, `torchscript` trace, or `tensorrt` engine |
| `--device` | `cuda` | CUDA by default; CPU requires explicit selection |
| `--threads` | `2` | PyTorch CPU thread count |
| `--viewer` / `--no-viewer` | enabled | Show/hide the desktop MuJoCo window |

The display offset is world-locked, not continually camera-following. Recenter
XR before calibration. If you recenter or move the tracking origin during a run,
recalibrate. Human-to-robot alignment is a neutral-pose approximation, not a
full anatomical retargeter; extreme motion and poor foot tracking can cause the
simulated robot to fall. Hold both controller triggers for one second to reset it.

For USB-only testing, reverse the command and telemetry TCP ports, then launch
Outside Robot against `127.0.0.1:63901`:

```bash
adb -s SERIAL reverse tcp:63901 tcp:63901
adb -s SERIAL reverse tcp:63903 tcp:63903
adb -s SERIAL shell am start -n com.lovemoon.operator/com.godot.game.GodotApp \
  --es operator.mode teleop --es operator.teleop.host 127.0.0.1 \
  --es operator.teleop.port 63901 --es operator.teleop.protocol operator
```

Room tracking must remain active. A headset system dialog such as “Finding your
position in the room” suspends XR; successful socket connection alone does not
mean full-body poses are available. Do not bypass it with untracked/identity poses.

## Timing and conventions

Policy ticks are 50 Hz; MuJoCo executes four 5 ms PD steps per tick using the
metadata gains and model force limits. If inference cannot sustain 50 Hz,
simulation slows; the loop never queues a backlog of old XR frames.

ScaleBFM is a **state-feedback controller**, not a five-point inverse-kinematics
function. Inputs include history of root quaternion/angular velocity, joint
positions/velocities and raw actions. The action and joint orders come from the
checkpoint metadata and are mapped by name to MuJoCo motor/joint IDs.
`tgt_dof_pos` already includes action scale and offset; these are not applied twice.

As in the official Xsens path, six reference slots `[0,1,2,3,4,X]` are built from
buffered real samples with interpolation and quaternion SLERP. This deliberately
adds 200 ms at the default `X=10`, plus inference/network/rendering latency. It
does **not** predict unavailable future human poses. The actual exported final
input is `(1,6,1)` int64 step indices, not seconds; see the upstream export script.

XR uses Y-up, metres, xyzw. Policy/MuJoCo uses Z-up, metres, wxyz. Both directions
use the model asset convention `robot(x,y,z) → XR(-y,z,-x)`. Blueprint sends all
three robot state bindings atomically: named joint positions in radians,
`base_pose=[x,y,z,qx,qy,qz,qw]`, and a changing sample token. The renderer hides
samples older than 500 ms and smooths fresh samples with a 40 ms time constant.

## Benchmark and TorchScript export

This performs a real policy + MuJoCo closed loop with a scripted five-point
reference. It is **not** a substitute for live VR tracking/device coverage.

```bash
python examples/scalebfm/benchmark.py \
  --checkpoint /path/to/models/model_22200.pt \
  --upstream /path/to/ScaleBFM \
  --model /path/to/ScaleBFM/ScaleBridge/scalebridge/data/robot/g1_29dof/g1_29dof.xml \
  --motion wave --steps 1000 \
  --export /path/to/models/model_22200_torchscript_cuda.pt
```

The trace is compared against eager inference with changed joints, base attitude,
control mode and future offsets, then serialized and reloaded for another check.
Existing artifacts are not overwritten. Its sidecar records the trace's device:
CPU traces run on CPU, CUDA traces on CUDA. After export, `main.py` no longer
needs `--upstream` or the raw weights/mode table:

```bash
python examples/scalebfm/main.py \
  --backend torchscript --device cuda \
  --checkpoint /path/to/models/model_22200_torchscript_cuda.pt \
  --model /path/to/ScaleBFM/ScaleBridge/scalebridge/data/robot/g1_29dof/g1_29dof.xml
```

GPU measurements are the default; use `--device cpu` for a CPU comparison. The report
distinguishes process GPU memory from PyTorch allocated/reserved memory. If an
existing CUDA environment cannot locate `libnvrtc-builtins`, add that environment's
`site-packages/nvidia/cuda_nvrtc/lib` to the command's `LD_LIBRARY_PATH`; do not
replace system CUDA libraries.

TensorRT remains optional: install matching `torch_tensorrt`, then use
`--backend tensorrt --device cuda --checkpoint ..._tensorrt.pt`. Those engines are
GPU/runtime specific; public Linux engines were compiled on a 4090. Raw PyTorch
and CPU TorchScript do not impose that requirement.

As a reference measurement on the development RTX 4050 laptop, this M checkpoint
completed a 20-second scripted-wave MuJoCo run using CPU TorchScript: mean
inference 3.55 ms, full tick P95 4.68 ms, no GPU allocation. Eager CUDA inference
averaged 7.24 ms with about 138 MiB GPU process memory (PyTorch peak allocated
20.7 MiB, reserved 34 MiB). The CUDA TorchScript export completed the same
20-second wave check with mean inference 4.66 ms, full tick P95 5.80 ms and
about 138 MiB process GPU memory. These are observations for this model/environment,
not minimum hardware requirements; rerun the benchmark on your deployment host.

## Verification

Host-side mathematical/contract tests (no fabricated headset runtime):

```bash
PYTHONPATH=python:examples/scalebfm python -m pytest --no-cov \
  python/tests/test_blueprint.py examples/scalebfm/tests
```

Include the real upstream MuJoCo model in the host checks:

```bash
SCALEBFM_G1_XML=/path/to/ScaleBFM/ScaleBridge/scalebridge/data/robot/g1_29dof/g1_29dof.xml \
PYTHONPATH=python:examples/scalebfm python -m pytest --no-cov examples/scalebfm/tests
```

Also set `SCALEBFM_CHECKPOINT` and `SCALEBFM_UPSTREAM` to include real-weight
checks: five-point masking, action scaling, exporter/MuJoCo FK agreement, and
TorchScript export/reload equivalence. No fake policy is used in these checks.
If your pytest environment lacks pytest-cov, replace `--no-cov` with `-o addopts=`.

Device-only Blueprint contract and actual robot-hosted G1 download/import tests:

```bash
bash cicd/xr_module_harness.sh --platform pico --serial SERIAL --suite blueprint
PYTHON=/path/to/python-with-mujoco bash cicd/09_blueprint_robot_assets.sh \
  --model /path/to/ScaleBridge/scalebridge/data/robot/g1_29dof/g1_29dof.xml \
  --platform pico --serial SERIAL --skip-build
```

These checks do not establish policy quality or live full-body tracking. Final
end-to-end acceptance requires a compatible real checkpoint and a tracked person:
calibrate, move all five points, confirm all 29 simulated joints/base animate in
the headset, then remove tracking and verify pause/recalibration behavior.

Upstream: [ScaleBridge deployment and policy interface](https://github.com/zengweishuai/ScaleBFM/blob/abd6f17c02fe0baabc14709feb8d9ea4959aa621/ScaleBridge/README.md).
