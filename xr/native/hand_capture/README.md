# hand_capture

Native joint-capture GDExtension for the Operator XR client. Three classes,
no GDScript fallback:

- `NativeOpenXRHandCapture` — runtime-independent Quest/PICO MP4 hand capture
  through `XR_EXT_hand_tracking` on an independent 60 Hz worker clock.
- `NativeHandSampler` — render-driven live hand JSON and optional
  `poses/hands.jsonl`; it is also the explicit MP4 fallback before the 60 Hz
  worker starts.
- `NativeBodyMotionWriter` — body joints + motion trackers (Meta/Godot
  XRBodyTracker sampling is native; PICO joints arrive from the
  pico_openxr bridge and are packed/serialized here). Replaces the old
  GDScript path that rebuilt 87 joints as nested Dictionaries and
  JSON.stringify'd the record twice per 30 Hz sample.

## Why

The old GDScript hand path in `pose_sampler.gd` built ~80 nested
Dictionaries per sample (26 joints x 2 hands) and ran `JSON.stringify` on
the main thread, which forced a 30 Hz throttle to protect 72 Hz rendering.
The extension owns the whole pipeline in C++ and fans out to every hand
consumer directly:

- ego capture: `NativeOpenXRHandCapture` owns separate hand trackers, calls
  `xrLocateHandJointsEXT` at 60 Hz independently of Godot rendering/camera
  delivery, packs HJNT v1, and writes the native SpatialMP4 metadata ABI;
- live push/feed: serializes the same joints to JSON and calls the live
  server plugin `writeHandJointsJson` (the exact wire shape the old
  `LivePushWriter` produced), rate-limited in C++ — default 30 Hz — to
  preserve the network bandwidth contract (`set_live_interval_us`),
- optional `poses/hands.jsonl` sidecar: render rate, serialized in C++ and
  flushed on a background writer thread so file I/O never blocks the
  render loop.

The live/sidecar joints JSON array is built at most once per hand per frame.
The MP4 worker never calls a Godot Object, Variant, or Android Java method on
its hot path.

When this extension is absent (desktop editor, headless tests) hands are
not recorded; `pose_sampler.gd` logs one warning. There is no hand-tracking
runtime in the desktop editor anyway.

## Build

```bash
ANDROID_NDK=... ./build.sh Release     # or: make -C xr build-hand-capture
```

Installs `libhand_capture.so` into `xr/addons/hand_capture/`, referenced by
`hand_capture.gdextension`. Android arm64-v8a only.
