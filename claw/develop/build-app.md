# Build & Install the XR App

How to build the Operator XR client APK and install it on a headset, and the
one non-obvious step that ego **depth** capture depends on.

All commands run from `xr/`.

## Prerequisites

- `godot` on `PATH`, version **4.5.1 stable** (matching the pinned engine).
- Matching **Android export templates** for 4.5.1 installed in Godot.
- **Android platform tools** (`adb`) on `PATH`.
- A real Android XR device connected over `adb` for install and runtime tests.
- For the patched depth build (see below): a working **Android SDK + NDK** so the
  vendor plugin's `./gradlew buildPlugin` can compile native code, plus `git`,
  `curl`, and `unzip`.

First-run and first Android export are slow (the export alone can take more than
10 minutes). Run long builds in the background when useful.

## Standard build (no ego depth)

This is enough for teleop, live feed, VR mode, and ego capture **without** depth.

```bash
cd xr
make deps            # once after clone, and after any checkout that bumps a pin

# Quest
make build-quest
make install-quest
make ship-quest      # build + install + launch

# PICO
make build-pico
make install-pico
make ship-pico
```

`build-*` runs `setup-vendors`, which calls
`addons/godotopenxrvendors/prepare.sh` in its **default (fetch) mode**. That mode
downloads the *official, unpatched* GodotVR OpenXR Vendors release binaries.

> [!IMPORTANT]
> The official binaries **cannot deliver environment depth to the CPU**. If you
> only run `make build-quest`, ego recordings with `record_depth: true` will
> capture RGB, pose, hands, body, and audio — but **no depth** — and the app will
> not surface a hard error. See the next section.

## Ego depth capture requires the patched vendor plugin

Environment depth (`XR_META_environment_depth`) on any runtime that advertises
the extension is read back from the GPU depth swapchain to the CPU, converted
to `u16` millimetres, and muxed into the SpatialMP4. This includes supported
Meta and PICO runtimes while keeping one APK per vendor build. The device model
is never used as the support signal. That readback only works with two local
patches to the OpenXR Vendors plugin, tracked in
`xr/addons/godotopenxrvendors/patches/`:

- `0001-meta-depth-callback-metadata.patch` — adds `near_z`, `far_z`, FOV,
  `runtime_display_time_ns`, and `local_from_depth_eye` to each depth callback.
- `0002-meta-vulkan-depth-readback.patch` — creates a readback texture with
  `TEXTURE_USAGE_CAN_COPY_FROM_BIT` and copies the depth swapchain into it so
  Godot can read the pixels. **Without this the depth `Image` comes back null on
  every frame.**

The default `prepare.sh` (and therefore plain `make build-quest`) does **not**
apply these patches. You must build the patched vendor binaries once, then build
the APK:

```bash
cd xr

# 1. Build the patched OpenXR Vendors plugin (clones the pinned upstream tag,
#    applies patches/*.patch, runs ./gradlew buildPlugin, syncs .bin/).
./addons/godotopenxrvendors/prepare.sh --build-patched

# 2. Confirm the patched markers are present in the Android binaries.
./addons/godotopenxrvendors/prepare.sh --check-patched

# 3. Build and install the APK as usual. setup-vendors is a no-op now that
#    .bin/ already holds the patched binaries. Both builds use the same patched
#    runtime capability probe and depth-frame contract.
make build-install-quest
make build-pico
make ship-quest
```

Notes:

- `--build-patched` verifies the checkout matches `UPSTREAM_COMMIT` in
  `addons/godotopenxrvendors/VERSION`, applies all `patches/*.patch`, then builds.
- Pass `--source /path/to/godot_openxr_vendors` to build from a local checkout
  instead of cloning, and `--keep-source` to keep the temporary build tree.
- The generated `.bin/` files are git-ignored; `VERSION` + the `patches/` are the
  reproducible state tracked in git. Re-run `--build-patched` after any checkout
  that changes either.

## Verify depth actually records

After installing a depth-capable build, record a short ego session with depth
enabled and watch logcat (`make log`):

```bash
cd xr && make log
```

Healthy signals:

- `DepthSampler bound ...` then `DepthSampler started ...`
- `QcMetrics` lines show `depth={callbacks=N, frames=M, ...}` with **`frames > 0`**
- `muxer={... native_depth_writes=K ...}` with **`native_depth_writes > 0`**

Failure signals (unpatched vendor plugin):

- Repeated `DepthSampler drop: null_image` with dict keys limited to
  `["depth_projection_view","depth_inverse_projection_view","image"]`
  (the patch-0001 metadata fields are absent).
- Godot errors:
  `Texture requires the RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT to be set to be retrieved`
  followed by `texture_2d_layer_get ... data.is_empty()`.
- `depth={... frames=0 ...}` and `native_depth_writes=0.0` for the whole session.

If you see the failure signals, the installed APK was built against the official
(unpatched) vendor binaries — rebuild via the patched flow above.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Depth missing from recording, `DepthSampler drop: null_image`, `CAN_COPY_FROM_BIT` errors | APK built with unpatched OpenXR Vendors binaries | `prepare.sh --build-patched`, then rebuild/reinstall the APK |
| `--check-patched` reports files missing | `.bin/` is empty or holds official binaries | Run `prepare.sh --build-patched` |
| `--build-patched` fails at `./gradlew buildPlugin` | Missing Android SDK/NDK or godot-cpp submodules | Install the Android toolchain; the script runs `git submodule update --init --recursive` for you |
| `expected <commit>, got <commit>` during build | Local `--source` checkout is off the pinned commit | Check out `UPSTREAM_COMMIT` from `addons/godotopenxrvendors/VERSION` |
| No depth callbacks at all (`callbacks=0`) while recording | Depth not enabled in capture options, or device does not support environment depth | Confirm `record_depth: true`; use a depth-capable headset (Quest 3 / 3S) |

## Do Not

- Do not ship an ego-depth build made with plain `make build-quest`; always run
  `--build-patched` (and `--check-patched`) first.
- Do not commit the generated `.bin/` binaries; only `VERSION` + `patches/` are
  tracked.
- Do not use desktop/headless Godot to validate depth capture — depth readback
  only exists on-device. Test on a real headset.
