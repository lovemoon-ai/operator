# BrainCo Revo2 Dual-Hand Gesture Control and Visual Feedback

This integration keeps Revo2 hands in their normal position mode. It does not
claim that position error or raw tactile magnitude is a calibrated force. The
headset shows four separate signals:

- target versus actual motor position as a geometric displacement;
- filtered motor current as green/yellow/red load intensity;
- motor `STALL` state as an explicit contact alert;
- TOUCH fingertip proximity, normal contact, and directional shear.

The canonical six-channel order is `thumb metacarpal opposition`, `thumb
proximal flexion`, `index`, `middle`, `ring`, `pinky`. The SDK names the first
two motors `Thumb` and `ThumbAux`: `Thumb` is the rotation/opposition motor and
`ThumbAux` is the flexion motor. Values sent to the hand SDK are normalized
integers from 0 to 1000.

## Quest Input

`ControlMode` exposes these descriptor sources for both `left` and `right`:

```text
left_hand_thumb_aux
left_hand_thumb_flex
left_hand_index_flex
left_hand_middle_flex
left_hand_ring_flex
left_hand_pinky_flex
```

The right-hand names use the `right_hand_` prefix. Index through pinky flexion
is derived from scale-independent OpenXR chain straightness. The two thumb
motors are independent:

- `Thumb` follows in-palm metacarpal rotation toward opposition and a
  scale-normalized thumb-index pinch constraint. It is capped at 0.5.
- `ThumbAux` follows the summed bend of the OpenXR thumb proximal and distal
  segments and is capped at 0.87.

This preserves the two physical Revo2 thumb degrees of freedom instead of
driving both motors from one curl value. If the runtime does not provide a hand
skeleton, trigger remains the coarse fallback for both thumb axes and index,
while grip controls middle/ring/pinky.

The Thor runtime independently clamps SDK motor 0 (`Thumb`, opposition) to 500
and motor 1 (`ThumbAux`, flexion) to 870 as defense in depth. Per-hand One-Euro
filtering plus a small output deadband suppresses tracking shimmer without a
fixed low-pass delay.

The isolated hand profile exposes an explicit palm menu only when the left palm
faces the headset and all five fingers are open. The menu stays below the palm
and keeps its text facing the operator. Touch the button directly with the right
index fingertip; it does not participate in the hand-ray UI. Approach, press,
trigger, and locked states have distinct visual feedback, and a successful
press plays the system confirmation sound. Pressing `解锁` enables both tracked
hands, and the button changes to `锁定` so control can be stopped explicitly.
Losing tracking disables only the affected hand immediately. Opening Settings,
disconnecting, reconnecting, or leaving Teleop locks both hands again. The
adapter sends one latest-actual-position hold when a hand is disabled; it never
sends an open/reset command.

`operator_xr.integrations.revo2.merge_descriptor()` adds the twelve axes, input
mappings, eight motor telemetry definitions, and ten tactile telemetry
definitions to an existing G1 descriptor.

## Thor Control Loop

Install the official ARM64 SDK in an isolated environment. The upstream SDK
provides an `aarch64` wheel and supports Modbus/RS485 on Revo2 Basic.

The existing G1 process should own one Revo2 context per serial bus and merge
hand handling into the same command/watchdog loop:

```python
from operator_xr.integrations.revo2 import (
    CurrentEma,
    Revo2HandFeedback,
    command_packet_v3,
    command_targets,
    hand_enabled,
    merge_descriptor,
    telemetry_values,
)

descriptor = merge_descriptor(g1_descriptor)
left_current_filter = CurrentEma(alpha=0.35)
right_current_filter = CurrentEma(alpha=0.35)

async def apply_hand_command(command):
    if hand_enabled(command, "left"):
        await left_ctx.set_finger_positions(126, command_targets(command, "left"))
    else:
        await hold_left_at_latest_actual_position()

    if hand_enabled(command, "right"):
        await right_ctx.set_finger_positions(127, command_targets(command, "right"))
    else:
        await hold_right_at_latest_actual_position()

async def collect_hand_telemetry(left_target, right_target):
    left = await left_ctx.get_motor_status(126)
    right = await right_ctx.get_motor_status(127)
    return telemetry_values(
        left=Revo2HandFeedback.from_sequences(
            target=left_target,
            position=left.positions,
            current=left_current_filter.update(left.currents),
            states=left.states,
        ),
        right=Revo2HandFeedback.from_sequences(
            target=right_target,
            position=right.positions,
            current=right_current_filter.update(right.currents),
            states=right.states,
        ),
    )
```

The inspected HoloMotion checkout already has a safer integration point than
opening the serial ports again: its legacy BrainCo runtime accepts version-2
`BCH2` UDP packets and publishes `rt/brainco/{left,right}/state`. Use
`command_packet_v2()` only for that legacy receiver; v2 keeps the old flexion,
opposition channel order. New Operator runtimes use `command_packet_v3()` and
the canonical opposition, flexion order. Convert each DDS
`MotorStates` sample with `Revo2HandFeedback.from_motor_states()`; it maps
`q` to position, `tau_est` to current, and `mode` to the STALL flag. The
Operator bridge then merges `telemetry_values()` into its normal telemetry
frame.

