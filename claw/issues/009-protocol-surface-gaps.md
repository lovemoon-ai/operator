# Protocol surface gaps — XR client lagging Rust agent

Status: open
Category: protocol surface gaps (XR client lagging Rust agent)
Spawned-from: code-anchored audit during architecture doc cleanup, 2026-05

See [`claw/architecture/wire-protocol.md`](../architecture/wire-protocol.md)
for the byte-level reference; this issue is the consolidated TODO that
fell out of writing that doc against the actual source tree.

## Why this is one issue, not three

The three gaps below have different surface areas (pose data plane,
telemetry channel, discovery mechanism) and the cost of leaving any one
of them on the floor varies by an order of magnitude. They are grouped
into one umbrella because they share the same *shape*: in each case the
Rust robot agent has the wire surface built, tested, and live, while
the GDScript XR client is still using the legacy path the surface was
designed to replace. Whoever picks one of these up should feel free to
split it into its own issue at that point — the grouping here is just
to keep the audit-time discovery in one place, not to commit anyone to
a single PR.

## G-1. Pose UDP data plane has no XR sender

The high-rate pose channel was added explicitly to escape TCP
back-pressure on port 63901 (`005-decisions.md` D-1 and D-2 in the
sense that drop-old by `seq` is what the Rust side now enforces on
this channel). The robot half is fully built; the headset half still
goes over the legacy `"Tracking"` command-frame on TCP 63901.

### Built on the Rust side

* Codec: `robot/src/network/protocol.rs:307-356` (constants),
  `robot/src/network/protocol.rs:318-356` (`PoseUdpPacket` struct),
  `robot/src/network/protocol.rs:378-475` (`encode` / `decode`),
  `robot/src/network/protocol.rs:612-651` (roundtrip + CRC unit
  tests, including `pose_udp_pose_roundtrip`).
* Server: `robot/src/network/pose_udp_server.rs:86-133` (CRC →
  session-token → drop-old-by-`seq` pipeline, all three counters
  exposed via `UdpDropStats`).
* Wired into the agent: `robot/src/main.rs:135-141` brings the
  server up under `try_join!` alongside discovery / TCP /
  telemetry; `robot/src/main.rs:110` allocates the shared
  `session_token: Arc<AtomicU32>` that the TCP handshake is
  *supposed* to stamp.

### Not built on the XR side

* `xr/scripts/network/pose_sender.gd:47-50` still sends pose as a
  `"Tracking"` command-frame on the TCP socket.
* No GDScript caller exists for `PoseUdpPacket::encode`; no UDP
  socket is bound for outbound pose.
* `tracking_provider.gd` (`xr/scripts/xr/tracking_provider.gd`)
  feeds `command_sender.gd` (`xr/scripts/input/command_sender.gd:24-29`)
  for `DeviceCommand`, and feeds `pose_sender.gd` for the legacy
  `"Tracking"` frame. There is no third consumer wired for UDP pose.

### What it costs us

Pose updates are throttled by the same TCP socket buffer as
`DeviceCommand`, `Telemetry-legacy`, and `ClockPing`. The whole
point of the drop-old-by-`seq` policy on the UDP path
(`pose_udp_server.rs:112-115`) — that a stale pose is *worse* than
no pose, because it pulls the robot toward a position the operator
has already left — is forfeit. Under Wi-Fi loss or any TCP
back-pressure, pose rate dips with command rate instead of staying
pinned to controller refresh.

### What's needed (shape only)

* A GDScript `PoseUdpPacket` encoder mirroring
  `protocol.rs:378-406` byte-for-byte (LE header,
  CRC-16/CCITT-FALSE, `"POSE"` payload kind, 64-byte payload).
* A `UdpPoseSender` analogous in role to `UdpVideoHandler`
  (`xr/scripts/network/udp_video_handler.gd`) but outbound:
  bind once, send-on-tick, no reassembly.
* Wire `tracking_provider.gd` to feed it — either through a new
  signal or by adding a sender alongside the two
  `command_sender` / `pose_sender` consumers it already feeds.
* Pick the port from the `DeviceDescriptor`-driven path (see
  trip-wire below).

### Trip-wires / open questions

* **How does the XR side learn the robot's UDP port?** The
  discovery beacon already carries `pose_udp_port`
  (`robot/src/network/discovery.rs:65-90`), but
  `xr/scripts/network/discovery.gd:58-62` only extracts
  `tcp_port` and `video_port`. The cleanest fix is to plumb the
  port through the `DeviceDescriptor` instead (`telemetry_schema`
  / `video_feeds` already work this way) rather than teaching
  discovery a new field. See discrepancy #1 in `wire-protocol.md`.
