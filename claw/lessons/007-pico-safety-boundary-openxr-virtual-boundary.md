# PICO Safety Boundary via XR_PICO_virtual_boundary

Date: 2026-08-27

## Bug

The PICO safety boundary (安全区) stayed visible in every Operator mode, while
Quest headsets already suppressed theirs. A first attempt to close the gap
loaded PICO's Native SDK entrypoints at runtime:

```cpp
pxr_platform_handle = dlopen("libPxrPlatform.so", RTLD_NOW | RTLD_LOCAL);
pxr_set_guardian_system_disable = dlsym(pxr_platform_handle, "Pxr_SetGuardianSystemDisable");
pxr_set_boundary_visible        = dlsym(pxr_platform_handle, "Pxr_SetBoundaryVisible");
```

That approach could never have worked on device, and it also broke the PICO
export by requiring a `PxrPlatform.aar` that was never fetched.

## Cause

Three separate mistakes stacked up:

- `Pxr_SetGuardianSystemDisable` and `Pxr_SetBoundaryVisible` are not in
  `libPxrPlatform.so`. They live in `libpxr_api.so` (`PXR_API_DLL = "pxr_api"`).
- Neither library exists anywhere on the device filesystem, so no `dlopen` of a
  system copy can succeed. The blob would have to ship inside the APK.
- Even bundled, `libpxr_api.so` only dispatches through the PICO XR plugin's
  `VrDriver` function table. Under Godot's generic OpenXR loader that table is
  never initialized, so the call is a no-op at best.

The neighbouring assumption was wrong too: a code comment claimed "the Pico
runtime already suppresses its safe zone while in passthrough". It does not.
Passthrough (`XR_ENV_BLEND_MODE_ALPHA_BLEND`) and the guardian are independent.

## Fix

PICO's OpenXR runtime advertises `XR_PICO_virtual_boundary`, which has
*writable* entrypoints reachable through plain `xrGetInstanceProcAddr` — no
PICO library linked, no AAR bundled, no Enterprise ToB service:

```c
XrResult xrSetVirtualBoundaryEnablePICO(XrSession session, XrBool32 enable);
XrResult xrSetVirtualBoundaryVisiblePICO(XrSession session, XrBool32 visible);
XrResult xrSetVirtualBoundarySeeThroughVisiblePICO(XrSession session, XrBool32 visible);
```

Passing `XR_FALSE` to `xrSetVirtualBoundaryEnablePICO` is what the runtime
forwards to its internal guardian IPC as `ipc_guardian_guardiansystem_set_disable`.
Treat that call as required and the two visibility setters as best effort, so a
runtime shipping only a subset still turns the boundary off.

Disabling in *every* mode is a policy concern, not a per-mode patch:

- `PicoOpenXRExtension::_on_session_created` calls `set_boundary_visible(false)`.
  Operator runs one XR session across all modes, so this single call covers
  launcher, teleop, and capture.
- The `XRSessionPolicy` autoload re-applies the policy on `session_begun` and
  `session_focussed` through `PlatformRegistry`, which fans out to the PICO and
  Quest adapters and aggregates the outcome worst-wins across
  `not_applicable` / `applied` / `partial` / `failed`.
- Quest needs no runtime call at all. Its guardian is suppressed at install
  time by the `com.oculus.feature.BOUNDARYLESS_APP` manifest feature, injected
  with `android:required="true"` by
  `addons/quest_capture_android/export_plugin.gd`. The pinned vendor plugin
  (upstream_tag `4.3.1-stable`) ships no `XR_META_boundary_visibility` wrapper —
  `strings libgodotopenxrvendors.so` yields zero hits for `BoundaryVisibility`,
  and no `meta/boundary_visibility` setting is registered. The Quest adapter
  therefore reports `not_applicable`, which the policy logs at info level; it
  only probes for the singleton as an optional future upgrade path.

Do not reach for PICO Enterprise's `SwitchSystemFunction(SFS_SECURITY_ZONE_PERMANENTLY, S_OFF)`.
It flips a device-wide, permanent switch that outlives the app and leaves other
applications without a boundary. The OpenXR route is session-scoped and reverts
on its own — verified by `persist.pvr.showsafety.tip` remaining `1` after a run.

## Diagnosis

PICO publishes no header for this extension. The prototypes were recovered from
the device itself:

```bash
adb pull /product/priv-app/XRRuntime/XRRuntime.apk
unzip -o XRRuntime.apk -d x
strings -a x/lib/arm64-v8a/libpxrruntime.so | grep -i virtualboundary
strings -a x/lib/arm64-v8a/libpxrruntime.so | grep -E '^XR_PICO_[a-z_]+$'
```

Two traps make a naive search miss these functions:

- The runtime is Monado-derived, so implementations carry an `oxr_` prefix.
  Searching for `xrSetBoundary*` finds only the read-only `XR_PICO_boundary`
  calls (`xrGetBoundaryDimensionsPICO`, `xrBoundaryTestPointPICO`, …). The
  setters are named `xrSet*VirtualBoundary*PICO`.
- The public dispatch name is *tail-merged* into the `oxr_`-prefixed literal, so
  `grep -c xrSetVirtualBoundaryEnablePICO` returns 1, not 2. The string at
  offset +4 is what `xrGetInstanceProcAddr` compares against.

Signatures were confirmed by disassembly (`llvm-objdump` from the NDK; system
`objdump` lacks aarch64 support). Each implementation opens with
`mov x19, x0` / `mov w20, w1`, then validates `x0` against Monado's `"oxrsess"`
handle magic — proving `(XrSession, XrBool32)`. The `cset w2, eq` at the tail of
`xrSetVirtualBoundaryEnablePICO` shows the argument is *inverted* before being
handed to the guardian IPC, i.e. `enable=XR_FALSE` means "disable = true".

## Validation

Built and installed on PICO 4 Ultra Enterprise (`A9210`, `PA9410MGL5160902G`)
with `adb install --no-incremental`. Runtime log:

```text
PicoOpenXRExtension requested OpenXR extensions: [..., "XR_PICO_virtual_boundary"]
PicoOpenXRExtension instance created; ... XR_PICO_virtual_boundary=true
Operator-PicoBoundary: PICO safety boundary visible=false (enable+visible+see_through all applied)
[Operator] XR safety boundary disabled (pico: XR_PICO_virtual_boundary applied)
```

All three setters returned `XR_SUCCESS`, the guardian service reported
`BoundaryInfo::mpBoundary is null`, and the boundary was confirmed gone
in-headset. `validate_xr_features.py` and `validate_xr_test_manifests.py`
passed.

One measurement was misleading and should not be reused: the guardian's
`sumbit [N] layers` counters stay frozen whether or not the boundary is
disabled, because they only advance when the user actually approaches it. They
are not evidence of suppression.

## Reusable Rule

Before bundling a vendor's proprietary `.so` to reach a device feature, check
whether the OpenXR runtime already exposes it as an extension — pull the runtime
APK and read its strings. A vendor SDK entrypoint that dispatches through that
vendor's own engine plugin will not work under Godot's generic OpenXR loader,
however it is loaded.

When a feature must hold "in every mode", implement it once at session scope and
re-apply on session lifecycle signals. Do not scatter per-mode calls, and do not
assume an unrelated feature (passthrough) implies it.
