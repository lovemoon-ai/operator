# Wire-protocol reference

Authoritative byte-level reference for every channel the Rust agent
(robot side) and the Godot XR client (headset side) speak to each
other. This document is the internal companion to the public
`claw/sop/add-new-video-source.md` — the SOP tells you the minimum
you need to *implement* a robot; this doc tells you what the bytes
*actually look like* and where every constant lives in code.

Three independent implementations exist in this tree:

1. **Rust (canonical robot side)** — `robot/src/network/*.rs` and
   `robot/src/video/pipeline.rs`.
2. **GDScript (XR side)** — `xr/scripts/network/*.gd` and
   `xr/scenes/main.gd`.
3. **Reference Python** — `tools/mac_mock_streamer.py`. Minimal,
   exercises every required surface. Read this first if you are
   building a fourth implementation from scratch.

Where the three disagree, the Rust side is canonical and the
disagreement is called out in the relevant section.

## Cross-cutting rules

### Endianness — mixed, by channel

| Surface                      | Length / int endianness |
|------------------------------|-------------------------|
| Command channel (TCP 63901)  | **little-endian** i32 lengths, UTF-8 strings |
| Pose UDP (UDP 63902)         | **little-endian** for header + payload floats |
| Video TCP (TCP 12345)        | **big-endian** everywhere (TimedVideoFrame header + NAL length) |
| Video UDP (UDP 12345)        | **big-endian** for both the NLFR fragment header and the embedded TimedVideoFrame header |
| Discovery (UDP 63900)        | JSON text — endianness N/A |

The command-channel-vs-everything-else split is the single biggest
tripwire for new implementers. It exists because the original C#
client (`NetworkDataProtocolSerializer.cs`) used `BitConverter.GetBytes`
on little-endian Windows; the H.264 NAL length prefix uses standard
network byte order. Documented at
`robot/src/network/protocol.rs:38` (LE) and
`robot/src/network/protocol.rs:113` (BE).

### Size limits

| Constant                          | Value         | Source |
|-----------------------------------|---------------|--------|
| `MAX_CMD_LEN`                     | 64 KiB        | `robot/src/network/protocol.rs:45` |
| `MAX_DATA_LEN`                    | 16 MiB        | `robot/src/network/protocol.rs:47` |
| `MAX_NAL_SIZE`                    | 10 MiB        | `robot/src/network/protocol.rs:126` |
| `UDP_NAL_FRAGMENT_PAYLOAD`        | 1200 B        | `robot/src/video/pipeline.rs:37` |
| `UDP_MAX_PAYLOAD`                 | 60 KiB        | `robot/src/video/pipeline.rs:27` (assert only) |
| `TIMED_VIDEO_HEADER_BYTES`        | 80            | `robot/src/network/protocol.rs:207` |
| `UDP_FRAGMENT_HEADER_BYTES`       | 18            | `robot/src/video/pipeline.rs:58` |
| `POSE_UDP_HEADER_SIZE`            | 32            | `robot/src/network/protocol.rs:307` |
| `POSE_UDP_POSE_PAYLOAD_SIZE`      | 64            | `robot/src/network/protocol.rs:309` |
| GDScript `DEFAULT_MAX_RECV_BUFFER`| 10 MiB        | `xr/scripts/network/tcp_handler.gd:78` |
| GDScript video receive cap        | 32 MiB        | `xr/scenes/main.gd:115` (raised via `set_max_recv_buffer`) |

A peer that sends > `MAX_*` is disconnected with an
`InvalidData` error on the Rust side; the GDScript decoder returns
`{"error": ...}` and clears the receive buffer
(`xr/scripts/network/tcp_handler.gd:240`,
`xr/scripts/network/tcp_handler.gd:272`).

### Reliability story

Per `claw/issues/005-decisions.md` D-1 through D-3:

| Channel                        | Transport | Reliability    | Why |
|--------------------------------|-----------|----------------|-----|
| Discovery (63900)              | UDP bcast | best-effort    | Re-broadcast every 3 s. Lost beacon is harmless. |
| Command (63901)                | TCP       | reliable, ordered | Handshake, descriptor, telemetry, clock-sync — must not drop. |
| Pose UDP (63902)               | UDP       | best-effort, drop-old by `seq` | Wi-Fi HOL avoidance. Latest pose is the only useful one (D-1). |
| Telemetry (63903)              | TCP       | reliable       | 10 Hz push — same socket-buffer reasoning as command channel, kept isolated from the hot path. |
| Video TCP (12345)              | TCP       | reliable, ordered | Smoke-test loop over `adb reverse` (TCP-only). |
| Video UDP (12345)              | UDP       | best-effort, no FEC, no retransmit | Tail-latency over reliability for sub-100 ms teleop (D-3). One lost fragment = one lost NAL; recovery is the next IDR (GOP=0.5 s). |

---

## Port allocation summary

All ports are bound on `0.0.0.0` on the robot side. The XR side
discovers ports either from the discovery announcement or from the
DeviceDescriptor.

| Port  | Protocol | Direction      | Role                                   | Default source |
|-------|----------|----------------|----------------------------------------|----------------|
| 63900 | UDP      | robot → bcast  | Discovery beacon (JSON, 3 s cadence)   | `robot/src/config.rs:42`, hard-coded `DISCOVERY_PORT = 63900` in `xr/scripts/network/discovery.gd:17` |
| 63901 | TCP      | XR → robot     | Command channel (Hello / Descriptor / DeviceCommand / Clock / Telemetry-legacy) | `robot/src/config.rs:38` |
| 63902 | UDP      | XR → robot     | High-rate pose data plane              | `robot/src/config.rs:44`, `default_pose_udp_port()` `robot/src/config.rs:80` |
| 63903 | TCP      | XR → robot     | Dedicated telemetry channel            | `robot/src/config.rs:56`, `default_telemetry_port()` `robot/src/config.rs:76` |
| 12345 | TCP      | XR → robot     | Video stream (legacy, used by `ffplay`-style preview and `adb reverse`) | `robot/src/config.rs:40`, `robot/src/config.rs:87` |
| 12345 | UDP      | XR → robot     | Video stream (recommended for Wi-Fi)   | `VideoConfig.udp_port` `robot/src/config.rs:107`; by convention same number as TCP |

