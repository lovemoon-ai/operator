# Issue 005 — Video Transport Design Decisions

Status: accepted (2026-05)
Scope: companion ADR-style doc for `005-video-transport-decode.md`. Captures
the reliability / transport decisions we are making *now*, so future
sessions don't re-litigate them. Each decision lists what we
considered, what we picked, and the trip-wires that would force a
revisit.

## D-1. UDP transport selection: descriptor-driven, opt-in

**Decision.** `VideoFeedInfo.transport` (string) and `udp_port` (u16)
fields in the device descriptor advertise what the robot supports.
The XR client's `_select_video_transport()` picks UDP iff
`transport ∈ {"udp", "auto"}` and `udp_port > 0`. Default is `"tcp"`,
which keeps every existing YAML descriptor on the historical path.

**Considered.** A blind preference for UDP (always when it's open) was
attractive for tail-latency reasons but made the smoke-test loop
(`adb reverse` + 127.0.0.1) misbehave because `adb reverse` is
TCP-only. Hardcoding the smoke-test IP into the heuristic was uglier
than just letting the operator decide via descriptor.

**Trip-wires.** If we ever support multi-feed devices (one stereo
camera + one wrist cam), each feed needs its own transport selection
— the field is per-feed already, so no protocol change needed, but
the XR `_extract_primary_video_feed` hack picks only the first feed
and would have to grow.

## D-2. UDP framing: app-layer fragmentation, MTU-friendly

**Decision.** UDP datagrams carry one NAL slice each, capped at
`UDP_NAL_FRAGMENT_PAYLOAD = 1200` bytes per fragment plus a 16-byte
fragment header (`NLFR` magic, version, flags, idx, count, frame_id)
and the existing 80-byte timed video header. Total datagram never
exceeds ~1300 bytes, comfortably under typical Wi-Fi/Ethernet MTU.

**Considered.**

* *No fragmentation, drop > 60 KiB NALs* — the previous behavior. IDRs
  on a 1280×720 stream routinely exceed 60 KiB so the headset would
  freeze for a full GOP. Untenable as a permanent design.
* *RTP / RFC 6184 (FU-A units)* — proper standard, but we don't need
  RTP timestamps (we have our own 80-byte timed header) and the RTP
  parser would be another 200 lines of GDScript. App-layer framing
  with the same timed header on both transports is simpler.
* *IP-level fragmentation* — kernel-handled but a single dropped
  sub-fragment loses the whole datagram. Compounds loss on lossy
  Wi-Fi exactly when we need it least.

**Trip-wires.** If we move off Wi-Fi to a VPN / encapsulated tunnel
with smaller path MTU, drop the constant from 1200 to ~1000 (or do
proper PMTUD). If a different decoder wants RTP-shaped input we can
add an adapter at the GDScript boundary.

## D-3. Reliability: no FEC, no retransmit, no RTP / QUIC / WebRTC

**Decision.** The UDP path stays best-effort. A lost fragment loses
the NAL it belonged to; the decoder recovers at the next IDR (GOP =
0.5 s on the robot pipeline, item [opt 4]). The TCP path remains as
the reliable fallback when a feed needs zero loss.

**Why.** The teleop budget is ~100 ms motion-to-photons. Any
retransmit at Wi-Fi RTT (~5–30 ms) past the first byte burns half
the budget on a packet whose visual contribution may already be
stale. A short GOP (0.5 s) gives us a guaranteed recovery point
sooner than most retransmit schemes would deliver a clean replay.

We also explicitly considered:

* **FEC (XOR / Reed-Solomon)** — recovers some isolated losses, but
  the bitrate overhead (10–25 %) is non-trivial on a Wi-Fi link
  already shared with controllers and audio, and the decoder
  complexity is high for the tail-latency win.
* **Application-layer ARQ** — same problem as TCP: ordered delivery
  + retransmit re-creates head-of-line blocking on top of UDP, which
  is the exact issue we left TCP to escape.
* **QUIC** — solves head-of-line blocking via streams but has its own
  control-plane overhead (TLS handshake, congestion control) and no
  zero-RTT story we control. Worth re-evaluating if we add an
  internet (non-LAN) deployment story.
* **WebRTC** — purpose-built for low-latency video, but pulls in a
  signalling server, ICE/STUN/TURN, SDP negotiation, and a sizeable
  GDScript / native bridge. The price tag is a separate project.

**Trip-wires.** Revisit if (a) we deploy outside a single Wi-Fi
broadcast domain, (b) we get tail-latency complaints that aren't
already captured by the GOP-recovery model, or (c) we want to support
multiple simultaneous viewers where the "drop and wait for IDR" UX
is unacceptable.

## D-4. TCP reader: inline drain-loop is final

**Decision.** Stay with the inline drain-loop in
`tcp_handler.gd::_process_connected`. Cap at `MAX_DRAIN_PER_TICK = 32`
chunks of `READ_CHUNK_SIZE = 65536` bytes per process tick. Don't
spin up a worker thread for socket reads.

**Why.** Worker threads were tried (see `tcp_handler.gd` opt-6 reverted
comment): Godot 4's StreamPeerTCP is not reliably thread-safe on Pico
— `put_data` returned `FAILED` ~half the time with a worker reading
in the background, killing the connection before any frames flowed.
The inline loop adds at most ~3–5 ms of tx latency in the worst case,
versus a 100 ms motion-to-photons budget. That tradeoff is acceptable.

**Trip-wires.** If a future Godot release fixes StreamPeerTCP thread
safety, or if profiling shows process-tick latency dominating, revisit
with a TCP-only worker (we kept the API surface clean enough that the
swap is mechanical).

## D-5. Receive buffer: capped, configurable per-handler

**Decision.** `tcp_handler.gd::MAX_RECV_BUFFER` defaults to 10 MiB and
is exposed via `set_max_recv_buffer()` so individual handlers (e.g.
the dedicated video stream) can tune it without recompiling. Hitting
the cap clears the buffer and disconnects — that's the right action
because nothing past the cap is parseable anyway.

**Why.** Originally hard-coded 10 MiB. A 1280×720 IDR caps around
1.5 MiB at our 4 Mbps bitrate so 10 MiB is plenty of headroom for
short bursts. Exposing the knob is cheap insurance for future
high-resolution feeds without forcing a code edit.

## D-6. Decode path: keep all three, YUV plane is the *currently shipping* default; AHB is gated behind a known issue

**Decision.** The Kotlin decoder probes `libahb_decoder.so` at
classload time. When available, MediaCodec renders to an
`ImageReader` Surface and the AHB path takes over (zero CPU copy).
When absent, falls back to the YUV plane copy (Plan B) as the GPU
fast path. CPU YUV→RGB stays as the ultimate safety net.

**Update (2026-05-09 smoke test).** The AHB import side works on
Pico B3110 (Vulkan 1.4.295 / Adreno 840) at sustained 30 fps, but
the headset displays **black** when AHB is on, because Godot's
default sampler used by `Texture2DRD` shader bindings lacks the
`VkSamplerYcbcrConversion` required to sample a
`VK_FORMAT_UNDEFINED + externalFormat` image. See issue 008 for
options to actually display AHB textures. **Until 008 lands, the
operator-facing default is the YUV plane path**, toggled via:

```
adb shell setprop debug.xrobo.force_yuv_plane 1
```

YUV plane path measurement on the same hardware/network: 30 fps,
total motion-to-photons ≈ 120 ms (decode 35–40 ms, present 14–17 ms,
plus Wi-Fi tx and encoder).

**Why we still ship the AHB scaffold.** The wire format, JNI bridge,
Vulkan import, and YCbCr sampler creation are all working — the gap
is purely on the Godot RenderingDevice side. Removing the scaffold
would cost re-doing all that when option 1 in issue 008 (compute
blit) is the natural fix.

**Why sync polling stays.** The async callback path was tried and
reverted — `onOutputBufferAvailable` never fired on swan even though
input slots were consumed. Sync polling adds ~20 ms worst case which
is well inside budget.

**Trip-wires.** Revisit the async callback if we move to a different
device family. Drop the CPU path once we have telemetry showing
nobody hits it on real hardware. Drop AHB entirely (option 4 in
issue 008) if 008 sits open for more than ~3 sessions.
