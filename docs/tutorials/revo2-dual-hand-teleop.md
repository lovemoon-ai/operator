# BrainCo Revo2 Dual-Hand Gesture Control and Visual Feedback

This integration keeps the Revo2 Basic hands in their normal position mode.
It does not claim that position error is a calibrated force. The headset shows
three separate signals:

- target versus actual motor position as a geometric displacement;
- filtered motor current as green/yellow/red load intensity;
- motor `STALL` state as an explicit contact alert.

The six-channel order is `thumb proximal flex`, `thumb metacarpal
abduction/opposition`, `index`, `middle`, `ring`, `pinky`. The SDK names the
first two motors `Thumb` and `ThumbAux`. The official ROS driver exposes them
as the thumb proximal and thumb metacarpal joints respectively. Values sent to
the hand SDK are normalized integers from 0 to 1000.

## Quest Input

`ControlMode` exposes these descriptor sources for both `left` and `right`:

```text
left_hand_thumb_flex
left_hand_thumb_aux
left_hand_index_flex
left_hand_middle_flex
left_hand_ring_flex
left_hand_pinky_flex
```

The right-hand names use the `right_hand_` prefix. Index through pinky flexion
is derived from scale-independent OpenXR chain straightness. The two thumb
motors are independent:

- `Thumb` follows the summed bend of the OpenXR thumb proximal and distal
  segments and is capped at 0.5.
- `ThumbAux` follows the in-palm rotation of the OpenXR thumb metacarpal toward
  opposition. It is measured in a hand-local basis built from wrist and MCP
  joints, works identically for left and right hands, and is capped at 0.85.

This preserves the two physical Revo2 thumb degrees of freedom instead of
driving both motors from one curl value. If the runtime does not provide a hand
skeleton, trigger remains the coarse fallback for both thumb axes and index,
while grip controls middle/ring/pinky.

The Thor runtime independently clamps SDK motor 0 (`Thumb`) to 500 and motor 1
(`ThumbAux`) to 870 as defense in depth.

The isolated hand profile uses an explicit `解锁` button mounted just above the
left wrist, beside its status lamp. Touch it directly with the right index
fingertip; it does not participate in the hand-ray UI. Pressing it enables both
tracked hands, and the button changes to `锁定` so control can be stopped
explicitly. Hand orientation and wrist height do not affect the lock state.
Losing tracking still disables that hand's command immediately, and opening
Settings, disconnecting, or reconnecting locks both hands again. The adapter
sends one latest-actual-position hold when a hand is disabled; it never sends an
open/reset command.

`pyoperator.integrations.revo2.merge_descriptor()` adds the twelve axes,
input mappings, and eight telemetry definitions to an existing G1 descriptor.

## Thor Control Loop

Install the official ARM64 SDK in an isolated environment. The upstream SDK
provides an `aarch64` wheel and supports Modbus/RS485 on Revo2 Basic.

The existing G1 process should own one Revo2 context per serial bus and merge
hand handling into the same command/watchdog loop:

```python
from pyoperator.integrations.revo2 import (
    CurrentEma,
    Revo2HandFeedback,
    command_packet_v2,
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
opening the serial ports again: its BrainCo runtime accepts version-2 `BCH2`
UDP packets and publishes `rt/brainco/{left,right}/state`. Use
`command_packet_v2()` for the existing UDP receiver. Convert each DDS
`MotorStates` sample with `Revo2HandFeedback.from_motor_states()`; it maps
`q` to position, `tau_est` to current, and `mode` to the STALL flag. The
Operator bridge then merges `telemetry_values()` into its normal telemetry
frame.

Do not run another SDK process while that runtime owns `/dev/ttyUSB1` and
`/dev/ttyUSB3`. On deadman release, publish one hold command using the latest
DDS `q` before stopping UDP updates; merely allowing the remote watchdog to go
stale prevents new writes but does not retract the last position target already
accepted by the hand.

Run hand writes at 30-50 Hz, limit each target change to at most 50-80 units
per update, and hold the latest actual position when a deadman releases,
tracking becomes invalid for 1 second, or robot-service watchdog fires. Keep arm
and hand commands in the same process so one safety state governs the whole
upper body.

For isolated hand tuning before merging with the G1 adapter, the repository
also contains a guarded UDP runtime and a hand-only Operator adapter. Connect to
Thor with `ssh unitree@192.168.124.64` and run it from `/home/unitree/ws`.
Start the Thor side without `--allow-commands` first; that mode owns the two serial ports,
never calls a motion API, and previews received gesture targets beside actual
positions in the headset:

```bash
PYTHONPATH=/tmp/revo2-sdk-1.5.1 python3 scripts/revo2_udp_runtime.py \
  --telemetry-host 192.168.124.137 --allowed-source 192.168.124.137 \
  --left-port /dev/serial/by-id/usb-FTDI_USB__-__Serial_Converter_FTA8Q5TE-if01-port0 \
  --left-serial BCXRL2103J2600007 \
  --right-port /dev/serial/by-id/usb-FTDI_USB__-__Serial_Converter_FTA8Q5TE-if03-port0 \
  --right-serial BCXRR2100J2600007
