# Build and Deploy Reference

A consolidated reference for every build / install / deploy / smoke-test
loop in this repo. Each section starts with a "When to use this" hint so
you can find the right command without spelunking three Makefiles.

The commands are quoted verbatim from the source Makefiles / shell
scripts so they stay copy-pasteable. Line citations point at the
authoritative source.

---

## 1. Toolchain prerequisites

> When to use this: first-time setup on a new machine, or to diagnose a
> "command not found" / "version too old" error.

The repo doesn't ship a single setup script. The versions below are
either pinned by source files or implied by language features in use.

| Tool                       | Version / Notes                                                                                                         | Where cited                                                                                |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Rust toolchain (`cargo`)   | Stable, **≥ 1.56** (Rust 2021 edition).                                                                                 | `robot/Cargo.toml:4` — `edition = "2021"`                                                  |
| `cross`                    | Any recent release that supports the `aarch64-unknown-linux-gnu:main` image.                                            | `robot/Cross.toml:1-2`                                                                     |
| Cross container images     | `ghcr.io/cross-rs/aarch64-unknown-linux-gnu:main` (Pi 4/5 / aarch64), `ghcr.io/cross-rs/armv7-unknown-linux-gnueabihf:main` (Pi 3 / armhf). Docker or Podman daemon required. | `robot/Cross.toml:1-5`                                                                     |
| Godot Engine               | **4.5**, mobile renderer. The export templates pin **4.5.1.stable**.                                                    | `xr/project.godot:15` (`"4.5", "Mobile"`), `xr/project.godot:37` (`"mobile"`), `xr/Makefile:11` (`TEMPLATE_ZIPS=4.5.1.stable`) |
| Godot export templates     | `4.5.1.stable/android_source.zip` — searched at `~/Library/Application Support/Godot/export_templates/4.5.1.stable/android_source.zip` (macOS) and `~/.local/share/godot/export_templates/4.5.1.stable/android_source.zip` (Linux). | `xr/Makefile:11`, `xr/Makefile:23-35`                                                      |
| Android NDK                | **r25+** with API level 29+ headers (needs `VkAndroidHardwareBufferPropertiesANDROID`). `ANDROID_NDK` or `ANDROID_NDK_HOME` env var must point at it. | `xr/native/ahb_decoder/build.sh:7-26`, `xr/native/ahb_decoder/CMakeLists.txt:22-24`         |
| `adb`                      | Any recent Android Platform Tools. Used by every `xr/Makefile` deploy target.                                            | `xr/Makefile:3`                                                                            |
| `cmake`                    | **≥ 3.22** (project's minimum required).                                                                                | `xr/native/ahb_decoder/CMakeLists.txt:1`                                                   |
| `uv`                       | Any recent release. Required for the MuJoCo example env setup; the Makefile errors out with an install hint if missing. | `examples/mujuco-arm-so101/Makefile:33-39`                                                 |
| Python                     | **3.11** by default for the MuJoCo example (`PYTHON_VERSION ?= 3.11`).                                                  | `examples/mujuco-arm-so101/Makefile:12`                                                    |
| Gradle                     | Bundled by the Godot Android template; the build uses a project-local gradle cache.                                     | `xr/Makefile:4`, `xr/Makefile:20`                                                          |
| `ffmpeg`                   | Required at runtime on macOS for the camera capture pipeline (AVFoundation input). Not built; assumed on `$PATH`.        | `robot/Makefile:21-32` (comment block)                                                     |

A working Linux/V4L2 stack is **not** needed on macOS — see
section 2 for why the v4l/nix/libc crates are gated to Linux only.

---

## 2. Rust agent (`robot/`)

> When to use this: building or running the robot-side agent on macOS
> (smoke test) or cross-compiling for a Raspberry Pi target.

### 2.1 Why the Linux-only deps

`robot/Cargo.toml:51-55` gates `v4l`, `nix`, and `libc` behind
`cfg(target_os = "linux")`:

```
[target.'cfg(target_os = "linux")'.dependencies]
v4l = "0.14"
nix = { version = "0.29", features = ["ioctl", "mman", "fs"] }
libc = "0.2"
```

These crates wrap the Linux V4L2 ioctl interface plus mmap/raw-fd
helpers used by the V4L2 capture path. macOS has no V4L2, so on a Mac
the agent falls through to the AVFoundation `ffmpeg` capture path
(`robot/src/video/ffmpeg.rs`) and never touches these crates. Skipping
the gate would make `cargo build` fail on macOS with link errors
against `libv4l2`.

### 2.2 Local build

> When to use this: building the agent for the host you're sitting in
> front of (typically macOS dev or Linux dev).

```
cargo build --release
```

`robot/Makefile:4-5`. `[profile.release]` in `robot/Cargo.toml:61-66`
enables `lto = true`, `codegen-units = 1`, `strip = true`,
`panic = "abort"`. The release binary is required for camera capture —
the comment at `robot/Makefile:30-32` notes that the debug binary's
CPU YUV path "tops the encoder out and starves the framerate".

### 2.3 Cross-compile to Raspberry Pi (aarch64)

> When to use this: producing a binary for a 64-bit Pi (Pi 4 / Pi 5 /
> any aarch64 SBC).

```
cross build --release --target aarch64-unknown-linux-gnu
```

`robot/Makefile:8-9`. `cross` selects the container image from
`robot/Cross.toml:1-2`
(`ghcr.io/cross-rs/aarch64-unknown-linux-gnu:main`). The armv7 image
is declared at `robot/Cross.toml:4-5` for Pi 3 / armhf, but no
Makefile target invokes it — you'd run
`cross build --release --target armv7-unknown-linux-gnueabihf` by
hand.

### 2.4 Deploy to a Pi over SSH

> When to use this: shipping the freshly-cross-compiled binary to a Pi.

```
scp target/aarch64-unknown-linux-gnu/release/robo-agent $(RPI_HOST):~/
ssh $(RPI_HOST) mkdir -p ~/config
scp config/default.yaml $(RPI_HOST):~/config/
```

`robot/Makefile:12-15`. Pass the host with `make deploy RPI_HOST=pi@raspberrypi.local`.
The target does not restart any service; you start the agent manually
on the Pi (e.g. via `ssh $RPI_HOST ./robo-agent --config ~/config/default.yaml`).

### 2.5 Dev run

> When to use this: iterating on the agent with debug logs.

```
RUST_LOG=robo_agent=debug cargo run -- --config config/default.yaml
```

`robot/Makefile:18-19`. Builds in debug mode; do **not** use for
camera capture (see 2.2).

### 2.6 macOS smoke-test loop — `run-mac-local-camera`

> When to use this: feeding the Mac's built-in FaceTime HD camera into
> the agent so a paired headset can pull live video over the configured
> TCP ports.

```
RUST_LOG=robo_agent=info,robo_agent::video=debug \
    ./target/release/robo-agent --config config/default.yaml 2>&1 | \
    tee /tmp/robo-agent.log
```

`robot/Makefile:41-59`. The full target depends on a release build and
includes pre-flight teardown:

1. Refuses to run if `uname -s != Darwin` (lines 42-45).
2. Kills any lingering `target/release/robo-agent` or
   `target/debug/robo-agent` processes (lines 47-48). If you skip this,
   you'll see `Address already in use (os error 48)` on the pose,
   video, or discovery ports.
3. For each port (`63900`, `63901`, `12345`), runs `lsof -ti tcp:$port
   -ti udp:$port` and `kill -9`s the holders (lines 49-55). Catches the
   case where an unrelated process — typically a leftover `ffmpeg` from
   a crashed run — grabbed the port.
4. `sleep 1` (line 56). Comment at lines 39-40: "gives the kernel a
   moment to release TIME_WAIT state on the listeners". Skipping it
   intermittently re-trips error 48 even after the kills succeed.

`config/default.yaml` ships with `device: "/dev/video0"`; the macOS
code path in `robot/src/video/ffmpeg.rs` (`platform_input`)
auto-rewrites that to AVFoundation index `"0"`, so no separate config
file is needed.

The combined stdout+stderr is tee'd to `/tmp/robo-agent.log` so the
headset side can `tail -f /tmp/robo-agent.log` from a separate shell,
and so a crashing run leaves a postmortem behind.

### 2.7 macOS smoke-test loop — `run-mac-local-camera-bg`

> When to use this: invoking the robot from inside VSCode / Cursor /
> Conductor / any non-Terminal.app shell where camera permission
> doesn't work.

```
open -a Terminal /tmp/run_robot.command
```

`robot/Makefile:82-102`. Generates `/tmp/run_robot.command` (a `.command`
file so Finder will also open it in Terminal.app on double-click) and
launches it via `open -a Terminal`.

**Why this exists, verbatim from the Makefile comment (lines 61-75):**

> macOS TCC walks the process tree to find the "responsible" GUI app,
> so AVFoundation's permission gate looks at *that* app, not at ffmpeg.
> Conductor is not a registered TCC client for camera, so the prompt
> never appears and ffmpeg silently hangs inside AVFoundation init
> forever (you see the "Selected pixel format (yuv420p) is not
> supported... Overriding to uyvy422" warning and then nothing — no
> Video: stats line, ever).
>
> Re-routing through Terminal.app fixes that: Terminal *is* a known TCC
> client, the prompt is attached to it, and once granted the permission
> persists across launches.

Practical consequence: if you call `make run-mac-local-camera` from
inside Cursor's embedded terminal, ffmpeg appears to start, prints one
override warning, and then never logs another frame. Use
`run-mac-local-camera-bg` instead, grant Camera to Terminal once, and
you're done.

### 2.8 Tailing the log

```
tail -f /tmp/robo-agent.log
```

The log path is hard-coded in `robot/Makefile:59` (and reprinted by
`run-mac-local-camera-bg` at line 102).

### 2.9 Tests / binary size

```
cargo test
ls -lh target/release/robo-agent
```

`robot/Makefile:105-106` and `robot/Makefile:109-110`.

---

## 3. XR client (Godot, `xr/`)

> When to use this: building an APK for a headset.

The Godot project (`xr/project.godot`) is Godot 4.5 with the **mobile**
renderer, OpenXR enabled. Three export presets are declared in
`xr/export_presets.cfg`; each produces an APK at a distinct path.

### 3.1 Export presets summary

| Preset (`name=`) | APK path                          | OpenXR plugin                                     | Vendor support              | `runnable` |
| ---------------- | --------------------------------- | ------------------------------------------------- | --------------------------- | ---------- |
| `Meta Quest`     | `build/quest/XRoboToolkit.apk`    | `GodotOpenXRMeta=true` (`export_presets.cfg:255`) | Quest 2/3/Pro (`:246-248`)  | `true`     |
| `Pico`           | `build/pico/XRoboToolkit.apk`     | `GodotOpenXRPico=true` (`export_presets.cfg:519`) | Pico (`:512`)               | `false`    |
| `Glass XR`       | `build/glassxr/XRoboToolkit.apk`  | `GodotOpenXRKHR=true` (`export_presets.cfg:779`)  | Khronos generic (`:753`)    | `false`    |

All three presets share: `package/unique_name="org.xrobotoolkit.client"`,
`arm64-v8a` only, signed with the in-repo `res://android/debug.keystore`,
`permissions/camera=true`, `permissions/internet=true`,
`xr_features/xr_mode=1` (immersive).

Meta-specific differences: hand tracking on (`meta_xr_features/hand_tracking=1`,
`:237`), passthrough on (`:239`), render model on (`:240`). The Pico
preset disables Meta's hand tracking (`:500`) and uses Pico's plugin
instead. Glass XR turns off all vendor-specific features and uses only
the generic OpenXR (KHR) plugin (`:760-789`).

### 3.2 Build targets

> When to use this: producing an APK from CLI / CI without opening the
> Godot editor.

```
build-quest: prepare-android-libs
	@mkdir -p $(dir $(apk)) $(GRADLE_USER_HOME)
	GRADLE_USER_HOME=$(GRADLE_USER_HOME) godot --headless --verbose --path . --export-release "Meta Quest" $(apk)

build-pico: prepare-android-libs
	@mkdir -p $(dir $(apk_pico)) $(GRADLE_USER_HOME)
	GRADLE_USER_HOME=$(GRADLE_USER_HOME) godot --headless --verbose --path . --export-release "Pico" $(apk_pico)

build-glassxr: prepare-android-libs
	@mkdir -p $(dir $(apk_glassxr)) $(GRADLE_USER_HOME)
	GRADLE_USER_HOME=$(GRADLE_USER_HOME) godot --headless --verbose --path . --export-release "Glass XR" $(apk_glassxr)
```

`xr/Makefile:37-47`. `build` (line 49) is an alias for `build-quest`.

### 3.3 `prepare-android-libs` — AAR extraction

> When to use this: implicitly, before any APK build. The other build
> targets depend on it.

```
prepare-android-libs:
	@set -e; \
	LIB_DEBUG="android/build/libs/debug/godot-lib.template_debug.aar"; \
	LIB_RELEASE="android/build/libs/release/godot-lib.template_release.aar"; \
	if [ -f $$LIB_DEBUG ] && [ -f $$LIB_RELEASE ]; then exit 0; fi; \
	for ZIP in $(TEMPLATE_ZIPS); do \
		if [ -f "$$ZIP" ]; then TEMPLATE_ZIP="$$ZIP"; break; fi; \
	done; \
	if [ -z "$$TEMPLATE_ZIP" ]; then echo "Missing Android template zip (4.5.1.stable). Install export templates in Godot."; exit 1; fi; \
	echo "Extracting Godot Android template AARs from $$TEMPLATE_ZIP"; \
	mkdir -p android/build/libs/debug android/build/libs/release; \
	unzip -o "$$TEMPLATE_ZIP" "libs/debug/godot-lib.*.aar" -d android/build >/dev/null; \
	unzip -o "$$TEMPLATE_ZIP" "libs/release/godot-lib.*.aar" -d android/build >/dev/null
```

`xr/Makefile:23-35`. Searches `TEMPLATE_ZIPS`
(`xr/Makefile:11`) in order:

1. `$HOME/Library/Application Support/Godot/export_templates/4.5.1.stable/android_source.zip` (macOS install layout)
2. `$HOME/.local/share/godot/export_templates/4.5.1.stable/android_source.zip` (Linux / Flatpak layout)

If neither exists, the build aborts with "Missing Android template zip
(4.5.1.stable). Install export templates in Godot." Fix:
**Godot editor → Editor → Manage Export Templates → Download for the
4.5.1.stable version.**

Idempotent: if both AARs are already extracted into
`android/build/libs/{debug,release}/`, the rule short-circuits.

### 3.4 Why `GRADLE_USER_HOME` is pinned local

```
GRADLE_USER_HOME?=$(CURDIR)/.gradle
```

`xr/Makefile:4`. Every build target re-exports this so gradle's cache,
wrapper distributions, and lock files all land under `xr/.gradle/`
instead of `~/.gradle/`. The build targets explicitly `mkdir -p
$(GRADLE_USER_HOME)` before invoking godot (lines 38, 42, 46).

Practical consequence: the gradle cache is project-scoped — you can
nuke `xr/.gradle/` and `xr/android/build/` without disturbing other
gradle projects on the machine, and your global `~/.gradle/` doesn't
get polluted with the project's Android SDK pins.

### 3.5 Install / run / stop / clean / uninstall

> When to use this: pushing an already-built APK onto the connected
> device, or doing routine lifecycle housekeeping.

```
install:
	$(ADB) install -r -d $(apk)

install-pico:
	$(ADB) install -r -d $(apk_pico)

install-glassxr:
	$(ADB) install -r -d $(apk_glassxr)

uninstall:
	$(ADB) uninstall $(package)

run:
	$(ADB) shell am start -n $(package)/$(activity)
	$(ADB) logcat -c | $(ADB) logcat | grep -e "XRoboToolkit" -e "godot" -e "OpenXR"

stop:
	$(ADB) shell am force-stop $(package)

build-install:      build install
build-install-pico: build-pico install-pico

clean:
	cd android/build && ./gradlew clean
	rm -rf build
```

`xr/Makefile:51-72`, `xr/Makefile:19-21`. Constants:

- `package = org.xrobotoolkit.client` (`xr/Makefile:9`)
- `activity = com.godot.game.GodotApp` (`xr/Makefile:10`)

`-r -d` on `adb install` means "reinstall, allow downgrade" — useful
when iterating without bumping `version/code`.

### 3.6 `log` / `crash`

```
log:
	$(ADB) logcat -c | $(ADB) logcat | grep -e "XRoboToolkit" -e "godot" -e "OpenXR"

crash:
	$(ADB) logcat -d > crash.log
```

`xr/Makefile:13-17`. `log` clears logcat then live-tails, filtered;
`crash` dumps the current ring buffer to `crash.log` for postmortem.

### 3.7 Open the project in the Godot editor

```
godot:
	godot -e .
```

`xr/Makefile:117-118`. `-e` opens the editor on the current project.

---

## 4. The Pico smoke-test loop

> When to use this: end-to-end iteration with a Pico headset connected
> over USB and a robo-agent running on the same Mac.

### 4.1 The `reverse` target

```
reverse:
	$(ADB) reverse tcp:12345 tcp:12345
	$(ADB) reverse tcp:63901 tcp:63901
	$(ADB) reverse tcp:63900 tcp:63900
	@echo "--- adb reverse list ---"
	@$(ADB) reverse --list
```

`xr/Makefile:80-85`. Mapping, from the comment block at lines 74-79:

- `12345` = video TCP (H.264 NALs)
- `63901` = command/pose TCP (telemetry + commands + clock sync)
- `63900` = UDP discovery broadcast

**`adb reverse` is TCP-only.** UDP packets do not traverse it; any UDP
video transport will silently drop. The Mac robot must be running with
a TCP video transport for this smoke-test path to work. (`debug.xrobo.host`
override exists precisely for the Wi-Fi UDP case — see 4.4.)

**`adb reverse` is wiped whenever the adb daemon restarts or the USB
cable is re-plugged.** Re-run `make reverse` or just `make ship-pico-fast`
(which re-runs reverse as a dependency) after every replug.

### 4.2 `ship-pico` — full build + install + relaunch + log

> When to use this: you've changed XR-side source and want a clean
> iteration.

```
ship-pico: build-install-pico reverse
	$(ADB) shell am force-stop $(package)
	$(ADB) logcat -c
	$(ADB) shell am start -n $(package)/$(activity)
	@sleep 1
	@PID=$$($(ADB) shell "pidof $(package)" | tr -d '\r'); \
	echo "--- tailing logcat for pid $$PID (Ctrl-C to stop) ---"; \
	$(ADB) logcat --pid=$$PID -v brief | \
		grep -E "godot|XRoboToolkit|RobotView|TcpHandler|KotlinVideo|AhbVideo|OpenXR"
```

`xr/Makefile:95-103`. Sequence:

1. `build-install-pico` — rebuild + `adb install -r -d` (will replace a
   stray Quest APK at the same `unique_name`).
2. `reverse` — restore the three TCP forwards.
3. `am force-stop` — guarantee a fresh pid so logcat's `--pid` filter
   doesn't pick up stale process IDs.
4. `logcat -c` — clear ring buffer.
5. `am start` — relaunch.
6. `sleep 1`, look up the new pid, tail filtered logcat for it.

The grep filter (`godot|XRoboToolkit|RobotView|TcpHandler|KotlinVideo|AhbVideo|OpenXR`)
covers the GDScript prints, the TCP handler, the Kotlin video decoder
plugin, the AHB GDExtension, and OpenXR runtime messages.

### 4.3 `ship-pico-fast` — relaunch without rebuilding

> When to use this: only the Mac-side robot changed (or you just want
> to bounce the app); the APK on the headset is fine.

```
ship-pico-fast: reverse
	$(ADB) shell am force-stop $(package)
	$(ADB) logcat -c
	$(ADB) shell am start -n $(package)/$(activity)
	@sleep 1
	@PID=$$($(ADB) shell "pidof $(package)" | tr -d '\r'); \
	echo "--- tailing logcat for pid $$PID (Ctrl-C to stop) ---"; \
	$(ADB) logcat --pid=$$PID -v brief | \
		grep -E "godot|XRoboToolkit|RobotView|TcpHandler|KotlinVideo|AhbVideo|OpenXR"
```

`xr/Makefile:107-115`. Same as `ship-pico` minus the build+install.
Still re-runs `reverse` because adb daemon restarts are frequent.

### 4.4 `debug.xrobo.host` — pointing the headset at a Wi-Fi target

> When to use this: UDP video transport over Wi-Fi (adb reverse can't
> carry datagrams), or when you want to keep the headset untethered.

```
adb shell setprop debug.xrobo.host 192.168.31.31
```

`xr/scenes/main.gd:179-187` reads this on startup via
`OS.execute("getprop", ["debug.xrobo.host"], ...)`. The auto-connect
logic (`_auto_connect_loopback`, lines 171-193) prefers, in order:

1. `XROBO_HOST` environment variable (if set).
2. `debug.xrobo.host` system property (Pico's way of injecting it).
3. Loopback `127.0.0.1:63901` (the `adb reverse` USB workflow).

The property survives until next reboot or explicit `setprop debug.xrobo.host ""`.

If you set the prop but the headset still loops back to `127.0.0.1`,
re-`ship-pico-fast` so the app re-reads it at startup — `getprop` is
only called once per launch (line 185).

---

## 5. AHB GDExtension (`xr/native/ahb_decoder/`)

> When to use this: when the C++ Vulkan/AHB native bridge needs to be
> rebuilt (you've edited `src/*.cpp`, or you're on a fresh clone).

### 5.1 One-time submodule init

```
git submodule update --init --depth=1 xr/native/ahb_decoder/godot-cpp
```

`xr/native/ahb_decoder/build.sh:28-31` runs this automatically if it
notices `godot-cpp/SConstruct` is missing. The submodule itself is
declared at `.gitmodules:1-4`:

```
[submodule "xr/native/ahb_decoder/godot-cpp"]
	path = xr/native/ahb_decoder/godot-cpp
	url = https://github.com/godotengine/godot-cpp.git
	branch = 4.5
```

Branch `4.5` is mandatory — it must match the engine version pinned in
`xr/project.godot:15`.

### 5.2 Build

```
xr/native/ahb_decoder/build.sh           # Release (default)
xr/native/ahb_decoder/build.sh Debug     # symbol-level debugging
```

`xr/native/ahb_decoder/build.sh:11-12`, `:15`. Requires `$ANDROID_NDK`
(or `$ANDROID_NDK_HOME`) pointed at an NDK **r25+** install (lines
19-26). Internally runs:

```
cmake -B build-arm64 \
    -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-29 \
    -DCMAKE_BUILD_TYPE=Release
cmake --build build-arm64 -j4
```

The CMake project asserts API level ≥ 29 explicitly
(`xr/native/ahb_decoder/CMakeLists.txt:22-24`) because it needs
`VkAndroidHardwareBufferPropertiesANDROID`.

### 5.3 Install paths (and why both are needed)

The build script (`xr/native/ahb_decoder/build.sh:48-58`) copies the
resulting `libahb_decoder.so` to **two** locations:

```
ADDON_DST="$SCRIPT_DIR/../../addons/ahb_decoder/libahb_decoder.so"
JNI_DST="$SCRIPT_DIR/../../android/build/libs/arm64-v8a/libahb_decoder.so"
```

That resolves to:

- `xr/addons/ahb_decoder/libahb_decoder.so` — referenced by
  `ahb_decoder.gdextension` so the Godot exporter packages it into the
  APK as a GDExtension.
- `xr/android/build/libs/arm64-v8a/libahb_decoder.so` — picked up by
  the gradle build so Kotlin's
  `System.loadLibrary("ahb_decoder")` can resolve it at runtime.

Skip either and the import path breaks at a different layer: missing
addon copy → Godot exporter ships an APK without the GDExtension and
the C++ class is null; missing JNI copy → Kotlin's
`System.loadLibrary` throws `UnsatisfiedLinkError` and the plugin
falls back to the slower CPU YUV plane copy.

See `xr/native/ahb_decoder/README.md` (especially "Status" §4 and
"Build") for the architectural context and a hand-runnable cmake
recipe.

---

## 6. MuJoCo sim subprocess (`examples/mujuco-arm-so101/`)

> When to use this: driving the SO-101 arm in simulation from the
> Rust agent — no physical servos required.

### 6.1 One-time Python env setup

```
make env
```

`examples/mujuco-arm-so101/Makefile:42-49`. Uses `uv` to create
`.venv/` with Python `3.11` (overridable via `PYTHON_VERSION=`) and
installs `requirements.txt` (mujoco, numpy, pillow). The target
short-circuits via a `.deps-installed` stamp file so a re-run does
nothing if dependencies are already in.

If `uv` isn't on `$PATH`, the `check-uv` rule
(`examples/mujuco-arm-so101/Makefile:33-39`) prints install hints
(`brew install uv` or `curl -LsSf https://astral.sh/uv/install.sh | sh`).

### 6.2 Manual smoke tests

```
make smoketest     # load model, step, print joint/cam summary
make run-sim       # launch the interactive MuJoCo viewer
make render        # offscreen render all cameras to ./renders/
make pick          # scripted IK pick-up demo
```

`examples/mujuco-arm-so101/Makefile:56-67`. Useful for verifying the
env before wiring it into the Rust driver.

### 6.3 How the Rust driver launches it as a subprocess

`robot/config/default.yaml:34` declares the arm driver enum:

```
driver: "dummy"           # dynamixel | feetech_sts | feetech_scs | dummy | mujoco_so101
```

When `driver: "mujoco_so101"` is selected, the Rust `mujoco_so101`
driver spawns the Python script as a subprocess and speaks the JSON-line
protocol defined in `examples/mujuco-arm-so101/sim_so101.py`. The
configuration sub-section (commented out by default at
`robot/config/default.yaml:43-47`) is:

```
# mujoco:
#   python: "examples/mujuco-arm-so101/.venv/bin/python"
#   script: "examples/mujuco-arm-so101/sim_so101.py"
#   steps_per_write: 3     # mj_step calls per outbound ctrl write (1–50)
#   extra_args: []         # reserved for future flags
```

The `python` path points at the venv created by `make env`, so the
end-to-end startup is:

1. `cd examples/mujuco-arm-so101 && make env` (one-time per clone).
2. Edit `robot/config/default.yaml`: flip `driver` to `mujoco_so101`
   and uncomment the `mujoco:` block.
3. Start the agent normally (`make run-mac-local-camera` or `cargo run`).
4. The driver spawns `<python> <script> bridge`; subsequent control
   writes from XR pose mapping flow as JSON lines into the
   subprocess's stdin, and mj_step ticks come back over stdout.

---

## 7. Common failures and fixes

> When to use this: when something just broke. Each entry maps a
> symptom back to the Makefile comment that explains it.

### 7.1 `Address already in use (os error 48)` on macOS

**Symptom:** the agent exits at startup with error 48 on port 63900,
63901, or 12345.

**Cause:** a prior `robo-agent` is still running, or a leftover
`ffmpeg` from a crashed run still holds the port. `robot/Makefile:36-40`
explicitly enumerates this case.

**Fix:** `make run-mac-local-camera` already pkill's prior agents and
`lsof | kill -9`s the listed ports, then sleeps 1 second for TIME_WAIT
to drain. If you started the agent some other way, run those steps by
hand or just call `make run-mac-local-camera`.

### 7.2 ffmpeg hangs silently in AVFoundation init

**Symptom:** Run the agent from VSCode / Cursor / Conductor's embedded
terminal; you see `Selected pixel format (yuv420p) is not supported...
Overriding to uyvy422` and then no frame stats line, ever.

**Cause:** macOS TCC walks the process tree to find the "responsible"
GUI app, attaches the camera permission prompt to *that* app, and
Conductor (etc.) is not a registered TCC client for camera. The prompt
never appears and ffmpeg blocks forever inside AVFoundation init.
Documented at `robot/Makefile:61-75`.

**Fix:** `make run-mac-local-camera-bg`. It generates
`/tmp/run_robot.command` and opens it in Terminal.app, which *is* a
registered TCC client. Grant the camera permission once; it sticks.

### 7.3 `adb reverse` wiped after replug / daemon restart

**Symptom:** Headset can no longer reach the robot at 127.0.0.1:63901;
auto-connect log line appears but TCP connect fails.

**Cause:** `adb reverse` mappings are per-daemon and per-USB-session.
A USB replug or `adb kill-server` clears them. Comment at
`xr/Makefile:74-76`.

**Fix:** Re-run `make reverse`. Or use `make ship-pico-fast` which
includes `reverse` as a prerequisite (`xr/Makefile:107`).

### 7.4 Wrong APK installed on the headset

**Symptom:** APK launches but OpenXR plugin mismatch — Pico's runtime
can't load the Meta plugin or vice versa; obvious symptoms include
"OpenXR failed to start" in logcat.

**Cause:** Both presets share the same `package/unique_name`
(`org.xrobotoolkit.client`, `export_presets.cfg:45` and `:308`), so an
`adb install -r -d` replaces whatever was on the device with the new
APK — including across vendors.

**Fix:** `make ship-pico` (Pico) or `make build-install` (Quest) force
the right APK in. If in doubt, `make uninstall` first to wipe the
existing install.

### 7.5 Missing Godot export templates

**Symptom:** `make build-quest` (or any build target) aborts with
"Missing Android template zip (4.5.1.stable). Install export templates
in Godot."

**Cause:** `prepare-android-libs` (`xr/Makefile:23-35`) couldn't find
`android_source.zip` at either of the two paths in `TEMPLATE_ZIPS`.

**Fix:** Open the Godot editor → **Editor → Manage Export Templates →
Download** for **4.5.1.stable**. Re-run the make target.

### 7.6 Debug binary too slow for camera capture

**Symptom:** Agent runs but the headset only sees 5-10 fps; debug logs
show the encoder backlogged.

**Cause:** The debug binary's CPU YUV path tops the encoder out
(`robot/Makefile:30-32`).

**Fix:** Use the release binary — `make run-mac-local-camera` already
does this; `make run` does not. Don't pipe `cargo run` into a camera
session.

---
