# Whole-body control: VR → policy + MuJoCo → Blueprint G1

One host example, two real controllers. The headset sends an atomic body frame;
the selected controller extracts its required points, runs inference and host
physics, and returns **actual simulated joint angles and floating-base pose**.
No physical robot is controlled. The headset downloads the host's model and
renders it; it does not execute policy code or physics.

| Controller | Body targets | Policy runtime | Lower body |
| --- | --- | --- | --- |
| `scalebfm` | Root (mode 0), root + wrists (2), or five-point body (4) | Official ScaleBFM weights; Torch, TorchScript or TensorRT | Commanded root trajectory in LOCOMOTION/VR; tracked feet in BODY |
| `sonic` | Official PICO hand points 22/23 + neck 12, relative to pelvis 0 | Official SONIC v1.1 encoder + decoder and V2 planner; ONNX Runtime CPU/CUDA | Official locomotion planner, driven by sticks/mode buttons |

Both controllers use the shared Operator gamepad mapping below. SONIC retains
the pinned official preprocessing/calibration, planner and POSE streamer, but
not the upstream manager's button shortcuts. Its encoder modes remain G1/planner
**0**, VR_3PT **1**, and SMPL/POSE **2**. Both controllers produce 29 body actions.
SONIC separately drives 14 Dex3 finger joints. ScaleBFM defaults to the standard
29-DoF model without articulated fingers; its trigger/grip bindings stay reserved
but have no effect on that model.

## Install

Linux, Python 3.10/3.11, MuJoCo 3.3.6, a compatible real headset, and host/headset
LAN connectivity are required. SONIC additionally needs a C++20 compiler: it
builds a small adapter around the actual upstream planner/timeline methods.
Install in your chosen environment:

```bash
pip install -e ./python -r examples/whole-body-control/requirements.txt
```

The SDK and both controllers share `numpy>=2,<3` (SciPy >=1.13). In particular,
pyoperator's required rerun-sdk dependency needs NumPy 2; do not downgrade this
environment to NumPy 1 or bypass dependency resolution with `--no-deps`.

For ScaleBFM, follow the [ScaleBFM guide](docs/scalebfm.md), including real weights,
metadata, mode table and the pinned ScaleBridge robot model. Install a matching
PyTorch build; CUDA is the default and CPU must be explicitly selected.

For SONIC, choose **one** ONNX Runtime distribution:

```bash
# CPU (run with --device cpu)
pip install -r examples/whole-body-control/requirements-sonic.txt

# OR NVIDIA GPU (do not also install the CPU onnxruntime package)
pip install -r examples/whole-body-control/requirements-sonic-gpu.txt
```

The CUDA backend must initialize successfully; there is no silent CPU fallback.
If the dynamic loader cannot find `libonnxruntime_providers_shared.so` or
`cudnnCreate`, add the installed `onnxruntime/capi`, `nvidia/cudnn/lib`,
`nvidia/cublas/lib`, and `nvidia/cuda_runtime/lib` directories to
`LD_LIBRARY_PATH` **before** launching. For example, for a Python 3.10 venv:

```bash
SONIC_SITE=/path/to/venv/lib/python3.10/site-packages
export LD_LIBRARY_PATH="$SONIC_SITE/onnxruntime/capi:$SONIC_SITE/nvidia/cudnn/lib:$SONIC_SITE/nvidia/cublas/lib:$SONIC_SITE/nvidia/cuda_runtime/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
```

The adapter also invokes ONNX Runtime's `preload_dlls()` for the CUDA/cuDNN
dependencies. Use an environment with enough GPU memory for both models.

## SONIC assets

