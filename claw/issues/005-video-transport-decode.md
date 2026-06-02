# Video Transport And Decode Gaps

Status: closed (smoke-tested on Pico B3110, 2026-05-09)
Category: video transport and decode

## Resolution Summary

All eight items closed; design decisions captured in
[`005-decisions.md`](005-decisions.md).

| # | Item | Status | Where |
|---|------|--------|-------|
| 1 | Wire UDP transport into main.gd with descriptor negotiation | done | `xr/scenes/main.gd` `_select_video_transport`, `_connect_video_stream` |
| 2 | Add transport metadata to video feed descriptors | done | `robot/src/device/traits.rs` `VideoFeedInfo.transport`, `udp_port`; runtime overlay in `robot/src/main.rs` |
| 3 | RTP-style fragmentation for large NAL units over UDP | done | `robot/src/video/pipeline.rs` `build_udp_fragments` (encoder, 4 unit tests) + `xr/scripts/network/protocol.gd` `decode_udp_fragment` + `xr/scripts/network/udp_video_handler.gd` reassembly |
| 4 | FEC / retransmit / RTP / QUIC / WebRTC decision | done | `005-decisions.md` D-3: explicit decision to stay best-effort, GOP recovery |
| 5 | TCP reader: worker thread vs inline drain | done | `005-decisions.md` D-4 + reinforced doc-comment in `xr/scripts/network/tcp_handler.gd` |
| 6 | Configurable larger receive buffer | done | `tcp_handler.gd` `set_max_recv_buffer()` + 32 MiB override on the video handler in `main.gd` |
| 7 | MediaCodec async callback / OES SurfaceTexture plan | done | Doc-comments in `KotlinVideoDecoderPlugin.kt` aligned with `005-decisions.md` D-6: sync polling + Surface→ImageReader→AHB |
| 8 | Vulkan AHardwareBuffer zero-copy path actually builds | done | `xr/native/ahb_decoder/build.sh` produces a 600 KiB arm64 .so, installed to both the addons/ and android/build/libs/arm64-v8a/ paths |

## Original Unfinished Items (for reference)

- ~~Wire UDP video transport into `main.gd` with an explicit transport selection or descriptor negotiation.~~
- ~~Add transport metadata to video feed descriptors if UDP is meant to be selected dynamically.~~
- ~~Implement RTP-style fragmentation or another strategy for large NAL units over UDP.~~
- ~~Add FEC, retransmit, RTP, QUIC, or WebRTC behavior if reliable Wi-Fi deployment remains a goal.~~ (decision: no — see D-3)
- ~~Revisit dedicated TCP reader thread or document the inline drain-loop as the final design.~~ (decision: inline — see D-4)
- ~~Implement larger receive buffer support if still needed; current Godot path only has `TCP_NODELAY` and a drain loop.~~
- ~~Complete or remove the MediaCodec async callback / OES SurfaceTexture plan.~~
- ~~Make the Vulkan AHardwareBuffer zero-copy path actually build and ship.~~

## Acceptance Criteria

- ✅ Video feed descriptors can select TCP or UDP, and Godot connects the matching handler. *Verified on Pico: with `udp_port` set in robot config, headset logs `Connecting video stream (UDP) to 127.0.0.1:12345` after the descriptor lands; with it unset, stays on `(TCP)`.*
- ✅ UDP path works over real Wi-Fi in headset testing. **Verified end-to-end on Pico B3110 ↔ Mac (192.168.31.95 ↔ 192.168.31.31, single Wi-Fi AP, 2026-05-09)**: descriptor-driven TCP→UDP upgrade fired (`[TeleOp] Connecting video stream (UDP) to 192.168.31.31:12345` after `Video stream disconnected` from the initial TCP probe), `[UdpVideoHandler] Bound, registering with ...`, `UDP video client registered: 192.168.31.95:41669` on the agent side, and **sustained `KotlinVideoDecoder: AHB import: ~30 fps` for 28+ seconds** with no reassembly drops (no `[probe] WARN` or `reassembly: ...` errors logged). Earlier loopback Python probe additionally confirmed wire format byte-for-byte: `NLFR` magic, version=1, datagram = 18 (frag header) + 80 (timed header) + ≤1200 (payload), fragment counts 1–25 per NAL across 360 reassembled NALs in 10 s.
- ✅ Large IDR/NAL handling is defined and tested. *Fragment encoder has 4 unit tests in `pipeline.rs`; reassembler in `udp_video_handler.gd` clears stale partials at 200 ms TTL and caps memory at REASSEMBLY_MAX entries. End-to-end fragmentation+reassembly proven on real ffmpeg-encoded NALs (largest seen: 25 fragments / ~30 KiB).*
- ✅ Chosen decode path is documented (D-6: AHB zero-copy preferred, plane-copy fallback, CPU YUV→RGB safety net).
- ⚠️ AHB path builds a non-empty `.so` (~600 KiB), exports the expected `ahb_decoder_init` and `Java_..._nativeImportAhb` symbols, is installed at both addon and JNI paths, and **the import side works** (Vulkan device acquired, YCbCr conversion ready, sustained `AHB import: ~30 fps` on Pico B3110). **However, the imported `VkImage` does not display** because Godot's `Texture2DRD` shader binding uses a default sampler that lacks `VkSamplerYcbcrConversion` info — sampling a `VK_FORMAT_UNDEFINED + externalFormat` image without the immutable conversion-aware sampler returns 0 (black). Operator workaround: `adb shell setprop debug.xrobo.force_yuv_plane 1` falls back to Plan B's CPU plane copy + 3 L8 textures + GPU shader YUV→RGB, **which displays real video at 30 fps with ~120 ms total latency on Wi-Fi** (verified on Pico B3110 against Mac ffmpeg/videotoolbox encoder, 640×360, 4 Mbps). True zero-copy display is tracked as a follow-up — see issue 008.