* **How does the XR side learn the session token?** The
  `Arc<AtomicU32>` in `robot/src/main.rs:110` is allocated and
  shared with the UDP server, but it is **never written to** by
  the TCP handshake — `robot/src/network/session.rs` does not
  stamp the token, and there is no `session_token` field in the
  XR-side `session.gd`. So `session_token == 0` ("anonymous")
  works today as the de-facto contract. Either accept that
  (and document it in `wire-protocol.md` §Channel 3) or design a
  token-mint step into the Hello → DeviceDescriptor exchange.
* The pose-UDP path on the Rust server preserves the on-wire
  `seq` end-to-end into the latency aggregator
  (`pose_udp_server.rs:127-133`), unlike the TCP path which mints
  a fresh `seq` via `record_rx`. The XR sender must use a
  monotonic per-session counter starting at 1, and reset it on
  reconnect — see `pose_udp_server.rs:74-80` for the server's
  expectation.
* The legacy `"Tracking"` frame still gets `v1 → v2`-adapted on
  the robot (`robot/src/network/session.rs:27-79`). When UDP pose
  lands, decide whether to keep the legacy adapter (for
  backwards compatibility with older XR builds) or sunset it.

## G-2. Dedicated telemetry channel 63903 has no XR consumer

A second TCP socket was carved out at port 63903 specifically so
10 Hz telemetry would not contend with the command hot path for the
same outbound buffer
(`robot/src/network/telemetry_server.rs:8-13` documents the rationale).
Today the robot dual-emits on the legacy and dedicated channels; the
headset only listens to the legacy one.

### Built on the Rust side

* Server: `robot/src/network/telemetry_server.rs:29-74` (10 Hz
  push, multi-subscriber via `watch::Receiver` clone, per-subscriber
  socket isolation).
* Wired into the agent: `robot/src/main.rs:143`.
* Legacy emitter still active: `robot/src/network/pose_server.rs:141-158`
  pushes telemetry on the command channel (port 63901) in parallel.
  This dual-emit is intentional backward compat
  (`telemetry_server.rs:14-17`).

### Not built on the XR side

* Only telemetry consumer is on the command channel:
  `xr/scripts/network/session.gd:45-49` handles `"Telemetry"`
  command-frames received over 63901.
* No code opens a TCP socket to 63903; `tcp_handler.gd` is
  instantiated once for 63901 (command) and once for 12345 (video
  TCP), never for 63903.

### What it costs us

Same head-of-line story as G-1, smaller magnitude. 10 Hz telemetry
pushes contending with 72 Hz `DeviceCommand` writes on the same
TCP send buffer amplify jitter on the command channel under load.
The dedicated channel exists exactly to break that coupling; until
the XR side cuts over, the architectural win is on paper only.

### What's needed (shape only)

* XR-side TCP client to 63903. Mechanically, this is a second
  `TcpHandler` instance configured with the right port and the
  same command-frame codec it already speaks for 63901 — the
  wire format is identical
  (`telemetry_server.rs:67-74` confirms `command == "Telemetry"`
  with a JSON body, same as the legacy path).
* Decide whether `session.gd::on_telemetry_received` becomes
  port-agnostic (consume from whichever channel fires first) or
  whether the dedicated channel becomes the only path and the
  63901-side handler is muted.
* Decide whether to keep the dual-emit on the robot side
  indefinitely or sunset 63901 telemetry once XR migrates.
  Sunsetting requires a flag day (or a `DeviceDescriptor` field
  saying "I speak 63903, please don't dual-emit"); keeping it
  costs an idle `watch::Receiver` and one extra serialization per
  push.

### Trip-wires / open questions

* If multiple HUD components subscribe to telemetry, only one
  should own the socket; the rest should consume from a Godot
  signal. Mirror the existing `telemetry_received` signal on
  `session.gd:11`.
* `telemetry_server.rs:73` exits the per-subscriber spawn on send
  error but keeps the listener alive. XR-side reconnection logic
  needs to handle this — the same "drain-loop + reconnect" shape
  that `tcp_handler.gd` already implements should be fine.

## G-3. mDNS registered but unconsumed

The robot announces itself as `_xrobo._tcp.local.` via `mdns-sd` *in
addition to* the UDP 63900 broadcast. The headset only listens to the
UDP broadcast.

### Built on the Rust side

