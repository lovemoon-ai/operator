# SOP: add a new video source for the XR client

Standard operating procedure for getting H.264 video from any source —
a real robot, a Mac webcam, an IP camera, an RTSP relay — onto the
Pico/Quest headset's `RobotView` display.

This is the contract you must implement to be a valid "robot" on the
network. The XR client doesn't care what's behind the wire, it only
cares about the wire format.

## Reference implementations

* `tools/mac_mock_streamer.py` — minimal pure-Python streamer that
  exercises every required protocol surface. Read it first, then
  diverge.
* `robot/src/network/discovery.rs`, `robot/src/network/protocol.rs`,
  `robot/src/video/pipeline.rs` — the production Rust agent. Same
  wire format, hardware encode.

## Topology

* The robot/source and the headset must be on the **same Layer-2
  subnet**. Discovery is UDP broadcast — corporate Wi-Fi often blocks
  inter-AP broadcasts; if you see "Bad ClockPong" but no `Robot found`,
  send the discovery JSON as a unicast to the headset's IP as a
  fallback (see `mac_mock_streamer.py --pico` for the pattern).
* No NAT, no internet hop. The headset's `RobotClockSync` assumes RTT
  is a few ms; over the public internet the offset estimate is junk
  and the HUD's `net` reading is meaningless.

## Wire protocol at a glance

```
+-----------------------------+    UDP 63900 (broadcast, 3s cadence)
|     discovery JSON          |  --------> Headset Discovery scans
+-----------------------------+

+-----------------------------+    TCP `pose_port` (default 63901)
|     Hello       (client →)  |  --------+
|     DeviceDescriptor (← srv)|  --------|  command channel
|     ClockPing   (client →)  |  --------|  (length-prefixed JSON)
|     ClockPong   (← srv)     |  --------+
|     DeviceCommand (client →)|
|     Telemetry   (← srv)     |
+-----------------------------+

+-----------------------------+    UDP `video_port` (default 12345)
|     "Hello"     (client →)  |  --------> server learns client addr
|     H.264 fragments         |  <-------- server fans NALs to client
+-----------------------------+
```

## Step 1 — Discovery

Broadcast a JSON announcement on UDP `255.255.255.255:63900` every 3
seconds (or directed broadcast on your subnet's `xxx.xxx.xxx.255` if
limited broadcast is blocked). Payload:

```json
{
  "service": "xrobo-agent",
  "name": "MacMockRobot",
  "tcp_port": 63901,
  "video_port": 12345,
  "version": "0.0.0",
  "device_type": "mock",
  "device_name": "Display Name"
}
```

The headset's `xr/scripts/network/discovery.gd` listens on
`DISCOVERY_PORT = 63900`. Required: `service == "xrobo-agent"` and
`tcp_port > 0` (announcements that fail either check are dropped at
`discovery.gd:55`/`:64`). Load-bearing: `name` (shown in the connection
panel), `tcp_port`, `video_port`, `device_type`, `device_name`. The
production Rust agent also advertises `telemetry_port` and
`pose_udp_port` — today the XR client **ignores both** and learns
those ports from the `DeviceDescriptor` instead, so including them in
your announcement is harmless but optional.

**Tip.** Tooling-side: setting `adb shell setprop debug.xrobo.host
<your-ip>` makes the headset auto-connect on launch (3-second timer in
`xr/scenes/main.gd::_auto_connect_loopback`), bypassing discovery for
smoke tests.

## Step 2 — TCP command channel

Listen on `tcp_port` (default 63901). Wire format for every frame:

```
[4B cmd_len LE int32][cmd_len bytes UTF-8 command name]
[4B data_len LE int32][data_len bytes payload (usually JSON)]
```

