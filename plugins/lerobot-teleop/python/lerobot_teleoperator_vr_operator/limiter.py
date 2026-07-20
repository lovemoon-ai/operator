"""Command-space joint rate limiter for the `vr_operator` plugin (Phase-2).

Shapes the *commanded* joint trajectory: bounds velocity, acceleration, and
(via stopping-distance planning) prevents overshoot, so a jumpy IK target
becomes a smooth, jerk-bounded command.

It works in command space (against the plugin's own last command) because the
teleoperator cannot see the follower's encoders -- `get_action()` takes no
observation. That makes it cheap, but it also means it canNOT bound motion
relative to the arm's *actual* position: if the internal command state and the
physical arm disagree (e.g. at startup when the arm is not at the assumed home),
this limiter alone provides no measured-space guarantee. It therefore
COMPLEMENTS, and does not replace, LeRobot's `--robot.max_relative_target`, which
clamps each goal against a fresh `Present_Position` read (measured 1.3ms; keep it
on for safety). Use both: `max_relative_target` = measured-space floor, this =
command-space smoothness + fps-independent velocity/accel caps.

Design notes
------------
* `dt` is measured wall-clock between calls and clamped to `max_dt_s` so a loop
  stall (GC, serial retry) cannot turn into one giant jump when the loop resumes.
* Deceleration planning: the target velocity is capped at sqrt(2*a*distance) so
  the joint can always stop within the remaining distance under the accel limit
  -- a trapezoidal profile with no overshoot/oscillation on fast approaches.
"""

from __future__ import annotations

import math


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
            dist = target_q[i] - self._q[i]
            # Deceleration planning: never go faster than we can still stop from
            # within the remaining distance (v_stop = sqrt(2*a*|dist|)). Without
            # this the accel clamp can't brake in time and the joint overshoots
            # and oscillates around the target on fast approaches.
            v_stop = math.sqrt(2.0 * self.max_acc * abs(dist))
            desired_v = _clamp(dist / dt, -v_max, v_max)
            desired_v = _clamp(desired_v, -v_stop, v_stop)
            # Acceleration clamp: change in velocity is bounded per step...
            dv = _clamp(desired_v - self._v[i], -dv_max, dv_max)
            v = _clamp(self._v[i] + dv, -v_max, v_max)  # ...then the velocity itself.
            q_next = self._q[i] + v * dt
            # Discrete integration can still nudge a fraction past the target even
            # with decel planning; clamp to the target (and stop) if this step
            # would cross it, so there is provably zero overshoot.
            if (dist > 0.0 and q_next > target_q[i]) or (dist < 0.0 and q_next < target_q[i]):
                q_next = target_q[i]
                v = 0.0
            self._q[i] = q_next
            self._v[i] = v

        dg_max = self.grip_rate * dt
        self._g += _clamp(target_gripper - self._g, -dg_max, dg_max)

        return list(self._q), self._g

    def freeze(self) -> tuple[list[float], float] | None:
        """Stop here: zero the velocity and return the current command.

        Used when the deadman is released (or the link goes stale/e-stopped).
        Without this the limiter keeps slewing toward the last IK target it had
        not caught up to yet, and carries its accumulated velocity, so the arm
        visibly keeps moving after the operator lets go. Freezing makes "release"
        mean "the commanded pose stops changing NOW"; the only motion left is the
        servo finishing its approach to the pose already commanded.
        """
        if self._q is None or self._g is None:
            return None
        self._v = [0.0] * self._n
        return list(self._q), self._g

    def current(self) -> tuple[list[float], float] | None:
        """The limiter's current commanded (joints, gripper), or None if unseeded.

        This is what the arm is actually being driven toward -- report it (not the
        raw IK target) in State/Hello so the adapter's snapshot matches reality.
        """
        if self._q is None or self._g is None:
            return None
        return list(self._q), self._g
