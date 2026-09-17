"""Controller-independent gamepad semantics (robot frame: +X forward, +Y left).

Edges belong to the input session, not to a policy reset. A held chord can never
reset twice, including across loss of tracking. No Blueprint trigger binding is
needed: the headset already sends UI-filtered controller inputs in XrFrame.
"""
from dataclasses import dataclass
from enum import Enum
import math


class ControlMode(Enum):
    LOCOMOTION = "LOCOMOTION"
    VR = "VR"
    BODY = "BODY"

    def next(self):
        modes = list(type(self))
        return modes[(modes.index(self) + 1) % len(modes)]


@dataclass(frozen=True)
class Commands:
    reset: bool = False
    cycle_mode: bool = False
    vx: float = 0.
    vy: float = 0.
    vyaw: float = 0.
    left_trigger: float = 0.
    right_trigger: float = 0.
    left_grip: float = 0.
    right_grip: float = 0.


HELP = "ABXY: initialize/reset | left stick click: mode | sticks: move/turn | triggers/grips: hands"
RESET_HINT = "Release buttons, match robot pose, then press A+B+X+Y to initialize/reset"


class Gamepad:
    DEADZONE = .15
    MAX_SPEED = .6  # m/s, shared conservative command envelope
    MAX_YAW_RATE = 1.5  # rad/s

    def __init__(self):
        self.invalidate()

    def invalidate(self):
        self.armed = False
        self.reset_latched = False
        self.previous_click = True
        self.motion_armed = False

    @staticmethod
    def axis(value):
        value = float(value)
        return max(-1., min(1., value)) if math.isfinite(value) else 0.

    def update(self, frame) -> Commands:
        pair = getattr(frame, "controllers", None)
        if pair is None or any(c is None or not c.pose.valid for c in (pair.left, pair.right)):
            self.invalidate()
            return Commands()

        def value(side, name):
            return self.axis(getattr(pair, side).input.value(name))

        face = [value(side, name) > .5 for side in ("left", "right")
                for name in ("ax_button", "by_button")]
        click = value("left", "primary_click") > .5
        if not self.armed:
            if any(face) or click:
                return Commands()
            self.armed = True
        if not any(face):
            self.reset_latched = False
        reset = all(face) and not self.reset_latched
        if reset:
            self.reset_latched = True
        cycle = click and not self.previous_click and not any(face) and not self.reset_latched
        self.previous_click = click

        lx, ly, rx = (value("left", "primary_x"), value("left", "primary_y"),
                      value("right", "primary_x"))
        magnitude = math.hypot(lx, ly)
        if reset or cycle or any(face):
            self.motion_armed = False
        elif magnitude <= self.DEADZONE and abs(rx) <= self.DEADZONE:
            self.motion_armed = True
        speed = max(0., (min(magnitude, 1.) - self.DEADZONE) / (1. - self.DEADZONE))
        scale = self.MAX_SPEED * speed / magnitude if magnitude else 0.
        yaw = -math.copysign(max(0., (abs(rx) - self.DEADZONE) / (1. - self.DEADZONE)), rx)
        moving = self.motion_armed and not click
        return Commands(reset, cycle, ly * scale if moving else 0., -lx * scale if moving else 0.,
                        yaw * self.MAX_YAW_RATE if moving else 0.,
                        max(0., value("left", "trigger")), max(0., value("right", "trigger")),
                        max(0., value("left", "grip")), max(0., value("right", "grip")))