Do not run another SDK process while that runtime owns the Revo2 serial ports.
On deadman release, publish one hold command using the latest DDS `q` before
stopping UDP updates; merely allowing the remote watchdog to go stale prevents
new writes but does not retract the last position target already accepted by
the hand.

Run hand writes at 30-50 Hz, rate-limit every target update, and hold the latest
actual position immediately when a deadman releases or tracking becomes
invalid. Keep the 1-second robot-service watchdog as the independent fallback
for lost command traffic. Keep arm and hand commands in the same process so one
safety state governs the whole upper body.

## Thor Standalone Robot Service

For isolated hand tuning before merging with the G1 adapter, deploy the
`examples/brainco-revo2` service as one self-contained bundle to Thor.
`revo2_thor_service.py` is the only robot-side entry point: it owns both serial
ports, runs the guarded hand loop, hosts the operator_xr adapter on loopback,
and supervises `xr-bridge`.

### Bundle layout

The default paths expect this directory structure:

```text
/home/unitree/ws/operator-hand/
├── revo2_thor_service.py
├── bin/xr-bridge
├── config/revo2_tuning.yaml
├── lib/operator_xr/
└── sdk/bc_stark_sdk/
```

Build `xr-bridge` on Thor or another Linux aarch64 host, then stage the bundle
from the repository root. Extract the official BrainCo Linux aarch64 wheel into
`sdk/`; do not install an x86_64 wheel on Thor.
The hosted Blueprint frames extend the local adapter boundary, so the new
service must be deployed with the `xr-bridge` built from the same checkout; an
older bridge will reject the new frame variants. The PICO APK must also come
from that checkout: Blueprint is enabled only when the Python bundle,
`xr-bridge`, and headset advertise the same generated primitive-spec SHA-256.
A mismatch disables only Blueprint and is reported explicitly in the bridge
log; tracking, control, telemetry, and video can otherwise remain connected.

```bash
cd robot
cargo build --release -p xr-bridge
cd ..

rm -rf /tmp/operator-hand
install -D -m 0755 examples/brainco-revo2/revo2_thor_service.py \
  /tmp/operator-hand/revo2_thor_service.py
install -D -m 0755 robot/target/release/xr-bridge \
  /tmp/operator-hand/bin/xr-bridge
install -D -m 0644 robot/configs/revo2_tuning.yaml \
  /tmp/operator-hand/config/revo2_tuning.yaml
mkdir -p \
  /tmp/operator-hand/lib/operator_xr/integrations \
  /tmp/operator-hand/lib/operator_xr/protocol \
  /tmp/operator-hand/sdk/bc_stark_sdk \
  /tmp/operator-hand/sdk/bc_stark_sdk.libs
for module in __init__.py _blueprint_spec.py hosted.py ik.py models.py blueprint.py retargeting.py robot.py session.py xr_bridge.py; do
  install -m 0644 "python/operator_xr/$module" "/tmp/operator-hand/lib/operator_xr/$module"
done
for module in __init__.py revo2.py revo2_udp.py; do
  install -m 0644 "python/operator_xr/integrations/$module" \
    "/tmp/operator-hand/lib/operator_xr/integrations/$module"
done
for module in __init__.py retargeting.py; do
  install -m 0644 "python/operator_xr/protocol/$module" \
    "/tmp/operator-hand/lib/operator_xr/protocol/$module"
done
rm -rf /tmp/revo2-sdk-wheel
python3 -m zipfile -e /path/to/bc_stark_sdk-*-linux_aarch64.whl \
  /tmp/revo2-sdk-wheel
install -m 0644 /tmp/revo2-sdk-wheel/bc_stark_sdk/main_mod.abi3.so \
  /tmp/operator-hand/sdk/bc_stark_sdk/main_mod.abi3.so
install -m 0644 /tmp/revo2-sdk-wheel/bc_stark_sdk.libs/libudev-*.so.1 \
  /tmp/operator-hand/sdk/bc_stark_sdk.libs/
rsync -a --delete /tmp/operator-hand/ \
  unitree@192.168.124.64:/home/unitree/ws/operator-hand/
```

The `unitree` user must be able to open the two FTDI serial interfaces. Stop any
other manually started hand process before this temporary debug runtime takes
the ports. Do not install, enable, disable, or otherwise change a Thor system
service for this workflow.

```bash
ssh unitree@192.168.124.64
fuser /dev/ttyUSB* 2>/dev/null
cd /home/unitree/ws/operator-hand
./revo2_thor_service.py --check
```

The check validates the ARM64 bridge, bridge config, SDK import, BCH2 protocol
agreement between the runtime and bundled `operator_xr`, and automatic left/right
discovery by Modbus ID and hand serial. Always redeploy the complete bundle when
either the service or `python/operator_xr` changes; mixing a v3 runtime with the
legacy v2 adapter connects successfully but cannot deliver motion commands.
Explicit `--left-port` and `--right-port` overrides remain available, but
persistent `/dev/serial/by-id/...-port0` paths should be used instead of
`ttyUSB` numbers.

