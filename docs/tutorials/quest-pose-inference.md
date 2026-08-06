# Quest Pose Inference: Operation And Interface

This mode connects Quest to a computer on the same Wi-Fi. Quest sends head,
wrist, and hand-joint tracking once per Godot process frame, with no artificial
client-side rate cap. The server returns a headless Matplotlib 3D visualization
of the newest head and hand pose as an RGB JPEG at up to 20 Hz.

The image overlay shows the latest `pose` frame id and server `image` sequence.
Both should keep increasing while tracking is active.

## Service, QR Code, And Interfaces

The deployed server is `10.10.99.72`; its repository is
`/home/evophys/code/operator`. The continuously running
`pose-inference.service` starts `server/pose_inference_ws.py`. That one program
does three jobs:

- serves the QR-code web page: `http://10.10.99.72:63920/`;
- accepts Quest WebSocket clients: `ws://10.10.99.72:63920/pose-inference`;
- receives pose JSON and returns `PINF` JPEG image messages.

The QR page is generated in memory every time a browser requests `/`; no
separate QR generator needs to be started.

### First-Time Server Installation

Run these commands once as `evophys` after the repository and Python virtual
environment are in place:

```bash
cd /home/evophys/code/operator

sudo install -m 0644 server/pose-inference.service /etc/systemd/system/pose-inference.service
sudo install -d -m 0700 /home/evophys/.config/operator
sudo sh -c "printf 'POSE_INFERENCE_TOKEN=replace-with-a-long-random-token\\n' > /home/evophys/.config/operator/pose-inference.env"
sudo chown root:root /home/evophys/.config/operator/pose-inference.env
sudo chmod 0600 /home/evophys/.config/operator/pose-inference.env
sudo systemctl daemon-reload
sudo systemctl enable --now pose-inference.service
```

Generate a suitable token with `openssl rand -base64 32`. The deployed host is
already installed and enabled; do not rerun these commands in normal use.

### Daily Start, Stop, And Logs

The service starts automatically after server boot. Use:

```bash
sudo systemctl status pose-inference.service
sudo systemctl start pose-inference.service
sudo systemctl restart pose-inference.service
sudo systemctl stop pose-inference.service
sudo journalctl -u pose-inference.service -f
```

Open this address on a LAN computer to show the QR code:

```text
http://10.10.99.72:63920/
```

## Connect Quest

On Quest:

1. Join the same non-guest Wi-Fi as `10.10.99.72`.
2. Open **Operator**, then **Pose Inference**. If its launcher card is absent,
   connect with ADB and ask the maintainer to launch the required mode.
3. In Pose Inference settings, choose QR scan and scan the page's QR code.
4. Keep the mode open. After the first tracking pose, the image updates at
   20 Hz.

Restart after server code/configuration changes:

```bash
sudo systemctl restart pose-inference.service
sudo systemctl is-active pose-inference.service
```

The token is stored in
`/home/evophys/.config/operator/pose-inference.env`; a normal restart keeps it.

## Verify FPS And Delay

Follow the server log while Quest is connected:

```bash
sudo journalctl -u pose-inference.service -f
```

Once per second it writes, for example:

```text
POSE_STATS pose_rx_fps=72.0 image_tx_fps=20.0 head_tracked_fps=72.0 left_hand_tracked_fps=72.0 right_hand_tracked_fps=72.0 pose_rx_bytes=... image_tx_bytes=... latest_pose_frame_id=123 pose_to_image_avg_ms=... pose_to_image_max_ms=...
```

- `pose_rx_fps`: accepted Quest pose messages per second. There is no configured
  target or cap; the measured rate depends on the Quest render/process rate,
  tracking work, JSON serialization, Wi-Fi, and server receive capacity.
- `image_tx_fps`: JPEG images sent to Quest per second; target about 20 after
  the first pose.
- `head_tracked_fps`: accepted poses whose head reports `tracked: true`.
- `left_hand_tracked_fps` / `right_hand_tracked_fps`: accepted poses whose
  corresponding hand reports `tracking: true`.
- `pose_rx_bytes` / `image_tx_bytes`: traffic in that one-second window.
- `latest_pose_frame_id`: latest Quest pose; a stationary number means input
  stopped.
- `pose_to_image_avg_ms` / `pose_to_image_max_ms`: time on the server from
  receiving a pose to sending its associated image. This includes server queue
  wait, fake rendering or model inference, JPEG encoding, and send preparation.

For each WebSocket connection, the first accepted pose is also printed once:

```text
POSE_SAMPLE {"type":"pose","frame_id":1,"capture_time_ns":...,"head":{...},"left":{"tracking":true,"wrist":{...},"joints":[...]},"right":{"tracking":true,"wrist":{...},"joints":[...]}}
```

