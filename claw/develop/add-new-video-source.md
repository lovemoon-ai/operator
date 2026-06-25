# SOP: Add A New Teleop Video Source

This SOP covers video sources that should appear in the XR Teleop panel. Live
Feed server results use `live-pull` and are separate.

## Target Contract

The XR client expects timed H.264 packets delivered by `xr-bridge` over TCP or
UDP. Packet layout is documented in `claw/architecture/wire-protocol.md`.

XR-side consumers:

- `xr/scripts/app/modes/teleop_controller.gd`
- `xr/scripts/network/tcp_handler.gd`
- `xr/scripts/network/udp_video_handler.gd`
- `xr/scripts/ui/teleop_panel.gd`
- `xr/addons/live_video/live_video_view.gd`

Robot-side producers:

- `robot/crates/xr-bridge/src/video/`
- `robot/configs/*.yaml`
- `robot/configs/*descriptor*.yaml`

## Steps

1. Choose the source type.

   Examples: RTSP camera, USB/V4L2 camera, macOS AVFoundation camera, Python
   process that emits Annex-B H.264, or simulator camera.

2. Convert the source to Annex-B H.264 access units.

   `LiveVideoView` does not open RTSP or decode arbitrary containers. It
   accepts H.264 access units after the bridge normalizes the stream.

3. Add or configure the `xr-bridge` video source.

   Keep source-specific capture in `robot/crates/xr-bridge/src/video/`. The
   bridge should attach timing metadata and publish the same timed packet
   format as existing sources.

4. Update the device descriptor.

   Advertise the video feed transport:

   ```yaml
   video_feeds:
     - id: main
       codec: h264
       transport: auto
       port: 12345
       udp_port: 12345
   ```

   Use `transport: tcp` when the source must work over USB `adb reverse`.
   Use `transport: udp` only when UDP reachability is required and tested.

5. Verify XR transport selection.

   `teleop_controller.gd` chooses UDP when the descriptor has a usable
   `udp_port` and `transport` is `udp` or `auto`; otherwise it uses TCP.

6. Test on a real headset.

   ```bash
   bash cicd/01_rtsp_test.sh
   cd xr && make ship-quest
   cd xr && make ship-pico
   ```

   Watch logcat for video connection, packet receive, decoder, and presentation
   logs.

## Do Not

- Do not add source-specific code to `xr/scripts/ui/teleop_panel.gd`.
- Do not make `LiveVideoView` responsible for opening RTSP URLs.
- Do not bypass the timed packet format for one source.
- Do not test runtime behavior with desktop Godot.

## When Native Decode Changes Are Needed

Android decode and presentation belong in:

- `xr/addons/live_video/`
- `xr/android/build/src/com/godot/game/video/`
- `xr/native/ahb_decoder/`

If a source requires a new codec or packetization, add a bridge-side adapter or
a new Android/native decode path while preserving the `LiveVideoView` API where
possible.