---

## Channel 1 — Discovery (UDP 63900)

* **Port + protocol:** UDP 63900, broadcast.
* **Direction:** Robot → broadcast (`255.255.255.255:63900`, or
  subnet-directed broadcast like `10.79.159.255:63900` on Mac with
  multi-interface routing) every 3 s.
* **Cadence:** 3 s, fixed.

### Payload

JSON object, UTF-8, no framing (one datagram = one message):

```json
{
  "service": "xrobo-agent",
  "name": "robo-1",
  "tcp_port": 63901,
  "video_port": 12345,
  "telemetry_port": 63903,
  "pose_udp_port": 63902,
  "version": "0.6.0",
  "device_type": "robot_arm",
  "device_name": "SO-101"
}
```

XR side requires `service == "xrobo-agent"` and `tcp_port > 0`;
everything else is best-effort. See
`xr/scripts/network/discovery.gd:54` (validator) and
`xr/scripts/network/discovery.gd:58-62` (field reads — only `name`,
`tcp_port`, `video_port`, `device_type`, `device_name` are
extracted).

### Failure modes

* Lost beacon: ignored. Next one is 3 s away.
* Robots time out from the known-set after `ROBOT_TIMEOUT = 10.0` s
  with no beacon (`xr/scripts/network/discovery.gd:19`).
* Limited broadcast (`255.255.255.255`) can fail with
  `EADDRNOTAVAIL` on multi-interface hosts (Mac + VPN). The Python
  reference falls back to subnet-directed broadcast
  (`tools/mac_mock_streamer.py:181-205`).

### Implementations

* **Robot encode:** `robot/src/network/discovery.rs:65-90`.
* **XR decode:** `xr/scripts/network/discovery.gd:49-81`.
* **Python:** `tools/mac_mock_streamer.py:167-212`.

### Inconsistencies

The Rust beacon (`robot/src/network/discovery.rs:65-75`) advertises
`telemetry_port` and `pose_udp_port`. The XR side
(`xr/scripts/network/discovery.gd:58-62`) does **not** read those
fields — it only ever surfaces `tcp_port` and `video_port`. The
`telemetry_port` and `pose_udp_port` therefore have no effect on
which ports the headset connects to today; they are advisory only.
Resolving this requires the XR client to honor those fields or
discover them from the DeviceDescriptor (recommended path: keep
discovery minimal, let the descriptor be the source of truth).

mDNS service `_xrobo._tcp.local.` is also registered
(`robot/src/network/discovery.rs:22`) but the GDScript client does
not consume it — only the UDP beacon is consumed.

---

## Channel 2 — Command channel (TCP 63901)

* **Port + protocol:** TCP, default 63901.
* **Direction:** Bidirectional after the XR client `connect`s.
* **NODELAY:** Both ends set `TCP_NODELAY` immediately on connect to
  prevent 40 ms Nagle batches from poisoning latency.
  See `robot/src/network/pose_server.rs:36` and
  `xr/scripts/network/tcp_handler.gd:141`.
* **Codec:** `CommandCodec`, length-prefixed UTF-8 + opaque payload.

### Frame layout — `CommandFrame`

All length fields are **little-endian signed i32**.

```
+0  +1  +2  +3
+---+---+---+---+
|    cmd_len    |  LE i32  (signed; max 64 KiB)
+---+---+---+---+
| cmd UTF-8 ... |  cmd_len bytes  (no null terminator)
+---+---+---+---+
|    data_len   |  LE i32  (signed; max 16 MiB)
+---+---+---+---+
| data ...      |  data_len bytes  (opaque; almost always UTF-8 JSON)
+---+---+---+---+
```

* `cmd_len` and `data_len` are signed for legacy reasons. Negative
  values are rejected.
  See `robot/src/network/protocol.rs:53-95`.
* The codec is a streaming decoder: partial frames return `Ok(None)`
  and ask the buffer to reserve more bytes
  (`robot/src/network/protocol.rs:84`).

### Implementations

* **Rust:** `robot/src/network/protocol.rs:42` (`CommandCodec`).
* **GDScript:** `xr/scripts/network/protocol.gd:57`
  (`encode_command`), `xr/scripts/network/protocol.gd:86`
  (`decode_command`).
* **Python:** `tools/mac_mock_streamer.py:67-94`.

### Commands carried on this channel

| Command name       | Direction      | Payload type | Section |
|--------------------|----------------|--------------|---------|
| `Hello`            | XR → robot     | JSON         | §2.1 |
| `DeviceDescriptor` | robot → XR     | JSON         | §2.1 |
| `Tracking`         | XR → robot     | JSON (legacy) | §2.2 |
| `DeviceCommand`    | XR → robot     | JSON         | §2.3 |
| `Telemetry`        | robot → XR     | JSON         | §2.4 |
| `ClockPing`        | XR → robot     | JSON (compact) | §2.5 |
| `ClockPong`        | robot → XR     | JSON (compact) | §2.5 |
| `Heartbeat`        | XR → robot     | (empty)      | logged only, no action |
| `VideoFrame`       | robot → XR     | raw NAL      | §6 (TCP video — unused in practice) |

### Cadence / timing

* `Hello` is sent once on connect.
* The robot must respond to `Hello` with `DeviceDescriptor` within
  3 s — beyond that the XR client falls back to legacy "Tracking"
  mode (`xr/scripts/network/session.gd:18`,
  `xr/scripts/network/session.gd:54-60`).
* `Heartbeat` is currently not emitted but is recognised
  (`robot/src/network/pose_server.rs:182`).
* `Telemetry` is pushed at 10 Hz
  (`robot/src/network/pose_server.rs:142`).
* `ClockPing` is emitted by the XR side at 1 Hz
  (`xr/scripts/network/clock_sync.gd:23`).
