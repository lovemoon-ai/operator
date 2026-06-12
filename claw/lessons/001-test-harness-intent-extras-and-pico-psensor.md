# Lesson: intent extras need GodotApp.java mapping; Pico psensor sleep kills CI runs

## Bug 1: WP7 test harness never launched on device

`tests/xr_module_harness.sh` launches with `--es operator_test_suite <s>`, but the
app booted the normal launcher and the harness timed out waiting for
`OPERATOR_TEST_SUITE_DONE`.

Root cause: Godot's Android activity does NOT forward arbitrary intent extras to
GDScript. `xr/android/build/src/com/godot/game/GodotApp.java#getCommandLine()`
maps an explicit allowlist of extras to `--flag value` cmdline args
(`operator.mode`, capture automation, mujoco, ...). `operator_test_suite` /
`operator_test_case` were missing, so `OS.get_cmdline_user_args()` never saw them.

Fix: add to `getCommandLine()`:

```java
appendIntentExtraArg(args, "operator_test_suite", "--operator-test-suite");
appendIntentExtraArg(args, "operator_test_case", "--operator-test-case");
```

Rule of thumb: any new `--es` extra consumed by GDScript needs a matching
`appendIntentExtraArg` line in GodotApp.java.

## Bug 2: 02_ego_record times out / low fps on PICO 4 Ultra when unattended

The PICO shell pauses VR apps and sleeps the HMD a few seconds after the
proximity sensor reports "not worn" (`persist.psensor.sleepmode=2`). The CI
auto-stop Timer freezes while paused, so the recording never finalizes
("timed out waiting for capture stop"), or repeated pause/resume cycles drop
the measured RGB fps below the validator threshold.

Fix for unattended CI runs (device must allow `adb root`):

```bash
adb root
adb shell setprop persist.psensor.sleepmode 0   # requires reboot to apply
adb reboot
adb shell svc power stayon true
```

After this the headset stays awake/focused on a desk and the test passes.
`input keyevent KEYCODE_WAKEUP` loops are NOT a substitute — each keyevent
itself triggers a pause/resume cycle on PICO.
