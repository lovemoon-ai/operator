"""Tests for the Phase-2 JointRateLimiter and its integration in get_action."""

from __future__ import annotations

from lerobot_teleoperator_vr_operator.limiter import JointRateLimiter


def _limiter(**kw):
    defaults = dict(
        n_arm=5,
        max_velocity_deg_s=180.0,
        max_acceleration_deg_s2=1200.0,
        gripper_max_rate_per_s=400.0,
    )
    defaults.update(kw)
    return JointRateLimiter(**defaults)


def test_first_step_seeds_to_target_verbatim():
    # Before any reset, the first step adopts the target as the baseline and
    # returns it unchanged (so a fresh limiter never injects a spurious slew).
    lim = _limiter()
    q, g = lim.step([10, 20, 30, 40, 50], 60.0, now=1.0)
    assert q == [10, 20, 30, 40, 50]
    assert g == 60.0


def test_velocity_cap_is_never_exceeded():
    lim = _limiter(max_velocity_deg_s=180.0)
    lim.reset([0.0] * 5, 0.0, now=0.0)
    prev = 0.0
    dt = 1 / 30
    for k in range(1, 300):
        q, _ = lim.step([1000, 0, 0, 0, 0], 0.0, now=k * dt)
        assert q[0] - prev <= 180.0 * dt + 1e-6
        prev = q[0]


def test_acceleration_cap_makes_first_move_small():
    # From rest, the first step is accel-limited (<= a*dt^2), not a vel-cap jump.
    lim = _limiter(max_acceleration_deg_s2=1200.0)
    lim.reset([0.0] * 5, 0.0, now=0.0)
    dt = 1 / 30
    q, _ = lim.step([1000, 0, 0, 0, 0], 0.0, now=dt)
    assert 0 < q[0] <= 1200.0 * dt * dt + 1e-6


def test_converges_to_reachable_target():
    lim = _limiter()
    lim.reset([0.0] * 5, 0.0, now=0.0)
    q = g = None
    for k in range(1, 400):
        q, g = lim.step([90, -45, 30, 10, -20], 75.0, now=k / 30)
    assert q == [90, -45, 30, 10, -20] or all(abs(a - b) < 1e-3 for a, b in zip(q, [90, -45, 30, 10, -20]))
    assert abs(g - 75.0) < 1e-6


def test_stall_dt_is_clamped():
    # A multi-second gap must not translate into a huge single jump.
    lim = _limiter(max_acceleration_deg_s2=1200.0, gripper_max_rate_per_s=400.0)
    lim.reset([0.0] * 5, 0.0, now=100.0)
    q, g = lim.step([1000] * 5, 100.0, now=110.0)  # dt=10s -> clamped to max_dt
    # accel-limited first step with the clamped dt (default max_dt_s=0.05):
    assert q[0] <= 1200.0 * 0.05 * 0.05 + 1e-6
    assert g <= 400.0 * 0.05 + 1e-6


def test_gripper_rate_is_bounded():
    lim = _limiter(gripper_max_rate_per_s=400.0)
    lim.reset([0.0] * 5, 0.0, now=0.0)
    dt = 1 / 30
    _, g = lim.step([0] * 5, 100.0, now=dt)
    assert 0 < g <= 400.0 * dt + 1e-6


def test_disabled_via_config_returns_raw(tmp_path):
    # With limit_enabled=False the plugin must return raw IK output (no slew).
    import numpy as np
    from lerobot_teleoperator_vr_operator.config_vr_operator import VROperatorConfig
    from lerobot_teleoperator_vr_operator.vr_operator import VROperator

    op = VROperator(VROperatorConfig(calibration_dir=tmp_path, limit_enabled=False))
    assert op._limiter is None
    raw = op._action([11.0, 22.0, 33.0, 44.0, 55.0], 66.0)
    assert raw["shoulder_pan.pos"] == 11.0
    assert raw["gripper.pos"] == 66.0
    _ = np  # keep import meaningful if extended later