* `DeviceCommand` is emitted by the XR side at up to ~72 Hz
  (`xr/scripts/input/command_sender.gd:11`).

### Failure modes

* Decode error → connection torn down. Rust:
  `robot/src/network/pose_server.rs:229`. GDScript:
  `xr/scripts/network/tcp_handler.gd:240`.
* Receive-buffer cap exceeded (10 MiB default) → GDScript clears
  the buffer and disconnects
  (`xr/scripts/network/tcp_handler.gd:211`). The video TCP handler
  raises the cap to 32 MiB (`xr/scenes/main.gd:115`).
* Pico `StreamPeerTCP` sometimes reports `STATUS_NONE` for a single
  tick after first `put_data`. The XR side tolerates up to 5
  consecutive bad ticks before declaring the socket dead
  (`xr/scripts/network/tcp_handler.gd:67-68`).

### §2.1 Hello → DeviceDescriptor

`Hello` body (XR → robot), JSON:

```json
{ "version": "2.0", "client": "godot", "capabilities": ["hand_tracking", "controller"] }
```

(`xr/scripts/network/session.gd:26`). The robot ignores the body
contents and only checks `frame.command == "Hello"`
(`robot/src/network/pose_server.rs:84`).

`DeviceDescriptor` body (robot → XR), JSON. Authoritative schema is
the `DeviceDescriptor` struct in
`robot/src/device/traits.rs:18-35`. Every field below is documented
with its serde rename and default.

```json
{
  "device": {
    "type":     "robot_arm",       // serde rename "type" (Rust field: device_type) — traits.rs:41
    "name":     "SO-101",
    "icon":     "",                 // default ""
    "model_url": ""                 // default ""
  },
  "control_schema": {
    "axes":    [ { "name": "gripper", "display": "Gripper", "range": [-1.0, 1.0], "default": 0.0, "dead_zone": 0.05 } ],
    "buttons": [ { "name": "horn",    "display": "Horn",    "toggle": false, "group": null, "confirm": false } ],
    "poses":   [ { "name": "end_effector", "display": "EE",  "dof": 6,        "frame": "right_hand" } ]
  },
  "input_mapping": [
    { "source": "right_trigger", "target": "gripper", "scale": 1.0, "invert": false, "offset": 0.0, "mode": "absolute" }
  ],
  "telemetry_schema": {
    "values": [
      { "name": "battery_v", "display": "Battery", "unit": "V",
        "range": [10.0, 12.6], "warn_below": 10.5, "type": "float", "length": null }
    ]
  },
  "video_feeds": [
    { "name": "main", "display": "Front", "port": 12345,
      "width": 1280, "height": 720, "fps": 30, "stereo": false,
      "transport": "udp",      // "tcp" | "udp" | "auto"; default "tcp"
      "udp_port": 12345 }
  ],
  "safety": {
    "disconnect_action": "stop",   // "stop" | "hold" | "return_home"; default "stop"
    "command_timeout_ms": 500,
    "limits": { "gripper": [-1.0, 1.0] }
  }
}
```

Serde renames / defaults to be aware of:

* `DeviceInfo.device_type` ↔ JSON `"type"`
  (`robot/src/device/traits.rs:41`).
* `AxisDef.range` defaults to `(-1.0, 1.0)`
  (`robot/src/device/traits.rs:77`,
  `robot/src/device/traits.rs:87`).
* `PoseDef.dof` defaults to 6
  (`robot/src/device/traits.rs:119`,
  `robot/src/device/traits.rs:125`).
* `InputMapping.scale` defaults to 1.0
  (`robot/src/device/traits.rs:138`,
  `robot/src/device/traits.rs:150`).
* `TelemetryValueDef.value_type` ↔ JSON `"type"`
  (`robot/src/device/traits.rs:180`).
* `VideoFeedInfo.transport` defaults to `"tcp"`
  (`robot/src/device/traits.rs:215`,
  `robot/src/device/traits.rs:226`).
* `VideoFeedInfo.udp_port` defaults to 0 — meaning "no UDP feed"
  (`robot/src/device/traits.rs:222`).
* `DeviceSafetyConfig.disconnect_action` defaults to `"stop"`
  (`robot/src/device/traits.rs:244`,
  `robot/src/device/traits.rs:254`).

XR-side decoder: `xr/scripts/network/session.gd:34-44` parses the
JSON into a `Dictionary` and emits `device_connected`. The
`_select_video_transport` heuristic at
`xr/scenes/main.gd:381-388` is the contract for the
`transport` / `udp_port` fields:

* `transport == "udp"` AND `udp_port > 0` → UDP.
* `transport == "auto"` AND `udp_port > 0` → UDP.
* Otherwise → TCP.

### §2.2 Tracking (legacy v1)

JSON body emitted by `xr/scripts/network/pose_sender.gd:34-50` when
no descriptor is in scope. Shape (must match the C# serialiser
exactly):

```json
{
  "Head": { "pose": "x,y,z,qx,qy,qz,qw" },
  "Controller": {
    "left":  { "pose": "...", "trigger": 0.0, "triggerClick": 0.0, "grip": 0.0, ... },
    "right": { "pose": "...", ... }
  },
  "Hand": {
    "leftHand":  [ { "pose": "...", "radius": 0.01 }, ... ],
    "rightHand": [ ... ]
  },
  "timeStampNs": 123456789
}
```

Floats are formatted with `%.6f`
(`xr/scripts/network/pose_sender.gd:144-146`).

The Rust side converts this to the generic `DeviceCommand` via
`robot/src/network/session.rs:27-79`
(`headset_pose_to_device_command`). This is a v1 → v2 adapter and is
fully deprecated for new robots — emit `DeviceCommand` instead.

### §2.3 DeviceCommand

JSON body emitted by `xr/scripts/input/command_sender.gd:29-31`.
Authoritative shape in `robot/src/device/command.rs:17-30`:

```json
{
  "axes":    { "throttle": 0.75, "gripper": 0.0 },
  "buttons": { "horn": false, "headlight": true },
  "poses":   {
    "end_effector": { "position": [0.1, -0.2, 1.0], "rotation": [0.0, 0.0, 0.7071, 0.7071] }
  },
  "timestamp_ns": 1234567890123456789
}
```

* All four fields are `#[serde(default)]` — an empty object `{}` is
  valid.
* `Pose6D.rotation` is a quaternion in `[qx, qy, qz, qw]` order
  (`robot/src/device/command.rs:60`).
* `timestamp_ns` is XR-side wall clock; the Rust side passes it to
  the latency aggregator and (via `LatencyRecorder::set_clock_offset`,
  see §2.5) corrects it to robot clock.

Rust decoder: `robot/src/network/pose_server.rs:164-181`
(`DeviceCommand` arm in `handle_connection`). On every accept, the
server stamps a new internal `seq` and pushes a `TimedCommand`
(`DeviceCommand` + `seq` + `t_rx_ns`) into a
`watch::Sender<Option<TimedCommand>>` using `send_replace`. That is
the **drop-old** semantics on this TCP channel: any unread
previous value is overwritten, preventing head-of-line blocking on
a slow driver.

### §2.4 Telemetry

JSON body pushed by the robot at 10 Hz. Authoritative shape in
`robot/src/device/command.rs:65-82`:

```json
{
  "values": {
    "battery_v":  12.4,
    "errors":     0,
    "homed":      true,
    "mode":       "manual",
    "joint_q":    [0.0, 1.5, 0.5, 0.0, 0.0, 0.5]
  },
  "timestamp_ns": 1234567890123456789
}
```

`TelemetryValue` is `#[serde(untagged)]` so values are emitted as
bare JSON primitives (number / bool / string / array of f64). The XR
side parses with `JSON.parse_string`
(`xr/scripts/network/session.gd:47`) into a `Dictionary`.

### §2.5 ClockPing / ClockPong

Clock sync is **piggybacked on the command channel** specifically so
it shares the same TCP path as `DeviceCommand` and the offset
estimate reflects the same network conditions.

XR sends `ClockPing` every 1 s with payload
(`xr/scripts/network/clock_sync.gd:130-133`):

```
{"t_xr_send":1234567890123456789}
```

Note: **compact JSON, no spaces around colon**. The Rust side's
parser hand-rolls a needle search for `"t_xr_send":` (no space)
(`robot/src/network/pose_server.rs:265`). The XR side has the
mirror parser (`xr/scripts/network/clock_sync.gd:144-160`). Python
implementations must use `json.dumps(..., separators=(",", ":"))`
— the SOP calls this out explicitly
(`claw/sop/add-new-video-source.md:150-152`,
`tools/mac_mock_streamer.py:284-293`).

Robot replies immediately with `ClockPong` payload
(`robot/src/network/pose_server.rs:212-215`):

```
{"t_xr_send":1234567890123456789,"t_robot_recv":1234567890124456789,"t_robot_send":1234567890124457789}
```

All timestamps are **unix-epoch nanoseconds**, NOT a monotonic
clock. The Rust side uses `SystemTime::now().duration_since(UNIX_EPOCH)`
(`robot/src/network/pose_server.rs:246-252`). The XR side uses
`VideoLatencyTracker.now_ns()` calibrated to the same epoch
(`xr/scripts/network/clock_sync.gd:140`). Monotonic clocks would
make the offset bear no relation to the headset's epoch and the
HUD `net` reading would be meaningless.

The XR side computes:

```
offset_ns = ((t_robot_recv - t_xr_send) + (t_robot_send - t_xr_recv)) / 2
rtt_ns   = (t_xr_recv  - t_xr_send) - (t_robot_send - t_robot_recv)
```

(`xr/scripts/network/clock_sync.gd:85-101`). The offset is
EWMA-smoothed with `alpha = 0.3`
(`xr/scripts/network/clock_sync.gd:24`); samples whose RTT is
> 3× the median of the last 5 RTTs are rejected
(`xr/scripts/network/clock_sync.gd:97-99`).

Robot-side one-sided estimate
(`offset ≈ t_xr_send − t_robot_recv`) is also fed into the
latency aggregator immediately
(`robot/src/network/pose_server.rs:209-211`).

---

## Channel 3 — Pose UDP data plane (UDP 63902)

* **Port + protocol:** UDP 63902.
* **Direction:** XR → robot, unicast.
* **Encoder:** `xr/scripts/network/pose_sender.gd` (only the legacy
  TCP path is wired in the current GDScript build; the UDP encoder
  on the XR side is **TBD** — see Inconsistencies below).
  Rust side decodes at `robot/src/network/pose_udp_server.rs:86`.

### Packet layout — 32 B header + payload

All header fields are **little-endian**.

```
Offset  Size  Field                Notes
+0      8     t_xr_send_ns         LE u64  — XR wall clock at send (unix-epoch ns)
+8      8     seq                  LE u64  — monotonic per XR session, starts at 1
+16     4     session_token        LE u32  — 0 = anonymous; else must match TCP-side token
+20     2     descriptor_version   LE u16  — 0 = unknown / not enforced
+22     2     payload_len          LE u16  — payload byte count (after header)
+24     2     crc16                LE u16  — CRC-16/CCITT-FALSE over payload bytes
+26     1     flags                u8      — bit0 = keyframe, bit1 = hold_request
+27     1     reserved             u8      — must be 0
+28     4     payload_kind         4 ASCII bytes — "POSE", future "AXIS"/"BUTN", etc.
+32     ...   payload              payload_len bytes
```

ASCII visualisation of the fixed header:

