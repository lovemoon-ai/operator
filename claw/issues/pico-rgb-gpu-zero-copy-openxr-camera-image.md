# Pico RGB native camera-to-codec path

## Status

Implemented for the current raw-buffer form of `XR_PICO_camera_image`.

The native camera and shared hand workers do not call Godot or Java on their
hot paths:

- a camera worker acquires both OpenXR images, uploads the runtime RGBA pointer
  directly into reusable GLES textures, composes stereo side-by-side, and
  encodes through an NDK `MediaCodec` input Surface;
- `native/hand_capture` owns separate `XR_EXT_hand_tracking` trackers and calls
  `xrLocateHandJointsEXT` on a 16.667 ms schedule, independently of Godot
  rendering and camera delivery; the same implementation runs on Quest;
- compressed RGB packets, frame-index metadata, and HJNT payloads enter the
  SpatialMP4 writer through a native C ABI. No `PackedByteArray`, Godot
  `Variant`, JNI `ByteArray`, or Kotlin per-frame callback is involved. Codec
  output makes one required ownership copy into the asynchronous mux queue;
  the previous temporary-vector second copy has also been removed.

The normal PICO RGBA8888 layout has no CPU staging copy. A reusable native
staging buffer remains as a correctness fallback for non-four-byte pixel
strides or row layouts that GLES cannot consume directly. The raw OpenXR
pointer still has to be uploaded into a GPU texture; the current PICO extension
does not expose a GPU-importable image or `AHardwareBuffer`, so this is not a
literal end-to-end zero-copy path.

## Device result (PICO 4 Ultra, 1280x960 stereo)

- Final MP4 duration: 12.923 seconds.
- Left/right RGB frame-index samples: 464 each.
- Encoded stereo frames: 464, about 35.9 fps over the file timeline.
- Java camera/encoder counters: zero.
- Native RGBA staging copies: zero.
- Native camera drops: zero.
- Native hand locate calls: 60-62 per second per hand with zero locate errors.
- Godot main-thread camera stage (diagnostic polling only): about 3-5 ms per
  second.

The unattended test had no visible hands, so the runtime reported
`isActive=false` and no HJNT packets were expected. The 60 Hz query counters
verify scheduling/decoupling without treating inactive samples as hand data.

A subsequent hand-visible recording (`20260716_093036.mp4`) verified the
written metadata path itself:

- right-hand HJNT packets / unique timestamps: 435;
- hand timestamp span: 7.233478 seconds;
- effective written rate: 59.999 Hz;
- dt median / p90 / maximum: 16.663 / 17.491 / 38.638 ms;
- right-hand writes matched the 60-62 per-second locate count with zero locate
  errors;
- RGB-to-nearest-hand timestamp delta was about 4.2 ms mean and 14.6 ms max.
  The left hand was not visible and correctly produced no track.

The encoder presents session-relative timestamps to Qualcomm MediaCodec and
maps output PTS back to the absolute Godot/OpenXR clock before muxing. The MP4
timeline origin is frozen once its header is written, so a late packet from an
independent producer cannot shift the base and collapse later PTS values.

## Remaining work

- Prefer a vendor-supported texture, `AHardwareBuffer`, or other GPU-importable
  handle if PICO exposes one in a newer SDK/runtime.
- Profile 640x480 and the largest supported 4:3 mode, including sustained
  thermals; 1280x960 stereo is the verified mode.

## Acceptance

- Pico OpenXR RGB recording does not invoke Kotlin per-pixel RGBA -> YUV
  conversion at any resolution.
- The OpenXR frame pump performs no acquire, copy, upload, or encode work on
  the Godot main thread; GDScript only drains small diagnostic counters.
- 640x480, 1280x960, and the largest supported 4:3 Pico mode are profiled on
  device with encoded RGB FPS, frame gaps, CPU load, and thermals.
