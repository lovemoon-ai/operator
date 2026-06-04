# Spatial audio recording — capture mic + ambisonics into the SpatialMP4

Status: open
Category: capture pipeline (XR client / SpatialMP4 muxer)
Spawned-from: capture-side feature request, 2026-06

The Quest/Pico capture session today muxes stereo RGB (HEVC), depth
(FFV1 GRAY16LE), and a fan-out of timed-metadata tracks (head pose,
controller pose, hand joints, controller input) into a single mp4 via
`SpatialMp4MuxerPlugin`. There is **no audio track**. This issue scopes
adding a spatial audio track to that mp4 — capture, encode, mux,
metadata, and the GDScript surface — so a recorded session reproduces
what the operator heard, not only what they saw and where they moved.

See [`claw/architecture/xr-client.md`](../architecture/xr-client.md)
for the XR-side capture wiring and
[`xr/addons/spatialmp4_muxer/api/SpatialMP4Writer.gd`](../../xr/addons/spatialmp4_muxer/api/SpatialMP4Writer.gd)
for the host-facing muxer surface.

## Why this is one issue, not a stack

Audio capture touches four layers — Android permission + capture
device, encoder, muxer/contract surface, session-config plumbing — but
none of them are useful in isolation. A mic-only Kotlin capture with
no muxer sink is dead code; a contract `onAudioPacket` with no
producer is paper. Land it as one feature, gated behind a single
`record_audio` capture option in `SessionSpoolWriter`.

## Current state

### Not built anywhere

* `xr/export_presets.cfg:183` (Quest), `:446` (Pico), `:709` (GlassXR)
  all have `permissions/record_audio=false`. Neither
  `permissions/modify_audio_settings` nor `permissions/capture_audio_output`
  is set. Without `RECORD_AUDIO` in the manifest, no Android capture
  API call will succeed.
* `xr/scripts/capture_app.gd:689` (`_setup_audio_cues`) is the only
  audio code in the XR client today, and it is **playback** — a
  `cue_player: AudioStreamPlayer` that plays start/stop beeps. No
  `AudioStreamMicrophone`, no `AudioServer.add_capture_device`, no
  Kotlin `AudioRecord`.
* `xr/scripts/session_spool_writer.gd:63-68` enumerates the sources
  manifest with `rgb`, `depth`, and `pose` entries; there is no
  `audio` entry. `capture_options` likewise has no `record_audio`
  key — flipping one on through the existing
  `XRToolsUserSettings`-driven path would no-op.

### Not built in the muxer / contract

* `xr/android_plugin/contract/src/main/java/com/spatialmp4/contract/SpatialDataSink.kt:193-253`
  exposes `onRgbCsd / onRgbPacket / onDepthMetadata / onDepthFrame`.
  There is no `onAudioCsd` / `onAudioPacket` and no audio fields on
  `SessionConfig` (`SpatialDataSink.kt:89-106`). The contract is
  versioned (`CONTRACT_VERSION: Int = 2`), and the comment at
  `SpatialDataSink.kt:27-30` calls audio out as the kind of hot-path
  stream the contract is reserved for — it just hasn't been added.
* `xr/android_plugin/spatialmp4_muxer/src/main/cpp/spatialmp4_writer_jni.cpp`
  declares track ids 0–6 (`kTrackHeadPose` through
  `kTrackRightControllerInput`) and per-track-kind streams (HEVC,
  FFV1 depth, timed metadata). Grep for `audio | AAC | Opus |
  ambisonic | SA3D` returns nothing — there is no audio stream
  allocation, no codec wiring, and no spatial-audio side data atom
  written.
* `xr/android_plugin/spatialmp4_muxer/src/main/java/com/spatialmp4/questcapture/SpatialMp4MuxerPlugin.kt:67-71`
  exposes per-stream metric counters (`metricNativeWriteRgb`,
  `metricNativeWriteDepth`, `metricNativeWritePose`,
  `metricNativeWriteHand`, `metricNativeWriteControllerInput`).
  There is no `metricNativeWriteAudio` and no `@UsedByGodot
  writeAudioPacket` entry point.
* `xr/addons/spatialmp4_muxer/api/SpatialMP4Writer.gd` (the GDScript
  facade) mirrors the surface above and has no audio method.

### What "spatial audio" means here

The intended capture is **first-order ambisonics (FOA, 4-channel
B-format: W, X, Y, Z)** for the head-locked microphone array,
expressed in the head frame. On playback, a renderer rotates the
B-format basis by the inverse of the head pose track to produce a
world-locked binaural / loudspeaker render. Stereo and mono are
acceptable degraded modes (when the headset only exposes a stereo or
mono mic) and must be tagged as such in the track metadata so a
downstream player does not try to rotate a non-ambisonic signal.

FOA is the minimum interesting target because:

