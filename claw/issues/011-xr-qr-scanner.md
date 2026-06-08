# In-headset QR scanner for ingest URL setup

Status: open · scope-defined, partially implemented
Category: feature (XR client UX), tooling (Android plugin)
Spawned-from: user request, 2026-06-03

## Why this exists

Typing a URL like `http://192.168.1.42:3000/api/ingest` into a VR
text field with a controller laser is miserable. The web app's
`/connect` page (added in PR-4 of issue 010) already displays a QR
code per LAN IP — we just need the headset to decode it.

## What ships

A camera-button shortcut next to the **Upload URL** field in the Ego
capture-settings panel. Tap it → a fullscreen scanner overlay opens.
The headset's passthrough camera frames flow through ZXing on the
Android side. Detected QR codes appear as floating arrows in 3D space
(via the existing OpenXR composition layer pattern). Picking one
fills in the Upload URL and closes the overlay.

```
┌─ Ego capture settings ─────────────────────────────┐
│  Upload (optional)                                 │
│  ┌──────────────────────────────┐ ┌──┐             │
│  │ https://my-ingest.local:8443 │ │📷│ ← new button │
│  └──────────────────────────────┘ └──┘             │
│  ...                                               │
└────────────────────────────────────────────────────┘

   ⇣ camera button tapped

┌─ QR scanner overlay (passthrough) ─────────────────┐
│                                                    │
│         ◄─── arrow #1                              │
│              http://192.168.1.42:3000/api/ingest   │
│                                                    │
│                          ◄─── arrow #2             │
│                               http://10.0.0.5:…    │
│                                                    │
│              [pick arrow 1]  [pick arrow 2]  [×]   │
└────────────────────────────────────────────────────┘
```

## Architecture

```
                  ┌────────────────────────────────────────────┐
                  │  xr/scripts/view_locked_capture_panel.gd   │
                  │  ─ Upload URL LineEdit                     │
                  │  ─ 📷 button (new)  ─► emits scan_requested │
                  └────────────────────────────────────────────┘
                                       │
                                       ▼
                  ┌────────────────────────────────────────────┐
                  │  xr/scripts/capture_app.gd                 │
                  │  ─ Manages scanner overlay show/hide       │
                  │  ─ Routes detected payload → URL field     │
                  └────────────────────────────────────────────┘
                                       │
                                       ▼
                  ┌────────────────────────────────────────────┐
                  │  xr/scripts/ego_qr_scanner.gd              │
                  │  ─ OpenXRCompositionLayer passthrough quad │
                  │  ─ Reads detections from Kotlin plugin     │
                  │  ─ Renders 3D arrows + accept/cancel       │
                  └────────────────────────────────────────────┘
                                       │  signal
                                       ▼
                  ┌────────────────────────────────────────────┐
                  │  xr/addons/qr_scanner/qr_scanner.gd        │
                  │  ─ Thin wrapper around the singleton       │
                  │  ─ Detects plugin presence, falls back     │
                  │    gracefully on non-Android targets       │
                  └────────────────────────────────────────────┘
                                       │  JNI
                                       ▼
                  ┌────────────────────────────────────────────┐
                  │  xr/android_plugin/qrscanner/              │
                  │  ─ Kotlin GodotPlugin singleton            │
                  │  ─ Camera2 capture loop @ 15 fps           │
                  │  ─ ZXing decode per frame                  │
                  │  ─ Emits qr_detected(payload, bounds)      │
                  └────────────────────────────────────────────┘
```

## Why a separate plugin (not piggy-back on QuestCapturePlugin)

QuestCapturePlugin is the hot path for ego recording — RGB stereo at
30 fps, HEVC encode, depth, pose, all coalesced into a single MP4.
Hijacking it for QR scanning would:

1. Couple two unrelated lifecycles (one starts/stops at "Save", the
   other at "tap 📷").
2. Force the scan to run at the recording bitrate / camera config,
   when a lower 15 fps mono feed is plenty for ZXing.
3. Make the scanner unusable on Quest builds where QuestCapture isn't
   linked.

A separate plugin (`qr_scanner`) keeps responsibility local: it owns
its own Camera2 session, runs only while the overlay is visible, and
releases the camera the moment the user dismisses the scanner.

## Why ZXing (not MLKit or zbar)

| Library | Pros | Cons |
|---------|------|------|
| **ZXing (core + android-embedded)** | Apache-2.0, mature, ~250 KB AAR, no Google Play Services dep | Pure Java decode is CPU-bound — fine at 15 fps on Snapdragon XR2 |
| MLKit Barcode | Faster on-device ML, free | Bundles Google Play Services which Pico devices don't reliably ship |
| zbar | Tiny C library, very fast | C build pipeline; not great with Android Camera2 YUV; abandoned upstream |

ZXing's Java + Camera2 path is well-trodden and avoids a vendor lock.

## Multi-result UX

Reality check: when the user looks at the Mac running `/connect`,
**two QRs are typically visible** (Wi-Fi en0 + Wi-Fi en1, or
Wi-Fi + Ethernet utun). The naive "pick the first detection" is
wrong because:

- "First" depends on ZXing's internal scan order, which is unstable.
- Frame N might detect both; frame N+1 might detect only one.

The scanner overlay shows an arrow in 3D space at each detection's
on-screen center for as long as ZXing keeps reporting it
(detection persistence: ~500 ms after last sighting). The user
points the controller at one and pulls trigger. The picked payload
goes back to the URL field.

If exactly one QR is in view, the overlay still requires a confirm
tap (avoids accidentally scanning whatever the user looks at first,
which might be the wrong code if there are old browser tabs lying
around).

## Camera permission

`CAMERA` is already requested by the QuestCapture pipeline. The
scanner plugin re-requests via the same flow if it lands on a Quest
that hasn't been through ego recording yet:

```kotlin
ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA)
ActivityCompat.requestPermissions(activity, arrayOf(CAMERA), REQUEST_CODE)
```

The Godot side polls `hasCameraPermission()` once a frame while the
overlay is open; if false after 5 s, the overlay shows a "grant
permission" hint and stays open until the user either grants or
cancels.

## Scope

In:
- Camera button in capture panel
- Scanner overlay (composition layer + passthrough)
- Kotlin plugin: Camera2 + ZXing
- Multi-result arrows
- Wire detected payload → upload URL field
- Settings persistence (already in place via BaseSettingsPanel)

Out of scope (deferred):
- iOS / AVP support (would need AVFoundation port)
- Non-URL QR payloads (we trust ZXing's text; no schema validation)
- Showing previous successful URLs as quick-pick chips
- Reading other 2D codes (Data Matrix, Aztec) — easy to add later via
  ZXing's `MultiFormatReader`

## Build wiring

A new `xr/android_plugin/qrscanner/` Gradle module ships an AAR; the
Makefile's `prepare-capture-plugins` target ships it next to the
existing `questcapture` and `spatialmp4_muxer` AARs so the export
process picks it up automatically.

## Acceptance criteria

- Tap 📷 next to Upload URL → scanner opens within ~200 ms.
- Point at the Mac running `npm run dev` (web app `/connect` page) →
  a single arrow appears within ~1 s, labelled with the URL.
- Pull controller trigger while pointing at an arrow → URL fills,
  overlay closes, settings persist.
- Two QRs visible → both arrows render; pulling trigger on one wins.
- Cancel button (or controller B) closes the overlay without
  modifying the URL.
- On non-Android targets (editor / macOS dev build) the camera button
  is hidden (or shows a "not available on this platform" toast).
