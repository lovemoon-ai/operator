"""Command-space joint rate limiter for the `vr_operator` plugin (Phase-2).

Bounds the *commanded* joint velocity and acceleration against the plugin's own
previous command, so it needs no `Present_Position` read. This lets us drop
LeRobot's `--robot.max_relative_target` (which clamped against a fresh serial
read every loop) without letting the arm slew or jerk unboundedly.

Design notes
------------
* Works in command space (last commanded joints), not measured space -- the
  teleoperator cannot see the follower's encoders (`get_action()` takes no
  observation). This is the same reason it is cheaper than `max_relative_target`,
  which paid a serial round-trip to read the present position.
* `dt` is measured wall-clock between calls and clamped to `max_dt_s` so a loop
  stall (GC, serial retry) cannot turn into one giant jump when the loop resumes.
* The velocity default is set at/above the effective envelope
  `max_relative_target=5` gave at 30Hz (~150 deg/s), so enabling this is a safety
  *replacement*, not a tracking regression.
* Also bounds the startup/reset home slew (target jumps to home; the limiter
  slews the command there at bounded speed) -- the role `max_relative_target`
  used to play for the README's "arm slews to home on start" behaviour.
"""

from __future__ import annotations


def _clamp(x: float, lo: float, hi: float) -> float:
    return lo if x < lo else hi if x > hi else x


class JointRateLimiter:
    """Per-joint velocity + acceleration limiter, plus a gripper rate limiter."""

    def __init__(
        self,
        *,
        n_arm: int,
        max_velocity_deg_s: float,
        max_acceleration_deg_s2: float,
        gripper_max_rate_per_s: float,
        max_dt_s: float = 0.05,
    ) -> None:
        self._n = n_arm
        self.max_vel = float(max_velocity_deg_s)
        self.max_acc = float(max_acceleration_deg_s2)
        self.grip_rate = float(gripper_max_rate_per_s)
        self.max_dt = float(max_dt_s)
        self._q: list[float] | None = None
        self._v: list[float] = [0.0] * n_arm
        self._g: float | None = None
        self._t: float | None = None

    def reset(self, q: list[float], gripper: float, now: float | None = None) -> None:
        """Snap internal command state to ``q``/``gripper`` with zero velocity.

        Call on connect and whenever the command chain is re-seeded so the
        limiter does not slew from a stale internal position.
        """
        self._q = [float(v) for v in q]
        self._v = [0.0] * self._n
        self._g = float(gripper)
        self._t = now

    def step(self, target_q: list[float], target_gripper: float, now: float) -> tuple[list[float], float]:
        """Advance the command one tick toward the target within vel/accel caps.

        Returns the rate-limited ``(joints, gripper)`` to actually command.
        """
        if self._q is None or self._g is None:
            self.reset(target_q, target_gripper, now)
            return list(self._q), self._g  # type: ignore[arg-type]

        dt = 0.0 if self._t is None else (now - self._t)
        self._t = now
        # First step after a reset, or a stalled/none dt: hold (no motion budget).
        if dt <= 0.0:
            return list(self._q), self._g
        dt = min(dt, self.max_dt)

        dv_max = self.max_acc * dt
        v_max = self.max_vel
        for i in range(self._n):
            desired_v = (target_q[i] - self._q[i]) / dt
            # Acceleration clamp: change in velocity is bounded per step...
            dv = _clamp(desired_v - self._v[i], -dv_max, dv_max)
            v = _clamp(self._v[i] + dv, -v_max, v_max)  # ...then the velocity itself.
            self._q[i] += v * dt
            self._v[i] = v

        dg_max = self.grip_rate * dt
        self._g += _clamp(target_gripper - self._g, -dg_max, dg_max)

        return list(self._q), self._g