* mDNS daemon: `robot/src/network/discovery.rs:20` creates
  `ServiceDaemon`, `robot/src/network/discovery.rs:22` registers
  `_xrobo._tcp.local.`, `robot/src/network/discovery.rs:52`
  performs the registration. Doc-comment at
  `robot/src/network/discovery.rs:7` calls out mDNS as the primary
  intended discovery path with UDP broadcast as the fallback.

### Not built on the XR side

* `xr/scripts/network/discovery.gd:54-81` is the only discovery
  entrypoint and it listens on UDP 63900 only. No mDNS browser
  exists in GDScript and Godot 4 has no built-in
  `_resolve_mdns()` / `NsdManager`-equivalent API.
* See discrepancy #2 in `wire-protocol.md`.

### What it costs us

Today, nothing measurable — the UDP 63900 broadcast works on the
home / lab Wi-Fi the project has been smoke-tested on. The trip-wire
case is corporate Wi-Fi or any deployment where inter-AP
broadcasts are blocked at L2; in that environment mDNS multicast
typically survives (5353/UDP is more often allowed through than
255.255.255.255). The mDNS announcement is currently dead-weight
on the robot side — it costs the agent a `ServiceDaemon` thread
and ~10 KB of memory, nothing more.

### Options (no recommendation)

* (a) Implement a minimal mDNS browser in GDScript. Non-trivial —
  multicast UDP 5353, DNS-SD packet parsing (PTR / SRV / TXT
  records), conformance with the `_xrobo._tcp.local.` service-type
  format `mdns-sd` produces.
* (b) Wire it via Android `NsdManager` through a new Kotlin
  plugin (mirroring the shape of
  `xr/native/ahb_decoder/`-style native deps). Closer to
  platform-native; Pico would presumably pick it up via the
  same `NsdManager` interface, but that needs verifying.
* (c) Drop the Rust-side mDNS registration to reduce wire surface
  area. Costs roughly 30 lines in `discovery.rs` and removes the
  `mdns-sd` dependency.

### Trip-wires / open questions

* If a future deployment hits broadcast-blocked corporate Wi-Fi,
  this jumps from "dead-weight" to "blocking", which would push
  option (a) or (b).
* The discovery beacon already advertises `telemetry_port` and
  `pose_udp_port` (see G-1 trip-wires); whatever fix lands here
  should also decide whether mDNS TXT records carry the same
  ports or whether the XR side falls back to the descriptor for
  port discovery once it has any connection.

## Cross-cutting context

All three gaps were surfaced during a code-anchored protocol audit
in 2026-05, written up at
`claw/architecture/wire-protocol.md`. The discrepancy table at the
end of that document (`wire-protocol.md` "Summary of
inter-implementation discrepancies") lists six items; G-1, G-2, and
G-3 here correspond to entries #3, #4, and #2 in that table
respectively. Entries #1, #5, and #6 are documented but do not
warrant their own issue:

* #1 (XR ignores `pose_udp_port` / `telemetry_port` from the
  discovery beacon) is folded into the G-1 trip-wire on port
  source-of-truth.
* #5 (`VideoFrameCodec` raw-NAL path and `"VideoFrame"` command
  dispatch are both dead code) is a delete-or-document decision,
  not a surface gap. No XR consumer or robot producer touches it
  on the hot path today.
* #6 (SOP says `REASSEMBLY_MAX = 64`, code uses 16) is a doc fix
  on the SOP side and unrelated to wire surface.

## Acceptance criteria for closure

Each gap closes independently. Per-gap criteria:

* **G-1.** `pose_sender.gd` no longer emits `"Tracking"` frames on
  TCP 63901 by default. A new GDScript pose-UDP encoder passes a
  byte-for-byte conformance test against
  `protocol.rs::tests::pose_udp_pose_roundtrip` (the recommended
  approach is to run the same vector through both encoders and
  diff). Robot-side `stats.stale_drop_count` increments under
  burst load (proving drop-old is doing work, not that the
  channel is dead).
* **G-2.** XR-side telemetry consumer subscribes to 63903 and the
  legacy 63901 telemetry handler is either removed or gated behind
  a "no dedicated channel" fallback. Smoke-test under load shows
  command-channel jitter unaffected by telemetry bursts.
* **G-3.** Either an mDNS browser lands on the XR side and
  resolves `_xrobo._tcp.local.` end-to-end (replacing or
  augmenting the UDP broadcast path) **or** the mDNS registration
  is removed from `discovery.rs` and the discrepancy is closed by
  deletion.