* It is what the head pose track in the SpatialMP4 already enables
  on the decoder side — rotating ambisonics by `-q_head(t)` is a
  4×4 matrix multiply per frame.
* It is what Quest 3's mic array can plausibly deliver via Meta's
  Spatial Audio Capture SDK; Pico exposes raw mic streams that can
  be beamformed into FOA offline.
* It is what Google's `SA3D` / `SAND` mp4 box convention already
  encodes — no new container surface needs to be invented.

Higher-order ambisonics (HOA) is out of scope; the mic array on
current consumer headsets cannot capture it without post-processing
that does not belong in the capture path.

## What it costs us to not have this

* **Egocentric recordings have no soundscape.** Operator commentary,
  environment audio, button-press feedback, and any voice annotation
  the operator might add during a teleoperation session are
  unrecoverable.
* **Sim-to-real and policy-replay use cases lose a signal.** The
  capture pipeline exists primarily to feed downstream learning and
  evaluation; audio is a known-useful modality for contact events
  (clicks, scrapes), human-robot interaction, and any speech-driven
  policy condition.
* **The "spatial" in SpatialMP4 is currently false advertising for
  audio.** The container ships head pose and ambisonic-ready playback
  metadata for video, but the audio slot is empty.

## What's needed (shape only)

Land in one PR — partial implementations create more dead surface
than they remove. Order below is the implementation order, not the
spec order.

1. **Manifest + permission.** Flip `permissions/record_audio=true`
   for Quest, Pico, and GlassXR exports in
   `xr/export_presets.cfg`. Decide whether
   `permissions/modify_audio_settings` is needed for Meta's Spatial
   Audio SDK (it is for some routing modes — verify at integration
   time). Add `record_audio` to the runtime permission request flow
   in `xr/scripts/capture_app.gd`.

2. **Capture device.** Two options, pick one:
   * (a) **Kotlin `AudioRecord` direct.** Open the mic in
     `MediaRecorder.AudioSource.MIC` (or `UNPROCESSED` if the
     platform supports it and we want raw beamforming inputs).
     Quest 3 exposes up to 4 mic channels via
     `CHANNEL_IN_*` masks — verify the exact mask at integration
     time. Pico exposes 2.
   * (b) **Meta Spatial Audio Capture SDK** (Quest only). Gives
     pre-beamformed FOA directly. Requires falling back to (a) on
     Pico / GlassXR and emitting an explicit "downgraded to stereo"
     warning in the manifest.
   * Recommendation: (a) for portability + a Quest-only
     beamforming step that promotes 4-channel raw → FOA when the
     Spatial Audio Capture SDK is available. Implement (a) first;
     (b) is an upgrade.

3. **Encoder.** AAC-LC via `MediaCodec` for the stereo path; for the
   4-channel FOA path, AAC-LC also works (use `audioConfig`'s
   `channelConfiguration=0` + the explicit channel mapping atom).
   Encoder runs on its own MediaCodec output thread, mirroring the
   shape of `StereoHevcEncoder`.

4. **Contract extension** (`SpatialDataSink.kt`):
   * Bump `CONTRACT_VERSION` to 3.
   * Add `data class AudioStreamConfig(val sampleRateHz: Int, val
     channelCount: Int, val channelLayout: AudioChannelLayout, val
     csd: ByteArray)` where `AudioChannelLayout` is an enum
     `{ MONO, STEREO, AMBISONICS_FOA_ACN_SN3D, RAW_4CH }`.
   * Add `fun onAudioCsd(config: AudioStreamConfig)` and
     `fun onAudioPacket(data: ByteBuffer, ptsNs: Long, durationNs:
     Long, isKeyframe: Boolean)`. Default-no-op for v2 compat.
   * Add `audioExpected: Boolean` and `audioChannelLayout: Int` to
     `SessionConfig`.