```
  0                   1                   2                   3
  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 +---------------+---------------+---------------+---------------+
 |                       t_xr_send_ns                            | LE u64
 |                       t_xr_send_ns (cont.)                    |
 +---------------+---------------+---------------+---------------+
 |                            seq                                | LE u64
 |                            seq (cont.)                        |
 +---------------+---------------+---------------+---------------+
 |                       session_token                           | LE u32
 +---------------+---------------+---------------+---------------+
 |  descriptor_version (LE u16)  |    payload_len (LE u16)       |
 +---------------+---------------+---------------+---------------+
 |     crc16 (LE u16)            | flags (u8)    | reserved (u8) |
 +---------------+---------------+---------------+---------------+
 |   'P'         |   'O'         |   'S'         |   'E'         |
 +---------------+---------------+---------------+---------------+
 |                        payload (variable)                     |
 +---------------+---------------+---------------+---------------+
```

(See `robot/src/network/protocol.rs:289-304` for the canonical
header table.)

### Payload — kind `"POSE"`

64 bytes, **little-endian** f64 throughout:

```
+0   8  position[0]   LE f64
+8   8  position[1]   LE f64
+16  8  position[2]   LE f64
+24  8  rotation[0] = qx  LE f64
+32  8  rotation[1] = qy  LE f64
+40  8  rotation[2] = qz  LE f64
+48  8  rotation[3] = qw  LE f64
+56  8  gripper            LE f64
```

(`robot/src/network/protocol.rs:309`,
`robot/src/network/protocol.rs:387-403`,
`robot/src/network/protocol.rs:443-462`.)

### CRC

CRC-16/CCITT-FALSE: poly `0x1021`, init `0xFFFF`, no reflection,
xorout 0. Implementation:
`robot/src/network/protocol.rs:343-356`. Test vector:
`crc16_ccitt("123456789") == 0x29B1`
(`robot/src/network/protocol.rs:606-609`).

### Server-side drop policies

In order, per packet (`robot/src/network/pose_udp_server.rs:86-133`):

1. **CRC mismatch** → drop silently, increment
   `stats.crc_drop_count` (line 89).
2. **Session token** — if the TCP-side handshake stamped a non-zero
   token into the shared `AtomicU32` and the packet carries a
   non-zero `session_token` that doesn't match → drop, increment
   `stats.token_drop_count` (line 106-109). A packet `session_token
   == 0` is "anonymous" and always accepted.
3. **Drop-old by seq** — if `pkt.seq <= last_applied_seq` for this
   session → drop, increment `stats.stale_drop_count` (line
   112-115). Otherwise update `last_applied_seq = pkt.seq`.

On accepted packets the server emits a `TimedCommand` preserving
`pkt.seq` end-to-end, so the latency aggregator sees the same seq
the XR side stamped (line 127-133). This is **different from the
TCP path**, which mints a fresh seq via `record_rx`. The pose-UDP
path deliberately reuses the on-wire seq because the drop-old logic
needs the same numbering.

### Session-token reset

The server reads `current_session_token` on every packet. If it
changed since the last packet, the server treats it as a new
session and resets `last_applied_seq` to 0
(`robot/src/network/pose_udp_server.rs:100-105`). This prevents a
new TCP handshake from getting its seq=1 immediately rejected as
stale.

### Cadence

XR sends at up to 72 Hz today (mirrors the command channel rate;
`xr/scripts/network/pose_sender.gd:29`). The server has no rate
ceiling — it processes whatever it receives.

### Failure modes

* Datagram too short (< 32 B) → `PoseUdpDecodeError::TooShort`,
  logged once
  (`robot/src/network/pose_udp_server.rs:92-95`).
* Wrong `kind` → `PoseUdpDecodeError::UnknownKind`. Only `"POSE"` is
  currently registered (`robot/src/network/protocol.rs:463`).
* Wrong `payload_len` for kind → `PoseUdpDecodeError::PayloadLenMismatch`.
* CRC failure → silent drop, counter increment.
* Packet smaller than `header + payload_len` (truncated payload) →
  `PoseUdpDecodeError::TooShort`
  (`robot/src/network/protocol.rs:427-432`).

### Implementations

* **Rust encode + decode:** `robot/src/network/protocol.rs:378-475`.
* **Rust server:** `robot/src/network/pose_udp_server.rs`.
* **GDScript:** not wired in the current build — see Inconsistencies.
* **Python reference:** not implemented in `tools/mac_mock_streamer.py`
  (the mock streamer is video-only).

### Inconsistencies

The XR-side encoder for this packet is **not present** in the
GDScript code paths read. `xr/scripts/network/pose_sender.gd` only
sends `"Tracking"` over the command TCP channel; pose data does
not yet flow over UDP from the headset. The server is built and
ready (`robot/src/network/pose_udp_server.rs`) and the Rust codec
has full encode + decode tests, but no GDScript caller yet exists
for `PoseUdpPacket::encode`. **Trust the Rust struct.** When the
GDScript side is wired, it must match
`robot/src/network/protocol.rs:378-406` byte-for-byte (the test
`pose_udp_pose_roundtrip` at line 612 is the conformance check).

---

## Channel 4 — Telemetry (TCP 63903 — dedicated)

* **Port + protocol:** TCP 63903, dedicated channel.
* **Direction:** robot → XR, push.
* **Cadence:** 10 Hz (`robot/src/network/telemetry_server.rs:29`).
* **Wire format:** identical to the command channel — `CommandFrame`
  with `command == "Telemetry"` and a JSON body
  (`robot/src/network/telemetry_server.rs:67-74`). Only the socket
  address differs from the legacy pose-channel telemetry.

The reason for the split is socket-buffer isolation: under load,
10 Hz telemetry pushes used to contend with 72 Hz command frames
for the same outbound TCP buffer on port 63901, amplifying jitter
on the hot path
(`robot/src/network/telemetry_server.rs:8-13`).

### Failure modes

* Subscriber socket broken → `framed.send` returns `Err` and the
  per-subscriber spawn exits
  (`robot/src/network/telemetry_server.rs:73`). The server keeps
  running; other subscribers are unaffected.
* Multiple subscribers are supported — each gets its own
  `watch::Receiver<DeviceTelemetry>` clone
  (`robot/src/network/telemetry_server.rs:43`).

### Implementations

* **Rust:** `robot/src/network/telemetry_server.rs`.
* **GDScript:** **not yet wired**. The XR side currently consumes
  `"Telemetry"` only on the legacy pose channel
  (`xr/scripts/network/session.gd:45-50`).

