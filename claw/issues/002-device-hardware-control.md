# Device And Hardware Control Gaps

Status: open
Category: device and hardware control

## Unfinished Items

- Replace simulated `RcCar` logging with real serial PWM output.
- Open and manage the configured RC car serial port, including neutral-on-disconnect behavior.
- Wire `feetech_sts`, `feetech_scs`, and `dynamixel` driver selection to `SerialServoDriver` instead of always falling back to `DummyDriver`.
- Complete gripper hardware behavior for serial servo drivers.
- Implement device types planned in docs but absent from code: `robot_dog`, `drone`, and future humanoid/full-body devices.
- Implement a pure YAML generic device driver so simple devices can be added without writing Rust code.

## Current Evidence

- `robot/src/devices/rc_car.rs` builds PWM command strings but only logs them.
- `robot/src/control/drivers/serial_servo.rs` contains packet builders and serial write code.
- `robot/src/control/drivers/mod.rs` still returns `DummyDriver` for `feetech_sts`, `feetech_scs`, and `dynamixel`.
- `robot/src/device/registry.rs` only recognizes `robot_arm` and `rc_car`; unknown types fall back to `DummyDevice`.

## Acceptance Criteria

- `rc_car` can drive a real configured serial device and returns errors when serial setup fails.
- Robot arm config values for `feetech_sts`, `feetech_scs`, and `dynamixel` instantiate the real serial driver.
- Hardware drivers have a dummy/simulated mode only when explicitly requested.
- At least one non-arm, non-car device can be added either by a generic YAML driver or a new concrete device implementation.