(Yes, mixed-endian: command-frame lengths (`cmd_len`, `data_len`) are
**little-endian** i32; the video TCP/UDP headers and the NLFR fragment
header are **big-endian**. Clock-sync payloads are plain UTF-8 JSON, no
endianness. Don't ask.)

### Mandatory: respond to `Hello` with `DeviceDescriptor`

On accept, the headset's `Session.start_handshake()` sends `Hello` with
a JSON body containing client capabilities. Within 3 seconds you must
reply with a `DeviceDescriptor` command whose JSON includes a
`video_feeds[]` array:

```json
{
  "device":         { "type": "mock", "name": "Camera", "icon": "", "model_url": "" },
  "control_schema": { "axes": [], "buttons": [], "poses": [] },
  "input_mapping":  [],
  "telemetry_schema": {},
  "video_feeds": [{
    "name":      "main",
    "display":   "Front Camera",
    "port":      12345,
    "width":     1280,
    "height":    720,
    "fps":       30,
    "stereo":    false,
    "transport": "udp",
    "udp_port":  12345
  }],
  "safety": {}
}
```

`width`/`height` drive `MediaCodec.createVideoFormat` on the headset.
If you advertise 1280×720 but encode 640×480 the decoder configures
for the wrong size and produces zero output (silent failure — see
issue 008). Keep them in lockstep.

`stereo=false` means a mono stream stretched across both eyes;
`true` means a side-by-side encoded frame split 50/50.

`transport: "udp"` + non-zero `udp_port` switches the headset from
the TCP video path to UDP. `"tcp"` keeps it on TCP. `"auto"` does the
same as `"udp"` when `udp_port>0`.

### Mandatory: respond to `ClockPing` with `ClockPong`

Every 1 s the headset sends:

```json
{"t_xr_send": <int64 ns>}
```

You must reply immediately:

```json
{"t_xr_send": <echo>, "t_robot_recv": <int64 ns>, "t_robot_send": <int64 ns>}
```

* All timestamps are unix-epoch nanoseconds (`time.time_ns()` in
  Python, `SystemTime::now().duration_since(UNIX_EPOCH).as_nanos()`
  in Rust). Don't use a monotonic clock — the offset becomes
  meaningless.
* `xr/scripts/network/clock_sync.gd::_parse_field` hand-parses the
  JSON looking for the literal needle `"<key>":` (no space). Emit
  compact JSON: `json.dumps(..., separators=(",", ":"))` in Python.

Without `ClockPong` the headset's `net` and `total` latency HUD
readings stay `"--"`.

### Other commands you'll see (ignore for video-only)

* `DeviceCommand` — controller/input from the headset. Drop if you
  don't drive actuators.
* `Telemetry` — server → headset, your push.

## Step 3 — UDP video stream

Listen on the `video_port` (same one you advertised in the
descriptor). On the first datagram from the headset (it sends a
plain `"Hello"` to register), remember `(sender_ip, sender_port)` and
start fanning fragments back to that address.

### Datagram layout

Every datagram is `[18B fragment header][80B timed header][≤1200B NAL payload]`,
total ≤ 1298 B. Stays under standard Ethernet/Wi-Fi MTU.

```
fragment header (18 bytes, BE except magic & version & flags):
  +0  [4B] magic "NLFR"  = {0x4E, 0x4C, 0x46, 0x52}
  +4  [1B] version       = 1
  +5  [1B] flags         (bit 0 = LAST, bit 1 = FIRST)
  +6  [2B] frag_index    BE  (0-based)
  +8  [2B] frag_count    BE  (total fragments for this NAL)
  +10 [8B] frame_id      BE  (monotonic u64)

timed_video header (80 bytes, all BE):
  +0  [8B] frame_id           u64  (same as fragment header)
  +8  [4B] nal_index          u32  (NAL slot within frame)
  +12 [4B] nal_count          u32  (NALs per frame)
  +16 [4B] pipeline_mode      u32  (0=V4L2 HW, 1=ffmpeg/SW — see PIPELINE_MODE_*)
  +20 [8B] capture_start_ns   u64  unix-epoch ns
  +28 [8B] capture_end_ns     u64
  +36 [8B] encode_start_ns    u64
  +44 [8B] encode_end_ns      u64
  +52 [8B] read_wait_ns       u64
  +60 [8B] parse_ns           u64
  +68 [8B] send_ns            u64  (← drives net latency on HUD)
  +76 [4B] nal_total_len      u32  (TOTAL across all fragments, not this slice)

payload:
  +98 [..1200B] this fragment's slice of the NAL
```

The headset reassembles by `(frame_id, nal_index)` with a
`REASSEMBLY_TTL_NS = 200 ms` TTL. Any fragment lost = whole NAL
dropped (no FEC, no retransmit — see `005-decisions.md` D-3).
Receivers cap in-flight reassembly entries at `REASSEMBLY_MAX = 16`
(see `xr/scripts/network/udp_video_handler.gd:63`); the oldest
partial gets evicted when full.

### Bundling NALs into access units

**Critical.** Each `frame_id` you emit must hold one *complete H.264
access unit*, not one bare NAL. MediaCodec on Adreno can't make sense
of a lone SPS — it needs SPS + PPS paired (as `csd-0` / `csd-1`) before
the first IDR. The headset's Kotlin decoder extracts those from the
*first access unit it sees*, so:

* Buffer the NALs your encoder produces.
* When you see a slice NAL (type `1` = non-IDR, type `5` = IDR),
  emit the *bundle* (preceding SPS/PPS/SEI + the slice) as one
  `frame_id`, with start codes preserved between NALs.
* Each subsequent P-slice on its own as one access unit is fine.

Reference: `tools/mac_mock_streamer.py::_stream_once`.

### Choosing your H.264 encoder

You can pick any encoder, but the SPS it writes must not trip the
Adreno decoder's DPB worst-case heuristic.

* **Recommended on Mac**: `h264_videotoolbox`, profile `baseline`,
  realtime mode. Apple's encoder writes a SPS with the
  `bitstream_restriction` VUI block constraining
  `max_num_reorder_frames = 0`.
* **libx264 baseline with `bframes=0`** does NOT write that VUI
  block by default. The decoder falls back to the level's DPB
  (= 14 at level 4.x for 720p) and stalls input until 14 frames
  have arrived. The headset shows "Decoder queue full" + zero
  output until forever.
* If you must use libx264, pair it with `MediaFormat.KEY_LOW_LATENCY`
  on the decoder side (already set in `KotlinVideoDecoderPlugin.kt`
  for API ≥ 30) which clips the DPB. Even then, videotoolbox is the
  safer default.

Other encoder hints:

* `-bf 0` — no B-frames, matches our send-immediately latency model.
* `-g 15 -keyint_min 15` — IDR every 0.5 s at 30 fps. Lost-fragment
  recovery time is bounded by GOP size; see `005-decisions.md` D-3.
* `-pix_fmt yuv420p` — anything else fails to import as AHB.
* `--profile baseline` or `-profile:v baseline` — smaller DPB by
  spec, no B-frames, decodes on every device.

### MTU sizing

Cap each datagram at ~1298 B (`UDP_NAL_FRAGMENT_PAYLOAD = 1200` + 98 B
headers). Above the local MTU, the kernel does IP-level fragmentation
where a single sub-fragment loss kills the whole datagram — exactly
the failure mode UDP fanout was meant to dodge.

## Step 4 — Verifying

Once you're streaming, the in-headset latency HUD (top-right of the
video panel) will show one line per pipeline stage:

| Line     | Meaning                                                              | Healthy steady-state |
|----------|----------------------------------------------------------------------|----------------------|
| `net`    | `receive_ns − (send_ns − clock_sync_offset)`                         | 5–30 ms (Wi-Fi)      |
| `decode` | `decoded_ns − receive_ns` (MediaCodec time)                          | 10–25 ms             |
| `present`| `now_ns − decoded_ns` (AHB → fragment shader display)                | 30–100 ms            |
| `total`  | sum of the three smoothed stages                                     | 50–150 ms            |
| `frames` | total AHB-imported frames since app start                            | grows at ~30 / s     |
| `stale`  | NALs dropped because `now − receive_ns > 100 ms` (`STALE_NAL_BUDGET_MS`) | 0                    |
| `busy`   | MediaCodec input queue full (`submit_access_unit` returned false)    | 0                    |
| `udp`    | UDP reassembly drops (TTL eviction + oldest-eviction when MAX hit)   | 0                    |

If `net` shows `--`: ClockSync isn't getting `ClockPong` from you, or
the JSON parser is failing (likely the compact-separators issue).

If `decode`/`present` show `--` only at startup: normal (need first
AHB import + first ClockSync sample); should stabilise within ~2 s.

If `udp` climbs steadily: your Wi-Fi is bad, your fragments are above
MTU, or `frame_id` isn't monotonic.

If `busy` climbs and `frames` is flat: MediaCodec isn't producing
output — see issue 008. Check the encoder's SPS DPB constraint per
above.

## Step 5 — Smoke test

```bash
# In your robot's network:
adb shell setprop debug.xrobo.host <your_ip>

# Start your streamer.

# On Pico / Quest:
adb shell am force-stop org.xrobotoolkit.client
adb shell am start -n org.xrobotoolkit.client/com.godot.game.GodotApp

# Watch the handshake:
adb logcat -d | grep --binary-files=text -E "Discovery|Session|TeleOp|UdpVideoHandler"

# Expected sequence:
#   [TeleOp] Auto-connect: using override host <your_ip>:63901
#   [TcpHandler] Connected to <your_ip>:63901 (command)
#   [Session] Hello sent, waiting for DeviceDescriptor...
#   [Session] DeviceDescriptor received: <your name>
#   [TeleOp] Connecting video stream (UDP) to <your_ip>:<video_port>
#   [UdpVideoHandler] Bound, registering with <your_ip>:<video_port>
#   [ClockSync] sample #1 offset=... ms rtt=... ms
#   [RobotView] AhbVideoTexture bound; AHB zero-copy path is now live
```

If you only see the first three lines and nothing else: your
`DeviceDescriptor` is malformed (JSON parse failure) or arrived after
the 3-second handshake timeout.

## References

* `claw/issues/005-decisions.md` — protocol design rationale.
* `claw/issues/008-ahb-ycbcr-sampler-gap.md` — the Vulkan compute
  blit (display path), in case your stream goes black instead of
  red.
* `claw/architecture/wire-protocol.md` — canonical byte-level
  reference, reconciled across the Rust agent, GDScript XR client,
  and `tools/mac_mock_streamer.py`. Read this if the SOP and the
  bytes disagree — the Rust side wins.
* `robot/src/network/protocol.rs` + `robot/src/video/pipeline.rs` —
  canonical encoders/decoders on the robot side.
* `xr/scripts/network/protocol.gd` — XR-side decoders. Mirrors the
  Rust layout but only implements the directions the headset needs
  (decode for video TCP/UDP fragments, encode for command frames).
* `xr/scenes/main.gd::_select_video_transport` — the
  TCP-vs-UDP selection logic.