5. **JNI writer** (`spatialmp4_writer_jni.cpp`):
   * Add `kTrackAudio = 7` and bump `kTimedTrackCount` accordingly.
   * On `nativeConfigureAudio`, allocate an `AVStream` of type
     `AVMEDIA_TYPE_AUDIO` with `AV_CODEC_ID_AAC` (`codec_tag = 0`
     so libavformat picks the right MP4 atom), `sample_rate`,
     `channels`, `ch_layout`, and CSD blob into `extradata`.
   * For ambisonic streams (`AMBISONICS_FOA_ACN_SN3D`), additionally
     write the Google `SA3D` (Spatial Audio metadata) box and the
     `SAND` (Spatial Audio Direction) marker on the audio track.
     The byte layout is documented in
     [Google's Spatial Media RFC](https://github.com/google/spatial-media/blob/master/docs/spatial-audio-rfc.md);
     copy the constants verbatim and unit-test against a known-good
     `gpac` / `MP4Box` output.
   * Add `nativeWriteAudioPacket(handle, payload, ptsUs, durationUs,
     flags)` mirroring `nativeWriteHevcPacket`.

6. **Muxer plugin** (`SpatialMp4MuxerPlugin.kt`):
   * Implement the new `onAudioCsd` / `onAudioPacket` contract methods.
   * Add `metricNativeWriteAudio: AtomicLong` and expose it in
     `popMuxerMetricsJson()`.
   * Honour `recordAudio` (mirror of `recordDepth`) gating.

7. **GDScript facade** (`SpatialMP4Writer.gd`):
   * Bump `EXPECTED_CONTRACT_VERSION` to 3.
   * Document that audio is provider-driven (no GDScript caller
     normally needs to push packets; provider's `AudioCapture`
     pipes them directly into `SpatialDataSink`).

8. **Session spool plumbing** (`session_spool_writer.gd`):
   * Add `record_audio` (default `false` for now, to avoid surprise
     mic access on existing builds) to `capture_options`.
   * Add an `audio` source entry to the manifest under
     `sources["audio"]` with the codec, sample rate, channel layout,
     and a `spatial_format` field (`"foa_acn_sn3d"` /
     `"stereo"` / `"mono"`).

## Trip-wires / open questions

* **PTS domain.** The contract is `godot_ticks_ns`
  (`SpatialDataSink.kt:261-264`). `MediaCodec`'s audio encoder emits
  `presentationTimeUs` in its own monotonic clock; the audio
  capture path must anchor that to Godot ticks at start-of-session
  the same way `StereoHevcEncoder` does, otherwise the audio track
  drifts against the video track during long captures. The
  anchoring fix-up is mechanical but must not be skipped — a
  one-frame slip is audible.
* **Mic-array layout.** The capture device's raw channels are
  *device-frame*, not head-frame. Beamforming to FOA needs the
  device-to-head extrinsic, which is platform-specific and not
  currently exposed by the codebase. For the MVP, document this as
  "FOA basis is approximate to the headset frame; per-device
  calibration is future work" and ship.
* **Sample rate.** 48 kHz is the safe default and what AAC-LC
  prefers; some Android devices expose 16 kHz only on the
  `UNPROCESSED` source. The session manifest must record the
  actual sample rate the device gave us, not the requested one.
* **Permission UX.** `RECORD_AUDIO` is a runtime permission. The
  current capture flow does not request runtime permissions
  interactively — it relies on pre-granted manifest entries. Adding
  audio means either pre-granting via `adb shell pm grant ...
  android.permission.RECORD_AUDIO` for dev builds, or implementing
  the Android runtime-permission dialog flow. Document which path
  ships and the operator workflow before merging.
* **Storage budget.** AAC-LC at 128 kbps stereo costs ~16 KB/s;
  FOA at 256 kbps costs ~32 KB/s. Both are negligible against the
  HEVC stream. No budget concern; flag only for completeness.
* **Privacy.** A teleoperation session that silently starts the
  microphone is a privacy footgun. The recording-cue beep
  (`capture_app.gd:706`) is already in place; consider whether
  audio capture should additionally surface a HUD indicator while
  recording. Not strictly an engineering requirement, but worth
  noting in the same PR.
* **Player compatibility.** ffmpeg `>= 6.0`, `MP4Box`, and Chrome's
  built-in `<video>` element all read the `SA3D` box correctly.
  QuickTime ignores it (plays the channels back as multi-channel
  PCM, not as ambisonic) — this is acceptable but document it in
  the SOP so reviewers don't think the recording is broken.

## Acceptance criteria for closure

* `permissions/record_audio=true` lands for Quest, Pico, and
  GlassXR exports; the APKs are confirmed to request and receive
  `RECORD_AUDIO` at runtime.
* A capture session started with `record_audio=true` produces an
  mp4 whose audio track plays back in `ffprobe` / `mpv` with the
  expected duration, sample rate, channel count, and no PTS-drift
  warnings ("Application provided invalid, non monotonically
  increasing dts" is a regression).
* For the FOA path, `ffprobe -show_streams` reports the
  `ambisonic_order=1` / `non_diegetic=0` `SA3D` side data; offline
  playback through a rotating ambisonic renderer (e.g. `IEM
  Plug-in Suite`'s `BinauralDecoder`) correctly tracks the head
  pose recorded in the head-pose track.
* The session manifest under `sources["audio"]` records the actual
  codec, sample rate, channel layout, and `spatial_format` string,
  matching the bytes written to the mp4.
* The contract version bump to 3 stays backward-compatible: a v2
  muxer paired with a v3 provider must still bind, with audio
  packets silently dropped (the default-no-op on `onAudioPacket`).
* `popMuxerMetricsJson` reports a non-zero `native_audio_writes`
  counter during a recording with audio enabled, and zero when it
  is disabled — proving the gate works in both directions.
* A short note in `claw/architecture/xr-client.md` documents the
  new audio stream alongside the existing RGB / depth / pose
  streams.
