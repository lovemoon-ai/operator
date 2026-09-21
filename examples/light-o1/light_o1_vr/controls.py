"""Right-controller semantics: stick left/right picks a prompt, A generates, B replays.

Edges belong to the input session. Nothing fires until every input has been
seen released once (a fresh baseline after connect or tracking loss), so a
button held while the headset connects cannot start a motion. The stick steps
one prompt per deflection and must return towards centre before the next step.
The headset already sends UI-filtered controller inputs in ``XrFrame``; no
Blueprint menu or trigger binding is involved.
"""
from __future__ import annotations

from dataclasses import dataclass
import math


@dataclass(frozen=True)
class Commands:
    prev: bool = False
    next: bool = False
    generate: bool = False
    replay: bool = False

    def __bool__(self) -> bool:
        return self.prev or self.next or self.generate or self.replay


HELP = "Stick left/right: prompt | A: generate | B: replay last"


class Gamepad:
    PRESS = 0.5       # button threshold on the 0..1 wire value
    DEFLECT = 0.6     # stick deflection that steps the prompt
    RECENTRE = 0.3    # stick must fall below this before the next step

    def __init__(self):
        self.invalidate()

    def invalidate(self) -> None:
        """Forget all edges; the next frame must show released inputs before anything fires."""
        self.armed = False
        self.a_down = True
        self.b_down = True
        self.stick_latched = 0

    @staticmethod
    def axis(value) -> float:
        value = float(value)
        return max(-1.0, min(1.0, value)) if math.isfinite(value) else 0.0

    def update(self, frame) -> Commands:
        pair = getattr(frame, "controllers", None) if frame is not None else None
        right = getattr(pair, "right", None)
        if right is None or not right.pose.valid:
            self.invalidate()
            return Commands()
        a = self.axis(right.input.value("ax_button")) > self.PRESS
        b = self.axis(right.input.value("by_button")) > self.PRESS
        x = self.axis(right.input.value("primary_x"))
        left = getattr(pair, "left", None)
        if abs(x) < self.RECENTRE and left is not None and left.pose.valid:
            x = self.axis(left.input.value("primary_x"))  # either stick selects prompts
        if not self.armed:
            if a or b or abs(x) >= self.RECENTRE:
                return Commands()
            self.armed = True
            self.a_down = self.b_down = False
        generate = a and not self.a_down
        replay = b and not self.b_down
        self.a_down, self.b_down = a, b
        step = 0
        if self.stick_latched == 0:
            if x >= self.DEFLECT:
                step = self.stick_latched = 1
            elif x <= -self.DEFLECT:
                step = self.stick_latched = -1
        elif abs(x) < self.RECENTRE:
            self.stick_latched = 0
        return Commands(prev=step < 0, next=step > 0, generate=generate, replay=replay)