### Inconsistencies

The XR client has no consumer for port 63903 in the read code.
Until the headset cuts over, the robot continues to emit telemetry
on the command channel (port 63901) via
`robot/src/network/pose_server.rs:141-158`. Both emitters run
simultaneously today; this is intentional backward compat
(`robot/src/network/telemetry_server.rs:14-17`). New
implementations should subscribe on 63903 and ignore the legacy
push on 63901.

---

## Channel 5 — Video TCP (TCP 12345)

* **Port + protocol:** TCP, default 12345.
* **Direction:** robot → XR.
* **NODELAY:** set on accept
  (`robot/src/video/pipeline.rs:373`).

### Wire format — TimedVideoFrame (80 B header + NAL)

All fields are **big-endian**.

```
Offset  Size  Field                Notes
+0      8     frame_id             BE u64  — monotonic per-stream
+8      4     nal_index            BE u32  — NAL index within frame
+12     4     nal_count            BE u32  — total NALs in this frame
+16     4     pipeline_mode        BE u32  — 0 = V4L2 HW, 1 = ffmpeg/SW
+20     8     capture_start_ns     BE u64  — unix-epoch ns (or 0 if FFmpeg path)
+28     8     capture_end_ns       BE u64
+36     8     encode_start_ns      BE u64
+44     8     encode_end_ns        BE u64
+52     8     read_wait_ns         BE u64  — FFmpeg-side stdout wait
+60     8     parse_ns             BE u64  — FFmpeg-side NAL split time
+68     8     send_ns              BE u64  — stamped at socket write; drives HUD `net`
+76     4     nal_len              BE u32  — length of NAL payload that follows
+80     ...   nal                  Annex-B H.264 NAL (incl. 0x00 0x00 0x00 0x01 if encoder emitted one)
```

ASCII visualisation:

```
  0                   1                   2                   3
  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 +---------------+---------------+---------------+---------------+
 |                         frame_id                              | BE u64
 |                         frame_id (cont.)                      |
 +---------------+---------------+---------------+---------------+
 |       nal_index (BE u32)      |     nal_count (BE u32)        |
 +---------------+---------------+---------------+---------------+
 |    pipeline_mode (BE u32)     |   capture_start_ns hi 32 bits |
 |     ... low 32 bits           |    capture_end_ns hi          |
 |     ... low                   |    encode_start_ns hi         |
 |     ... low                   |    encode_end_ns hi           |
 |     ... low                   |    read_wait_ns hi            |
 |     ... low                   |    parse_ns hi                |
 |     ... low                   |    send_ns hi                 |
 |     ... low                   |    nal_len (BE u32)           |
 +---------------+---------------+---------------+---------------+
 |                        NAL payload (nal_len bytes)            |
 +---------------+---------------+---------------+---------------+
```

(`robot/src/network/protocol.rs:11-18` — header doc-comment.
Encoder: `robot/src/network/protocol.rs:266-282`. Decoder:
`robot/src/network/protocol.rs:213-260`.)

### Cadence

One frame at the configured FPS (typically 30 Hz). Multiple
NALs per frame share `frame_id` and are distinguished by
`nal_index` (0 .. `nal_count - 1`).

### Failure modes

* Truncated header (< 80 B) → decoder returns `Ok(None)` and asks
  for more (`robot/src/network/protocol.rs:214-216`). Streaming
  decoder behavior.
* `nal_len > MAX_NAL_SIZE` (10 MiB) → connection dropped with
  `InvalidData` (`robot/src/network/protocol.rs:231-236`).
* GDScript side: `nal_len > 10_000_000` → returns
  `{"error": ...}`, the receive buffer is cleared and parsing
  halts for this tick
  (`xr/scripts/network/protocol.gd:201-202`,
  `xr/scripts/network/tcp_handler.gd:272`).
* Video-TCP receive buffer overflow (32 MiB cap) → disconnect
  (`xr/scenes/main.gd:115`,
  `xr/scripts/network/tcp_handler.gd:211`).
* Slow consumer: each TCP client is a `broadcast::subscribe`. If
  it falls 128 frames behind it gets `RecvError::Lagged(n)` and
  `n` frames are skipped
  (`robot/src/video/pipeline.rs:388-390`).

### Implementations

* **Rust encoder:** `robot/src/network/protocol.rs:266`
  (`TimedVideoFrameCodec::encode`). Wired via
  `robot/src/video/pipeline.rs:379-394`.
* **GDScript decoder:** `xr/scripts/network/protocol.gd:182`
  (`decode_timed_video_frame`). Wired via
  `xr/scripts/network/tcp_handler.gd:262-279`.

### Inconsistencies

The protocol module also defines a `VideoFrameCodec`
(`robot/src/network/protocol.rs:119`) for the **legacy raw NAL**
format `[4B nal_len BE][nal payload]`. This is documented in code
as "Compatible with ffplay preview" but is **not wired** into the
live pipeline today — `serve_video_clients` in
`robot/src/video/pipeline.rs:379` uses `TimedVideoFrameCodec`
unconditionally. The GDScript side mirrors this: it emits a
`"VideoFrame"` command-frame dispatch
(`xr/scripts/network/tcp_handler.gd:252-257`) but no code path
delivers raw `VideoFrame` frames over the command channel.

**Trust the timed format.** The raw-NAL `VideoFrameCodec` is
dead code kept for a hypothetical `ffplay` preview tool that
hasn't been built; treat the legacy raw-NAL path as
**non-existent on the wire** until someone explicitly wires it.

---

## Channel 6 — Video UDP (UDP 12345)

* **Port + protocol:** UDP 12345 (same number as the TCP video
  port by convention).
* **Direction:** XR → robot to register; then robot → XR (unicast)
  for every NAL fragment.
* **Registration:** XR sends a single ASCII `"Hello"` datagram
  every 5 s (`xr/scripts/network/udp_video_handler.gd:36`); the
  robot remembers `(sender_ip, sender_port)` and adds it to a
  recipient set (`robot/src/video/pipeline.rs:130-135`).

