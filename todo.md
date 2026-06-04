# Spatial Audio Recording TODO

## Blockers
- [x] Fix audio PTS anchoring so the first AAC frame is aligned to the first successful microphone read, not session start.
- [x] Fix the `RECORD_AUDIO` runtime-permission race so the first enabled recording waits for permission instead of silently producing no audio track.

## Code Fixes
- [x] Release `AudioRecord` if `MediaCodec` creation/configuration fails.
- [x] Preserve hidden audio shape options when the capture settings panel saves visible options.
- [x] Make `native_audio_writes` reflect actual muxer writes, not dropped/no-op audio packets.
- [x] Avoid relying on `has_method()` for bundled Android plugin RPCs; use a compact JSON configure RPC so `record_audio` reaches Kotlin.
- [x] Include muxer native write counters in `QcMetrics`.
- [x] Fix native writer finish/drain race when packets are parked in the I/O thread's deferred queue.
- [x] Rescale packet PTS/duration from microseconds into each FFmpeg stream's actual time base, fixing inflated AAC duration.
- [x] Avoid spurious stop timeout while audio capture drains.
- [x] Remove dead `AudioCapture.drainLoop` branch.
- [x] Avoid cumulative AAC PTS rounding drift.
- [x] Bump the spool manifest schema after adding `sources.audio`.
- [x] Keep manifest audio layout honest when requested FOA/4-channel capture falls back to stereo.
- [x] Soften the contract compatibility comment around `SessionConfig` constructor changes.

## Not Done In This Iteration
- [ ] Write real ISO BMFF `SA3D` / `SAND` boxes instead of only stream metadata.
- [ ] Implement true FOA / first-order Ambisonics capture via platform SDK or offline beamforming.
- [ ] Add playback/decoder validation with head-pose-driven binaural rendering.
- [ ] Investigate Quest depth capture: smoke test saw depth callbacks but `frames=0` / `native_depth_writes=0`, so the writer finalized without a depth stream.

## Verification Done
- [x] `godot --headless --xr-mode off --path xr --check-only --script ...` for edited GDScript files.
- [x] `gradle :contract:assemble :spatialmp4_muxer:assemble :questcapture:assemble` from `xr/android_plugin`.
- [x] `ANDROID_NDK=/Users/duino/Library/Android/sdk/ndk/26.1.10909125 make build-ffmpeg` from `xr`.
- [x] `ANDROID_NDK=/Users/duino/Library/Android/sdk/ndk/26.1.10909125 make build-quest` from `xr`.
- [x] Installed `xr/build/quest/Operator.apk` to Quest 3 `2G0YC1ZF7S0C2D`.
- [x] Disabled/skipped Quest Guardian via Oculus debug props and launched the app successfully in `ego` mode.
- [x] Ran automated 12s in-headset recording smoke test with `RECORD_AUDIO` granted.
- [x] Pulled `/sdcard/Movies/SpatialMP4/20260603_173121.mp4` and verified with `ffprobe`: HEVC video 12.254s, AAC stereo 48kHz 128kbps 12.352s, total MP4 duration 12.352s.