`POSE_SAMPLE` is the complete head-and-hands JSON frame serialized compactly.
It is intentionally not repeated, so full hand-joint data does not flood the
terminal while the FPS counters continue updating every second.

Quest also displays a metrics line below the image and emits it to logcat each
second:

```text
POSE_E2E_METRICS pose_tx_fps=... image_rx_fps=20.0 e2e_avg_ms=... e2e_max_ms=...
```

`e2e_*` is the actual control-loop latency: Quest pose capture until Quest
receives the corresponding JPEG. It includes Wi-Fi upstream/downstream and the
server work. It is reliable because both timestamps use Quest's same monotonic
clock. It does not include the final GPU display scanout.

Minor variation around 20 image FPS is normal for Wi-Fi and OS scheduling.
Pose FPS is intentionally uncapped and may vary with the Quest runtime.

## Wire Protocol

Endpoint:

```text
ws://10.10.99.72:63920/pose-inference
```

The QR page encodes the endpoint plus a required token. This plain `ws://`
service is LAN-only; do not expose port `63920` to the public internet.

### Quest To Server JSON

First authenticate:

```json
{"type":"hello","token":"QR-code-token"}
```

The server replies:

```json
{"type":"ready","target_hz":20}
```

`target_hz` describes the placeholder image rate. The Quest sends one pose on
every Godot process frame without an artificial pose-rate limit:

```json
{
  "type": "pose",
  "frame_id": 42,
  "capture_time_ns": 123456789000,
  "head": {"tracked": true, "position": [0, 1.6, 0], "rotation": [0, 0, 0, 1]},
  "left": {"tracking": true, "wrist": {}, "joints": []},
  "right": {"tracking": true, "wrist": {}, "joints": []}
}
```

Positions are metres and rotations are `[x, y, z, w]` quaternions. A wrist or
joint is `{"tracked": true, "position": [x,y,z], "rotation": [x,y,z,w],
"radius_m": number}`; unavailable points use `{"tracked": false}`. The
server retains only the newest pose, preventing a latency-inducing queue.

### Server To Quest Binary Image (`PINF`)

Each binary WebSocket payload is a 32-byte big-endian header plus JPEG:

| Byte offset | Size | Value |
| --- | ---: | --- |
| 0 | 4 | ASCII `PINF` |
| 4 | 1 | protocol version `1` |
| 5 | 3 | reserved zero bytes |
| 8 | 8 | `frame_id` unsigned 64-bit |
| 16 | 8 | source `capture_time_ns` unsigned 64-bit |
| 24 | 2 | image width unsigned 16-bit |
| 26 | 2 | image height unsigned 16-bit |
| 28 | 4 | JPEG byte length unsigned 32-bit |
| 32 | variable | JPEG payload, at most 8 MiB |

The visualization stream begins only after one valid pose. It reuses that newest
pose's id and timestamp so Quest can discard images older than its 250 ms stale
limit.

## Matplotlib Pose Visualization

The default server image is a headless Matplotlib 3D rendering of the newest
Quest pose. It draws the head and its forward direction, the left hand in cyan,
and the right hand in orange. Each hand follows the OpenXR 26-joint order.

The plot uses the first tracked head position as its stable origin and maps XR
coordinates `[x, y, z]` to chart coordinates `[x, -z, y]`, labeled right,
forward, and up. Untracked joints are omitted without stopping the image stream.

Rendering runs in a worker thread. The WebSocket receive path continues accepting
uncapped pose frames while the image loop selects the newest pose every 50 ms.
If rendering exceeds that interval, the server skips catch-up work and resumes
from the current time rather than building latency.

## Connecting A Real Model

Replace `MatplotlibPoseRenderer.render` in `server/pose_inference_ws.py` with a
model adapter returning `(width, height, jpeg_bytes)`. Keep JPEG output below
8 MiB. The caller already runs outside the event loop every 50 ms with the newest
pose and deliberately drops older poses. For heavier inference, use a dedicated
worker process or latest-result queue so rendering never accumulates latency.

`POSE_STATS` separates a slow model (low `image_tx_fps`) from missing Quest
tracking (low `pose_rx_fps`). Compare `pose_to_image_*` with Quest `e2e_*`:
the difference is mostly Wi-Fi transport and Quest decode/render scheduling.

## Troubleshooting

From a LAN computer:

```bash
curl -I http://10.10.99.72:63920/
nc -vz 10.10.99.72 63920
```

If `pose_rx_fps` stays zero, ensure Quest is not on guest Wi-Fi, rescan the QR
code, and make sure it is in Pose Inference rather than Live Feed. If
`image_tx_fps` is zero with nonzero `pose_rx_fps`, inspect the service log for
a Python exception.
