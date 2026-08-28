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

For isolated hand tuning before merging with the G1 adapter, deploy one
self-contained bundle to Thor. `revo2_thor_service.py` is the only robot-side
entry point: it owns both serial ports, runs the guarded hand loop, hosts the
pyoperator adapter on loopback, and supervises `xr-bridge`.

### Bundle layout

The default paths expect this directory structure:

```text
/home/unitree/ws/operator-hand/
├── revo2_thor_service.py
├── bin/xr-bridge
├── config/revo2_tuning.yaml
├── lib/pyoperator/
└── sdk/bc_stark_sdk/
```

Build `xr-bridge` on Thor or another Linux aarch64 host, then stage the bundle
from the repository root. Extract the official BrainCo Linux aarch64 wheel into
`sdk/`; do not install an x86_64 wheel on Thor.

```bash
cd robot
cargo build --release -p xr-bridge
cd ..

rm -rf /tmp/operator-hand
install -D -m 0755 scripts/revo2_thor_service.py \
  /tmp/operator-hand/revo2_thor_service.py
install -D -m 0755 robot/target/release/xr-bridge \
  /tmp/operator-hand/bin/xr-bridge
install -D -m 0644 robot/configs/revo2_tuning.yaml \
  /tmp/operator-hand/config/revo2_tuning.yaml
mkdir -p /tmp/operator-hand/lib /tmp/operator-hand/sdk
cp -a python/pyoperator /tmp/operator-hand/lib/
python3 -m zipfile -e /path/to/bc_stark_sdk-*-linux_aarch64.whl \
  /tmp/operator-hand/sdk
rsync -a --delete /tmp/operator-hand/ \
  unitree@192.168.124.64:/home/unitree/ws/operator-hand/
```

The `unitree` user must be able to open the two FTDI serial interfaces. Stop any
other hand process before starting this service; in particular,
`brainco_hand_control_server` must not own the same serial ports.

```bash
ssh unitree@192.168.124.64
sudo systemctl disable --now brainco_hand_control_server.service
cd /home/unitree/ws/operator-hand
./revo2_thor_service.py --check
```

The check validates the ARM64 bridge, bridge config, SDK import, and automatic
left/right discovery by Modbus ID and hand serial. Explicit `--left-port` and
`--right-port` overrides remain available, but persistent
`/dev/serial/by-id/...-port0` paths should be used instead of `ttyUSB` numbers.

Start without `--allow-commands` first. Read-only mode never calls a motion API
and previews received gesture targets beside actual positions in the headset:

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
`--command-side both --rate 50 --max-step 160 --max-speed 1000
--max-current-ma 500 --protected-current-ma 400`. The adapter sets
each motor speed independently from the measured gesture velocity and the
target-to-actual tracking error, rather than applying one low fixed speed.

Show the menu by facing the left palm toward the headset with all five fingers
open. Use the right index fingertip to press `解锁`; approach from outside the
button, then push the fingertip into its surface. No hand ray or pinch is used.
Press `锁定` to stop both hands. The lock resets after opening Settings, any
network disconnect/reconnect, or leaving Teleop, so motion never resumes
automatically.
Each tracked wrist carries a three-state status lamp: gray means the robot link
is disconnected, green means the link is connected but that hand is locked, and
orange means the explicit unlock is active and that tracked hand can command its
Revo2. Opening the settings panel returns orange to green because the panel
intentionally locks command output without disconnecting the link.

### Install as a systemd robot service

After the foreground read-only and controlled runs both pass, install the same
entry point as the robot service:

```ini
# /etc/systemd/system/operator-revo2.service
[Unit]
Description=Operator Revo2 dual-hand robot service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=unitree
WorkingDirectory=/home/unitree/ws/operator-hand
Environment=PYTHONUNBUFFERED=1
ExecStart=/home/unitree/ws/operator-hand/revo2_thor_service.py --allow-commands --advertise-host 192.168.124.64
Restart=on-failure
RestartSec=2
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now operator-revo2.service
systemctl status operator-revo2.service
journalctl -u operator-revo2.service -f
```

Thor must expose UDP `63900`, TCP `63901`, UDP `63902`, and TCP `63903` to the
headset network. TCP `63910` and UDP `19091`/`19092` are internal adapter/runtime
ports and remain bound to `127.0.0.1`; do not expose them externally.

The hand interface number may change after USB recabling, which is why the
unified service discovers ports by hand serial instead of assuming fixed
interface numbers. The default expected identities are:

- left hand: Modbus ID 126, serial `BCXRL2103J2600007`;
- right hand: Modbus ID 127, serial `BCXRR2100J2600007`.

On August 28, 2026, the connected FTDI adapter enumerated the left hand on
interface 01 and the right hand on interface 02. Do not encode those interface
numbers into deployment configuration.

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