### Datagram layout — 18 B fragment header + 80 B timed header + ≤1200 B NAL slice

All fields are **big-endian** unless noted.

```
Offset  Size  Field                Notes
== Fragment sub-header (18 bytes) ==
+0      4     magic                ASCII "NLFR" = {0x4E, 0x4C, 0x46, 0x52}
+4      1     version              u8, currently 1
+5      1     flags                u8 — bit0 = LAST fragment, bit1 = FIRST fragment
+6      2     fragment_index       BE u16, 0-based
+8      2     fragment_count       BE u16, total fragments for this NAL
+10     8     frame_id             BE u64  (mirrors the embedded timed header)
== Embedded TimedVideoFrame header (80 bytes, same layout as TCP) ==
+18     8     frame_id             BE u64
+26     4     nal_index            BE u32
+30     4     nal_count            BE u32
+34     4     pipeline_mode        BE u32
+38     8     capture_start_ns     BE u64
+46     8     capture_end_ns       BE u64
+54     8     encode_start_ns      BE u64
+62     8     encode_end_ns        BE u64
+70     8     read_wait_ns         BE u64
+78     8     parse_ns             BE u64
+86     8     send_ns              BE u64
+94     4     nal_len              BE u32  — **TOTAL** NAL byte count (not this fragment's slice)
== Payload ==
+98     ≤1200 fragment payload     this fragment's slice of the NAL
```

ASCII visualisation of the fragment sub-header:

```
 +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
 |  'N'  |  'L'  |  'F'  |  'R'  | ver=1 | flags |   frag_idx    |
 +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
 |   frag_count  |                  frame_id (BE u64)            |
 +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
 |             ... frame_id continues ...                        |
 +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
```

(Rust producer: `robot/src/video/pipeline.rs:587-614`. GDScript
parser: `xr/scripts/network/protocol.gd:268-317`. Python:
`tools/mac_mock_streamer.py:99-146`.)

### Flags

```
bit 0 (0x01)  UDP_FRAGMENT_FLAG_LAST   set on the final fragment of a NAL
bit 1 (0x02)  UDP_FRAGMENT_FLAG_FIRST  set on fragment_index == 0
```

(`robot/src/video/pipeline.rs:598-604`,
`xr/scripts/network/protocol.gd:50-51`.)

A NAL that fits in one fragment carries **both** FIRST and LAST,
fragment_index = 0, fragment_count = 1
(`robot/src/video/pipeline.rs:654-668` test).

### Reassembly rules (XR side)

`xr/scripts/network/udp_video_handler.gd:116-172`:

1. Receiver maintains a reassembler map keyed by
   `"frame_id:nal_index"`.
2. First fragment creates the entry with a fixed-size
   `fragments` array sized to `fragment_count`.
3. Each subsequent fragment is dropped into its index slot.
4. When `received_count == fragment_count`, concatenate the
   slices in index order and emit `video_frame_received`.
5. Duplicate fragments (same index, already received) are
   silently ignored — common with Wi-Fi L2 retransmits.
6. **Backpressure cap:** `REASSEMBLY_MAX = 16` in-flight
   reassembly entries
   (`xr/scripts/network/udp_video_handler.gd:63`). When full,
   the oldest partial NAL is evicted
   (`xr/scripts/network/udp_video_handler.gd:124`).
7. **TTL:** any partial reassembly older than
   `REASSEMBLY_TTL_NS = 200_000_000` (200 ms) is evicted
   (`xr/scripts/network/udp_video_handler.gd:68`,
   `xr/scripts/network/udp_video_handler.gd:225-236`).
8. Drops counted via `get_drop_count()` for the HUD.

### Failure modes

* Dropped fragment → its parent NAL is dropped after 200 ms TTL.
  Decoder recovers at the next IDR (GOP = 0.5 s).
* Length mismatch between concatenated fragment bytes and
  `nal_total_len` → entry erased, frame dropped
  (`xr/scripts/network/udp_video_handler.gd:188-192`).
* `fragment_count > u16::MAX` → producer drops the whole NAL
  (`robot/src/video/pipeline.rs:578-585`). With the 1200 B
  fragment payload this means NALs > ~78 MiB get dropped, which
  exceeds `MAX_NAL_SIZE` anyway.
* Wrong magic → GDScript treats the datagram as a legacy
  unfragmented `TimedVideoFrame` and tries
  `decode_timed_video_frame` on the raw bytes
  (`xr/scripts/network/udp_video_handler.gd:96-111`). This
  preserves compatibility with hypothetical older robot builds
  that emitted single-datagram NALs.
* Unsupported version → `{"error": "unsupported UDP fragment version: N"}`
  (`xr/scripts/network/protocol.gd:277`).

### Access-unit bundling (encoder-side)

The encoder must emit one *complete H.264 access unit* per
`frame_id`. Specifically: SPS / PPS / SEI NALs must be bundled
together with the first slice NAL (type 1 = non-IDR, type 5 = IDR)
in a single Annex-B byte buffer, start codes preserved between
NALs. The Adreno MediaCodec on Pico cannot extract `csd-0` /
`csd-1` from a bare SPS access unit and will stall forever. See
`tools/mac_mock_streamer.py:381-413` for the reference bundling
loop and `claw/sop/add-new-video-source.md:208-221` for the
explanation.

### Implementations

* **Rust producer:** `robot/src/video/pipeline.rs:557-616`
  (`build_udp_fragments`), `robot/src/video/pipeline.rs:112-163`
  (`serve_udp_broadcast`).
* **GDScript consumer:** `xr/scripts/network/protocol.gd:268`
  (`decode_udp_fragment`),
  `xr/scripts/network/udp_video_handler.gd` (whole file).
* **Python producer:** `tools/mac_mock_streamer.py:99-146`.

### Inconsistencies