Use the [official repository](https://github.com/NVlabs/GR00T-WholeBodyControl)
at commit `a0732b642c0333077e127a2f56ab0014c196bca4` (v1.1):

```bash
git clone https://github.com/NVlabs/GR00T-WholeBodyControl.git /path/to/GR00T-WholeBodyControl
git -C /path/to/GR00T-WholeBodyControl checkout a0732b642c0333077e127a2f56ab0014c196bca4
git -C /path/to/GR00T-WholeBodyControl lfs pull
```

Obtain the three matching files from
[nvidia/GEAR-SONIC/sonic_v1_1](https://huggingface.co/nvidia/GEAR-SONIC/tree/main/sonic_v1_1):
`model_encoder.onnx`, `model_decoder.onnx`, and `observation_config.yaml`, in
one checkpoint directory. Follow upstream's license and model-download terms.
The default/low-latency checkpoints have different observation layouts and are
rejected here rather than guessed. No checkpoint is bundled in Operator.

Download the matching **V2 planner** as well. From the pinned upstream checkout:

```bash
python download_from_hf.py --sonic-v1-1
```

This supplies the policy directory above and
`gear_sonic_deploy/planner/target_vel/V2/planner_sonic.onnx` (about 739 MiB).
`--planner` can point to that artifact elsewhere. The default simulation is
`gear_sonic/data/robot_model/model_data/g1/scene_43dof.xml`: 29 body joints plus
14 hand joints, matching upstream. Calibration uses the actual official
Pinocchio URDF/FK model, not the previous simplified 29-DoF scene.

The adapter verifies fingerprints before loading the upstream preprocessing,
calibration, manager, streamers, FK/SMPL helpers and model descriptions. It
compiles the original `Planner()` and `CurrentFrameAdvancement()` methods and
uses the original `LocalMotionPlannerBase` and `StreamedMotionMerger`; generated
libraries are cached under `~/.cache/operator/sonic/planner/`. It does not launch
XRoboToolkit, IsaacLab, DDS, a robot SDK, or the upstream CLI.

## Run

```bash
python examples/whole-body-control/main.py --controller sonic \
  --upstream /path/to/GR00T-WholeBodyControl \
  --checkpoint /path/to/sonic_v1_1 \
  --device cuda --headset-ip 192.168.1.100

python examples/whole-body-control/main.py --controller scalebfm \
  --checkpoint /path/to/model_22200.pt --upstream /path/to/ScaleBFM \
  --model /path/to/ScaleBFM/ScaleBridge/scalebridge/data/robot/g1_29dof/g1_29dof.xml
```

Use `--controller sonic --help` or `--controller scalebfm --help` for each
controller's options. `--backend` selects its inference implementation, not the
controller. `--no-viewer` disables the otherwise default desktop MuJoCo window.
The viewer uses a separate render snapshot; dragging it cannot perturb physics.
Closing it or Ctrl-C stops the session and clears the robot Blueprint.

ScaleBFM supports `--scale` (default 0.75); official SONIC requires scale **1**
and rejects other values. Both support `--distance` (2 m),
`--tracking-timeout` (0.25 s), `--headset-ip`, and `--asset-port` (63904).
Inference and model validation complete before advertising the XR session.

## Headset workflow

Build/install a generic Operator client with the current Blueprint spec. No XR
script or primitive was added for SONIC; a matching ScaleBFM-capable APK already
has the required renderer. **Do not run `make_robot`**: that is Inside Robot only.

```bash
cd xr
make build-pico
make install-pico
# Or build-quest / install-quest, with a supported body-tracking runtime.
```

Select **Teleop → Outside Robot → Operator → SONIC G1 / ScaleBFM G1**.
Both controllers explicitly request `head`, `controllers`, and `body` in their
SDK connection descriptor. On Pico, unconfirmed tracker calibration opens the
system Robot settings section and blocks control. Complete the Pico setup,
return to Operator, explicitly confirm when tracking is valid, then press
Connect again. This tracker setup is separate from the policy's ABXY reset below.
Wait for the robot asset to appear before initializing. Release all buttons
first; both controllers require a released baseline after connection/tracking loss.

For SONIC, match upstream's zero-reference calibration pose: stand upright,
upper arms at your sides, elbows bent 90 degrees forward, palms inward.

| Input | Shared action (both controllers) |
| --- | --- |
| A+B+X+Y | Initialize/reset physics, clear references, recalibrate, return to LOCOMOTION; **never exits** |
| Left stick click | Cycle LOCOMOTION → VR → BODY → LOCOMOTION, without resetting physics |
| Left stick Y / X | `vx` forward/back / `vy` sideways; right deflection means negative robot Y |
| Right stick X | `vyaw`; right deflection turns right (negative robot Z yaw) |
| Left/right trigger | Analog close of corresponding hand if present; release to open; never resets |
| Grip | Same-hand close alternative; maximum of trigger and grip |
| Left Menu | Operator connection/recenter menu |
| Ctrl-C / close desktop viewer | Stop the host |

Face-button subchords A+B, X+Y, A+X and B+Y have no separate action, avoiding
accidental mode changes while assembling ABXY. Each press acts once; release
all four face buttons before another reset. After reset/mode change, center
both sticks before moving. The common deadzone is 0.15, maximum planar speed
0.6 m/s, and maximum yaw rate 1.5 rad/s. Right-stick Y is unused.

| Shared mode | ScaleBFM | SONIC |
| --- | --- | --- |
| LOCOMOTION (after reset) | Native root-only mode 0, commanded root trajectory | Official planner; automatic IDLE/SLOW_WALK |
| VR | Native root+wrists mode 2; wrists relative to pelvis, root from sticks | Official VR_3PT targets plus planner lower-body reference |
| BODY | Original five-point mode 4 (pelvis, wrists, feet) | Official full-body SMPL/POSE |

Sticks drive locomotion in LOCOMOTION and VR. BODY follows human motion and
ignores stick locomotion, so two sources cannot fight over the root/legs.
Hand bindings are identical in all three modes. ScaleBFM uses exactly the model
passed to `--model`, normally upstream `g1_29dof.xml`; it never automatically
substitutes `g1_29dof_dex3.xml` or requires the Dex3 asset. With no articulated
hands, triggers/grips are no-ops, not alternate reset buttons. Explicit Dex3
models retain optional independent hand control, but this is not a claim that
the ScaleBFM checkpoint learned finger control or was validated for that dynamics.

Before entering VR, align your arms to the current robot pose. Entering it
does not reset physics. Centered sticks send zero velocity / SONIC IDLE. Whole-person room
translation cancels in pelvis-relative input; walking comes from the planner's
commands, not a guessed walking intent from body displacement.

SONIC requires the PICO `pico_bd_24` stream, including all 24 pose records.
LOCOMOTION/VR require valid pelvis, hand and neck targets; BODY rejects the
frame unless all 24 joints have valid tracked 6DoF poses. It deliberately does not substitute head 15,
wrists 20/21, HMD/controllers, Godot's differently framed skeleton, or fabricated
SMPL frames. The official preprocessing applies its per-joint OFFSETS first,
then normalizes both positions and orientations relative to pelvis, then applies
CALIB_FULL/CALIB. The neck target position is reconstructed from its calibrated
orientation using the official 0.05 m + 0.35 m kinematic chain.

ScaleBFM still supports both `pico_bd_24` and `godot_xr_body_tracker_v1`.
Runtime tracking availability depends on the headset/OS. Invalid/stale input
pauses physics and requires restarting/recalibrating; paused state stays visible.
Frame-sequence restarts or source-clock rollback invalidate calibration even
when a brief disconnect falls between host polls; fresh input cannot resume
physics without a new reset.

Left Menu opens the shared connection/recenter menu. Recenter only translates
the local display; it does not reset policy, physics, calibration, or host base
pose. Both Blueprints declare model, ground grid, lights and a controller-attached
mode/status label. Read that label or the host console to confirm initialization;
the former dual-trigger hold/acknowledgement vibration is no longer used.

### Alignment boundary

SONIC's body/root transforms, zero/measured-pose calibration, POSE conversion,
30→50 Hz planner resampling, eight-frame blending, replan decisions and idle
readaptation still use pinned upstream algorithms. **Button semantics, mode
cycle, velocity limits and analog hand mapping are Operator-specific**, shared
with ScaleBFM. The original SONIC manager is retained only for conformance tests,
not used by the live example. ONNX Runtime is still the inference engine, not upstream's
TensorRT engine; bitwise equality and identical performance are not claimed.
Operator retains its connection, stale-input and local-UI input-capture guards.
While a local menu captures input, neutralized controls reach the host. Left Menu
is not also forwarded to the upstream POSE pause binding.
The pinned SMPL swing/twist helper is singular for an exactly zero elbow
axis-angle; its behavior is not silently replaced by another algorithm here.

## Model transport and timing

`from_mujoco` exports the actual host model into a data-only articulated GLB;
`RobotAssetServer` serves immutable bytes. The headset validates length/hash,
downloads/caches it, and renders all named joints and the root. Adding/changing
this Outside model does not require adding APK assets or a model allowlist.
Allow host TCP 63904 plus Operator's discovery/control ports 63900–63903.
USB tests also need `adb reverse tcp:63904 tcp:63904`, alongside command/telemetry
ports 63901 and 63903. This transport assumes a trusted LAN.

Policy ticks are 50 Hz with four 5 ms MuJoCo steps. Slow inference slows the sim;
the loop does not queue old XR frames or burst overdue ticks. ScaleBFM BODY retains
its six-slot delayed reference buffer; LOCOMOTION/VR construct commanded future
root goals (not predicted human motion). SONIC uses ten-frame robot history,
20 Hz planner commands, the 50 Hz official POSE streamer, and a
separate 10 Hz planner worker. Offline benchmarks use the same native algorithms
synchronously for repeatable virtual-time execution; `--realtime` exercises the
live worker. Its
`encoder_mode_4` contains `[1,0,0,0]` (numeric mode plus padding, **not one-hot**).
Only mode-required encoder fields are filled; the others are masked zeros.

The 29 raw actions are scaled/offset once, applied through the official PD gains,
and limited by the model actuators. Only resulting state is displayed. Robot
Z-up/wxyz is converted to XR Y-up/xyzw; joints, base and sample token are published
together through latest-wins state. Display smoothing is not control feedback.

## Verification

Host tests do not substitute for device coverage:

```bash
pip install pytest PyYAML
python -m pytest -o addopts= examples/whole-body-control/tests

# Enable real SONIC weights, 20-second physics test and upstream C++ parameter oracle:
SONIC_UPSTREAM=/path/to/GR00T-WholeBodyControl \
SONIC_CHECKPOINT=/path/to/sonic_v1_1 \
SONIC_PLANNER=/path/to/planner_sonic.onnx \
python -m pytest -o addopts= examples/whole-body-control/tests/test_sonic_policy.py \
  examples/whole-body-control/tests/test_sonic_official.py

# CPU benchmark; omit --device cpu to require CUDA:
python examples/whole-body-control/benchmark.py --controller sonic \
  --upstream /path/to/GR00T-WholeBodyControl --checkpoint /path/to/sonic_v1_1 \
  --device cpu --motion walk --steps 1000
```

Set `SONIC_DEVICE=cuda` for GPU policy tests. Real ScaleBFM tests use
`SCALEBFM_CHECKPOINT`, `SCALEBFM_UPSTREAM` and `SCALEBFM_G1_XML`; see its guide.
Set `SONIC_G1_XML` to include SONIC's model in the exported-GLB/MuJoCo FK check.
The official planner adapter requires a C++20 compiler. Without external model paths,
real-model tests skip visibly. Scripted benchmark references only test host
policy/physics, not tracking or headset interaction.

```bash
bash cicd/xr_module_harness.sh --platform pico --serial SERIAL --suite blueprint
PYTHON=/path/to/python bash cicd/09_blueprint_robot_assets.sh \
  --model /path/to/GR00T-WholeBodyControl/gear_sonic/data/robot_model/model_data/g1/scene_43dof.xml \
  --platform pico --serial SERIAL
```

Live acceptance requires a tracked person: calibrate both controllers' examples,
move each required point, check headset/desktop motion agrees, remove tracking,
confirm pause, then reset/reconnect and recenter. Device asset tests alone do not
prove live three-point control. Never run the XR project in desktop headless mode.

## Layout and compatibility

`wbc/app.py`, `loop.py`, `tracking.py`, `presentation.py` and `desktop_viewer.py`
own shared orchestration; `controllers/scalebfm` and `controllers/sonic` own
calibration, policy inputs/outputs and simulation configuration. Controller-specific
dependencies are imported only for the selected controller. This is an example-local
contract, not a new general-purpose framework in pyoperator.

`examples/` is a general directory, **not a Python package API**. Direct script
execution already places this example directory on Python's import path. To
reuse its code from another script, explicitly add the example directory (the
parent of `wbc`) to `PYTHONPATH`, then import `wbc`:

```bash
PYTHONPATH=/path/to/operator/examples/whole-body-control python -c \
  'from wbc.controllers.sonic.pico_input import OfficialThreePoint'
```

Install pyoperator normally as described above. Example directories are not
package APIs; add this directory to `PYTHONPATH` and import `wbc` explicitly.

The former `examples/scalebfm` tree has been removed. There is one runtime loop;
new integrations should import `wbc` from this example directory.
