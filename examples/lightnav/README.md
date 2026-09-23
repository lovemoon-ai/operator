# LightNav

A navigation host in ~200 lines: it asks the headset for a camera and head
poses, receives them on its own session, and draws the walked route back into
the headset. No APK change, no ingest server, no new mode.

This is the worked example of host-declared composition
(`claw/architecture/overview.md`, "Host-declared Composition"):

| Layer | What LightNav does |
| --- | --- |
| Declaration | `BridgeConfig(capture_streams=…)`: 4 Hz left-eye `rgb.hevc`, `head_pose.json`, optionally a local `record` task. Upper limits only — the envelope the user grants. |
| Permission | The headset asks the user once per (host address, declaration). A denial changes `StreamsStatus`, never the session. |
| Capability | The headset mounts its own `CameraSource` → `LivePushSink`; LightNav never names a codec, a port or a token. |
| Session | Granted media arrives on the host session's media channel: `xr.capture.frames()`. |
| Rendering | Blueprint `path` + `marker` + `label`, bound to state values published at 5 Hz. |
| In-session control | `xr.streams_control({"rgb.hevc": {"hz": 1}})` while the operator stands still — inside the envelope, so the user is not asked again. |

## Run

With a headset, from the repository root:

```bash
python examples/lightnav/main.py            # add --record to also record on the headset
```

Then connect Operator XR's Teleop mode to this host (the headset finds it by
discovery, or enter the address in Teleop settings). Grant the capture request
when it appears. Over USB, forward the session ports first:

```bash
adb reverse tcp:63901 tcp:63901   # ctrl
adb reverse tcp:63905 tcp:63905   # media_up  (headset -> host)
adb reverse tcp:63906 tcp:63906   # media_down (host -> headset)
```

Without a headset, the navigator runs against a synthetic walk:

```bash
python examples/lightnav/main.py --replay
```

## What to watch

- `StreamsStatus:` lines print the headset's answer — which streams are
  `active` / `denied`, and `reason: limit` when a value was clipped to the
  envelope.
- An old APK (no `capture_streams_v1`) reports every stream
  `denied` / `unsupported`; the Blueprint route still renders.
- Stopping and walking again switches the declared camera between 1 Hz and
  4 Hz without a new prompt.
- `rgb.hevc` is not `required`: denying the camera leaves head poses, the
  route and the session intact.