The GDScript fragment parser computes `UDP_FRAGMENT_HEADER_SIZE`
as `4 + 1 + 1 + 2 + 2 + 8 = 18`
(`xr/scripts/network/protocol.gd:41`). The Rust constant evaluates
to the same number
(`robot/src/video/pipeline.rs:58`). The Python reference hard-codes
`18` (`tools/mac_mock_streamer.py:50`). All three agree.

The Rust source has a comment at
`robot/src/video/pipeline.rs:54` stating "Size of the fragment
sub-header" with layout `[4B magic][1B version][1B flags][2B
idx][2B count][8B frame_id]`. The narrative wire-protocol
documentation at the top of `protocol.rs` and the
`add-new-video-source.md` SOP both say **18 bytes**. Treat
18 as canonical.

---

## Reference: end-to-end packet flow

```
discovery: robot -- UDP 63900 broadcast (3s) ----------------------> XR
                                                                     |
handshake: XR -- TCP 63901 connect ----------------------------------> robot
           XR -- Hello (CommandFrame, JSON) ---------------------> robot
           XR <-- DeviceDescriptor (CommandFrame, JSON) ----------- robot
                                                                     |
clock:     XR -- ClockPing (CommandFrame, compact JSON, 1Hz) ------> robot
           XR <-- ClockPong (CommandFrame, compact JSON) ----------- robot
                                                                     |
control:   XR -- DeviceCommand (CommandFrame, JSON, ~72Hz) --------> robot   [TCP path; drop-old via send_replace]
           XR -- PoseUdpPacket (32B+payload, ~72Hz) ---------------> robot   [UDP path; drop-old by seq; TBD on XR side]
                                                                     |
telemetry: XR <-- Telemetry (CommandFrame, JSON, 10Hz) ------------- robot   [legacy on 63901]
           XR <-- Telemetry (CommandFrame, JSON, 10Hz) ------------- robot   [dedicated on 63903; XR consumer TBD]
                                                                     |
video:     XR -- "Hello" datagram (UDP 12345) ---------------------> robot   [registers recipient]
           XR <-- NLFR-fragmented NAL datagrams (UDP 12345) --------- robot
                                                                              [or, alternatively, TCP 12345:]
           XR -- TCP connect ---------------------------------------> robot
           XR <-- TimedVideoFrame stream (TCP 12345) ---------------- robot
```

---

## Summary of inter-implementation discrepancies

| # | Discrepancy | What to trust |
|---|-------------|----------------|
| 1 | Discovery beacon advertises `pose_udp_port` and `telemetry_port`; XR client ignores them. | Rust beacon is forward-looking. XR side should be patched. |
| 2 | mDNS is registered on the robot side but XR client only listens to UDP broadcast. | UDP broadcast is the only working discovery surface today. |
| 3 | `PoseUdpPacket` is fully implemented in Rust (server + codec) but the XR client has no encoder for it — `pose_sender.gd` still uses TCP `"Tracking"`. | Rust struct is canonical for byte layout. XR side is a planned addition. |
| 4 | Dedicated telemetry server runs on TCP 63903 but the XR client only handles `"Telemetry"` on the legacy command channel (63901). | Robot emits on both; XR cuts over later. |
| 5 | `VideoFrameCodec` (raw `[4B len BE][NAL]`) and the `"VideoFrame"` command-frame dispatch in the XR client both exist but are not wired in the live pipeline. | Treat as dead code. Only `TimedVideoFrameCodec` is on the wire today. |
| 6 | `claw/sop/add-new-video-source.md:204` documents `REASSEMBLY_MAX = 64`. The GDScript code uses `REASSEMBLY_MAX = 16` (`xr/scripts/network/udp_video_handler.gd:63`). | Code wins (16). SOP is stale by ~4×. |

---

## Where to look in code (quick index)

### Rust (robot side)

| Surface | File |
|---------|------|
| Command codec | `robot/src/network/protocol.rs:42-110` |
| Video TCP codec | `robot/src/network/protocol.rs:204-283` |
| Pose UDP codec | `robot/src/network/protocol.rs:307-475` |
| CRC-16/CCITT | `robot/src/network/protocol.rs:343-356` |
| Discovery sender | `robot/src/network/discovery.rs` |
| Command server (TCP 63901) | `robot/src/network/pose_server.rs` |
| Pose UDP server (63902) | `robot/src/network/pose_udp_server.rs` |
| Telemetry server (63903) | `robot/src/network/telemetry_server.rs` |
| Video pipeline + UDP fan-out (12345) | `robot/src/video/pipeline.rs` |
| Hello → DeviceDescriptor builder | `robot/src/network/session.rs:16-22` |
| DeviceDescriptor schema | `robot/src/device/traits.rs:17-225` |
| DeviceCommand / Telemetry schema | `robot/src/device/command.rs` |
| ClockPing parser + ClockPong builder | `robot/src/network/pose_server.rs:186-225` |
| Port defaults | `robot/src/config.rs:38-110` |

### GDScript (XR side)

| Surface | File |
|---------|------|
| Protocol encode/decode helpers | `xr/scripts/network/protocol.gd` |
| TCP handler (command + video TCP) | `xr/scripts/network/tcp_handler.gd` |
| UDP video receiver + reassembler | `xr/scripts/network/udp_video_handler.gd` |
| Discovery listener | `xr/scripts/network/discovery.gd` |
| Hello / Descriptor / legacy Telemetry | `xr/scripts/network/session.gd` |
| Clock sync (Ping/Pong handler) | `xr/scripts/network/clock_sync.gd` |
| Legacy `"Tracking"` sender | `xr/scripts/network/pose_sender.gd` |
| `DeviceCommand` sender | `xr/scripts/input/command_sender.gd` |
| Transport selection | `xr/scenes/main.gd:381-388` |

### Python reference

Single file: `tools/mac_mock_streamer.py`. Exercises discovery
(63900), TCP handshake + ClockPong (63901), UDP video registration
+ NLFR-fragmented streaming (12345). Does **not** exercise
DeviceCommand consumption, pose UDP (63902), or dedicated
telemetry (63903) — these are not needed for a video-only mock.
