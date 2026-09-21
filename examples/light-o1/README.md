# Light-O1: text → whole-body motion on a Unitree G1 in Operator XR

One host example: pick or type a prompt, Light-O1 turns it into a human action,
GEAR-SONIC tracks that action on a G1 in MuJoCo, and the headset shows the
**actual simulated G1** performing it. No physical robot is commanded. The
headset downloads the host's G1 model and renders it; it runs no policy,
physics, or Light-O1 code.

```
prompt ──▶ Light-O1 (GPU service) ──▶ (frames, 138) human action @ 20 FPS
      ──▶ Light-O1 examples.sonic adapter ──▶ pelvis-relative 24-joint reference
      ──▶ GEAR-SONIC low-latency policy + MuJoCo G1, 50 Hz ──▶ qpos every tick
      ──▶ Blueprint robot_model (joint_positions, base_pose, sample) ──▶ headset
```

| Piece | Where it runs | What it needs |
| --- | --- | --- |
| Text → action | Light-O1 `light-deploy-server` (or `light-deploy-api`) | GPU, Light-O1-Preview weights |
| Action → G1 rollout | this host process | Light-O1 checkout, GEAR-SONIC low-latency ONNX pair, MuJoCo, ONNX Runtime (CPU) |
| Rendering + menu | a generic Operator APK | nothing example-specific |

The rollout reproduces the schedule of Light-O1's own `examples.sonic`
(virtual-crane warm-up, 75 settle ticks, 50 Hz tracking with four 5 ms torque
steps) but publishes the robot state after every tick instead of encoding a
video. Playback to the headset starts after a short prefix exists and simply
holds the newest frame if the simulation ever lags; a fall (`pelvis < 0.35 m`)
ends the motion and is reported as such, never hidden.

## Prerequisites

- A Light-O1 checkout with its Sonic example and vendored G1 assets
  (`examples/sonic/assets/g1/`), see <https://github.com/lightorigins/Light-O1>.
  Only its NumPy-only modules are imported here; torch/vLLM stay in the GPU service.
- The GEAR-SONIC **low-latency** ONNX pair (`model_encoder.onnx`,
  `model_decoder.onnx`) in one directory. Follow the provider's license.
- A running Light-O1 service. On apex (`~/ws/light-o1`) that is
  `start_webui.sh` → control server on `:8090`, GPU API on `:8030`.
- Linux, Python 3.11, `uv`, and Rust (`rustup`) for pyoperator's native module.
- A real headset with a current Operator APK on the same LAN.

## Install

```bash
examples/light-o1/setup.sh        # creates examples/light-o1/.venv
```

`setup.sh` installs `requirements.txt` (NumPy 2, MuJoCo, ONNX Runtime CPU,
Pillow) and `pip install -e ./python` (pyoperator, built with maturin). To use
another environment, install the same set yourself; the Light-O1 checkout is
*not* installed, only located with `--light-o1`.

## Run

```bash
# apex defaults: ~/ws/light-o1/Light-O1, ~/ws/light-o1/models/GEAR-SONIC/low_latency, http://127.0.0.1:8090
examples/light-o1/run.sh
# or explicitly
examples/light-o1/.venv/bin/python examples/light-o1/main.py \
  --light-o1 /path/to/Light-O1 \
  --sonic-checkpoint /path/to/GEAR-SONIC/low_latency \
  --url http://127.0.0.1:8090 --headset-ip 192.168.1.50
```

Options: `--generator control|api|file` (control server, GPU API, or saved
`human_action.npy` files via `--actions-dir`), `--prompts FILE` (one per
line, see `prompts.txt`), `--seed`, `--no-thinking`, `--replan-frames`,
`--lookahead-frames`, `--distance` (2.5 m), `--no-face-user` (G1 faces away
like the simulation instead of towards you), `--asset-port` (63904),
`--prebuffer` (0.5 s), `--no-stdin`.

Startup validates the checkout, the checkpoint shapes, and exports the G1 GLB
from the *compiled* MuJoCo model; a Light-O1 service that is not ready is
reported at start and again on the headset when Generate is pressed.

## Headset workflow

Select **Teleop → Outside Robot → Operator → Light-O1 G1** and wait for the
G1 to appear standing in front of you. Open the left-hand system menu (left
controller Menu button, or palm menu with hand tracking). The example adds
four rows, two per page:

| Row | Button | Effect |
| --- | --- | --- |
| Light-O1 motion | **Generate** / Stop | run the current prompt; stop cancels generation or freezes playback |
| Prompt | **Next >** | select the next prompt in the library |
| Prompt | **< Prev** | select the previous prompt |
| Last motion | **Replay** / Stop | replay the last successful rollout without the GPU |

A label above the left controller shows the selected prompt and live status:
`Light-O1 generating... 12s` → `Sonic G1 simulating...` → `Playing 2.3/5.7s`
→ `Done - 5.7s, G1 stayed up` (or `G1 fell at 3.2s`, or the error message).

Free text: type a prompt in the host terminal and press Enter. It is added to
the library, selected, and generated immediately, so the wearer sees it as the
next motion. The shipped Blueprint has no in-headset text field yet; see
`claw/todo/blueprint-text-input.md` for that follow-up.

## Batch mode (no headset)

```bash
examples/light-o1/run.sh --batch "wave with the right hand" --output /tmp/wave.npz
```

Generates, simulates, prints the metrics JSON (`frames`, `survived_s`,
`fell_at`, ...) and saves the trajectory. Use it to check the Light-O1 link
and policy behaviour on a GPU host before involving a headset.

## Tests

```bash
examples/light-o1/.venv/bin/python -m pytest examples/light-o1/tests
```

The unit suite fakes Light-O1, the simulator, and the HTTP services; it needs
no GPU, checkout, or headset. One rollout test runs the *real* Sonic policy
when `LIGHT_O1_ROOT`, `SONIC_TEST_CHECKPOINT`, and `LIGHT_O1_TEST_ACTION` (a
saved `human_action.npy`) are set. On-device rendering of a host G1 is
covered by the generic `cicd/09_blueprint_robot_assets.sh`.

## Limits

- Presentation only: the rollout is a MuJoCo simulation, not a real-robot
  command path. Sonic may fall; the label says so.
- One motion at a time; starting a new prompt cancels the running one and
  waits for the shared simulator to be released.
- Light-O1 actions are 2–20 s; generation latency is that of the GPU service.
- Prompt selection in VR is a library plus host typing until Blueprint gains
  a text-input primitive.