Start without `--allow-commands` first. Read-only mode never calls a motion API.
It publishes the Revo2 Blueprint so the headset can validate the robot-authored
status label, per-hand status lamps, user visibility overrides, palm menu, and
fingertip tactile feedback. The menu remains touch-interactive as an input
preview, but its unlocked state cannot cause physical motion in read-only mode:

```bash
cd /home/unitree/ws/operator-hand
./revo2_thor_service.py
```

In the headset, first connect Wi-Fi to the same `192.168.124.0/24` network as
Thor. Then open Teleop, choose Outside Robot, and connect to
`192.168.124.64:63901`. The service scans the FTDI interfaces and selects each
hand by slave ID and hardware serial; explicit `--left-port` and `--right-port`
overrides remain available.

Only after physical clearance and an explicit motion confirmation, restart the
same service with `./revo2_thor_service.py --allow-commands`. An explicit hold
packet stops motion on deadman release; its 1-second watchdog remains the
fallback if command traffic is lost. The guarded defaults are
`--command-side both --rate 50 --touch-rate 20 --touch-timeout-ms 15
--max-step 160 --max-speed 1000 --max-current-ma 500
--protected-current-ma 400`. Tactile reads run as a bounded background sampler
behind the same per-hand serial lock as motor reads and writes, so the SDK
context is never used concurrently and a slow touch read cannot remain inside
the 50 Hz control loop. The adapter sets
each motor speed independently from the measured gesture velocity and the
target-to-actual tracking error, rather than applying one low fixed speed.

The menu is no longer a Revo2-specific XR widget. `revo2_thor_service.py`
publishes a built-in `palm_menu` through `HostedBlueprint`; the headset owns
hand tracking, hit testing, smoothing, and rendering. Show it by facing the left
palm toward the headset with all five fingers open. Use the right index
fingertip to press `解锁`; approach from outside the button, then push the
fingertip into its surface. No hand ray or pinch is used. The resulting
`BlueprintEvent` returns to the service, which is the authoritative
motion gate. Press `锁定` to send hold packets and stop both hands.

The lock resets when Settings disables the hand command stream, when hand
tracking is lost, on any network disconnect/reconnect, bridge shutdown, or when
leaving Teleop; the one-second watchdog remains a fallback. Motion therefore
never resumes automatically. Each tracked palm carries a
robot-authored status lamp: gray means startup has not completed, green means
that hand is connected and locked, orange means control is active, and a
warning state means expected telemetry is unavailable. The head-anchored label
reports read-only, waiting, locked, or unlocked state. All components remain
user-overridable from Teleop settings.

Thor must expose UDP `63900`, TCP `63901`, UDP `63902`, and TCP `63903` to the
headset network. TCP `63910` and UDP `19091`/`19092` are internal adapter/runtime
ports and remain bound to `127.0.0.1`; do not expose them externally.

The hand interface number may change after USB recabling, which is why the
unified service discovers ports by hand serial instead of assuming fixed
interface numbers. The default expected identities are:

- left hand: Revo2 TOUCH, Modbus ID 126, serial `BCXTL2196J2600010`;
- right hand: Revo2 TOUCH, Modbus ID 127, serial `BCXTR2196J2600012`.

On September 1, 2026, the connected FTDI adapter enumerated the left hand on
interface 02 and the right hand on interface 01. Do not encode those interface
numbers into deployment configuration.

## Telemetry Contract

The robot telemetry `values` object may contain either or both hands:

```json
{
  "revo2_left_target": [0, 0, 0, 0, 0, 0],
  "revo2_left_position": [0, 0, 0, 0, 0, 0],
  "revo2_left_current": [0, 0, 0, 0, 0, 0],
  "revo2_left_stall": [0, 0, 0, 0, 0, 0]
}
```

The same keys with `right` describe the right hand. The v1 robot-authored
Blueprint uses fresh `*_position` samples to drive connection status and
menu availability. Motor-position/current/stall arrays remain on the telemetry
channel for logging and future built-in visual components; the migrated example
does not activate the previous hardcoded actuator overlay.

TOUCH and TOUCH PRESSURE hands additionally publish five-element arrays in
physical finger order: thumb, index, middle, ring, pinky.

```json
{
  "revo2_left_touch_normal": [0, 0, 0, 0, 0],
  "revo2_left_touch_tangential": [0, 0, 0, 0, 0],
  "revo2_left_touch_direction": [0, 0, 0, 0, 0],
  "revo2_left_touch_proximity": [0, 0, 0, 0, 0],
  "revo2_left_touch_status": [0, 0, 0, 0, 0]
}
```

These values remain uncalibrated sensor intensities rather than newtons. The
Revo2 Blueprint binds them to the built-in `fingertip_tactile` component. XR
reuses the original logarithmic intensity mapping and renders proximity,
normal contact, strong contact, sensor errors, and directional shear on each
tracked fingertip without restoring robot-specific ownership in the Teleop
controller.