```

On the Ubuntu headset host, run the adapter and `xr-bridge`:

```bash
cd python
PYTHONPATH=. python3 ../scripts/revo2_operator_adapter.py \
  --runtime-host 192.168.124.64 \
  --command-speed 0.12 --max-command-speed 1.0 \
  --command-catchup-ms 70 --command-speed-gain 1.0

cd ../robot
cargo run -p xr-bridge -- \
  --config configs/revo2_tuning.yaml
```

Only after physical clearance and an explicit motion confirmation, restart the
Thor runtime with `--allow-commands`. An explicit hold packet stops motion on
deadman release; its 1-second watchdog remains the fallback if command traffic
is lost. For responsive
six-channel dual-hand tracking, use `--command-side both --rate 50
--max-step 160 --max-speed 1000 --max-current-ma 500
--protected-current-ma 400`. The adapter sets
each motor speed independently from the measured gesture velocity and the
target-to-actual tracking error, rather than applying one low fixed speed.

Use the right index fingertip to press the `解锁` button attached to the left
wrist. Approach from outside the button, then push the fingertip into its
surface; no hand ray or pinch is used. Press the same button after it changes to
`锁定` to stop both hands. The lock resets after opening Settings or after any
network disconnect/reconnect, so motion never resumes automatically.
Each tracked wrist carries a three-state status lamp: gray means the robot link
is disconnected, green means the link is connected but that hand is locked, and
orange means the explicit unlock is active and that tracked hand can command its
Revo2. Opening the settings panel returns orange to green because the panel
intentionally locks command output without disconnecting the link.

## Read-Only Hardware Check

The checked-in probe performs discovery and status reads only; it never calls a
motion API:

```bash
python scripts/revo2_read_only_probe.py \
  --port /dev/ttyUSB0 --port /dev/ttyUSB1 \
  --port /dev/ttyUSB2 --port /dev/ttyUSB3
```

It prints the exact flat telemetry object consumed by the headset overlay.
On the currently inspected Thor, the four serial nodes are interfaces of one
FT4232H adapter. Use persistent `/dev/serial/by-id/...-ifNN-port0` paths in the
deployment configuration rather than relying on `ttyUSB` numbering. Leave
`--protocol` unset for the first probe so the SDK can distinguish Modbus from a
serially attached CAN/CAN FD adapter.

The read-only probe on August 26, 2026 found:

- left hand: Modbus ID 126, `MediumLeft`, firmware `1.0.22.U`, interface 01
  (`/dev/ttyUSB1` during the probe);
- right hand: Modbus ID 127, `MediumRight`, firmware `1.0.22.U`, interface 03
  (`/dev/ttyUSB3` during the probe).

Interfaces 00 and 02 did not report a hand. The stable deployment paths are the
FTDI by-id names ending in `if01-port0` and `if03-port0`.

## Quest Visualization Contract

The robot telemetry `values` object may contain either or both hands:

```json
{
  "revo2_left_target": [0, 0, 0, 0, 0, 0],
  "revo2_left_position": [0, 0, 0, 0, 0, 0],
  "revo2_left_current": [0, 0, 0, 0, 0, 0],
  "revo2_left_stall": [0, 0, 0, 0, 0, 0]
}
```

The same keys with `right` drive the right panel. Each row renders the actual
position marker, translucent target marker, and the line between them. Current
controls marker/load-bar color; `STALL` forces red and enlarges the marker.
Telemetry older than 800 ms is marked stale and hidden after three seconds.

This is intentionally a schematic actuator view. A later strict spatial view
can replace each row with Revo2 URDF forward kinematics while preserving the
same telemetry contract.
