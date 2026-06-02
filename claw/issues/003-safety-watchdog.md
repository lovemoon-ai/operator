# Safety And Watchdog Gaps

Status: done
Category: safety

## Resolution

All five gaps closed in `robot/`:

- **Watchdog enforces `command_timeout_ms`** — `device::control_loop::run`
  tracks `last_cmd_at` and ticks at `timeout/4` (clamped to 50–250 ms),
  firing the configured action exactly once per silence period and
  re-arming on command resumption.
- **`disconnect_action` executed** — `apply_disconnect_action` in
  `device/control_loop.rs` handles `stop` (force-send neutral + e-stop),
  `hold` (no-op), and `return_home` (currently aliases stop with a
  follow-up TODO for a per-device home pose).
- **`SafetyResult::Rejected` real conditions** — `DeviceSafety::validate`
  rejects: NaN/inf axis or pose values, non-unit quaternions, unknown
  axis/button/pose names (strict schema), and >1 button active in a group.
- **Button semantics** — new `ButtonStateTracker` in `device/safety.rs`
  applies `toggle` (rising-edge latch), `confirm` (two-press within a
  2-second window), and `group` (mutual exclusion in output) semantics.
- **Cannot bypass safety** — new `device::SafeDevice` wraps
  `Box<dyn Device>` and is the only thing `DeviceRegistry::create_device`
  returns. The inner device is private. Watchdog uses a privileged
  `force_send` for synthetic commands; user code has only `send_command`,
  which always validates.

## Test Coverage

- 13 unit tests in `device/safety.rs` (clamp, dead-zone, NaN/inf, unknown
  names, quaternion norm, confirm two-press + window expiry, toggle
  rising-edge, group conflict).
- 6 integration tests in `tests/watchdog_test.rs` driven by a new
  `device::mock::MockDevice`, using `tokio::test(start_paused = true)`
  for deterministic timing:
  - timeout fires `stop` once and re-arms on recovery,
  - `hold` sends nothing,
  - `return_home` falls back to stop,
  - watchdog dormant before first command,
  - rejected command triggers e-stop,
  - clamped command still reaches the device.

## Follow-ups

- Implement true `return_home` once `Device` trait gains a home-pose
  method (track in a separate issue).
- Consider promoting `Device` trait to `pub(crate)` so the only public
  command path is `SafeDevice::send_command`.
