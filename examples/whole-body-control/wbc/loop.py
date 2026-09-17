"""Host lifecycle, independent of the controller and of XR transport.

Only fresh, valid body samples can enable calibration. Paused simulation poses
remain visible; physics never advances while input is unavailable. This module
does not synthesize tracking, infer button timing, or acknowledge local recenter.
"""
from .controllers.base import Controller
from .controls import RESET_HINT
from .tracking import TrackingUnavailable


class ControlLoop:
    def __init__(self, controller: Controller, tracking_timeout: float):
        self.controller = controller
        self.timeout = tracking_timeout
        self.connected = False
        self.frame_id = None
        self.source_timestamp = None
        self.last_body_time = None
        self.last_sample = None
        self.calibrated = False
        self.available = False
        self.sample = 0
        self.status = getattr(controller, "initial_status", RESET_HINT)

    def pause(self, message):
        self.controller.pause()
        self.calibrated = False
        self.status = message

    def tick(self, frame, connected: bool, event, now: float) -> dict:
        if connected != self.connected:
            self.pause("Connected; restore tracking and reset" if connected else "Disconnected; reset after reconnecting")
            self.controller.reset()
            # Frames cached by a prior session cannot calibrate a new session.
            self.frame_id = frame.frame_id if frame is not None else None
            self.source_timestamp = None
            self.last_body_time = None
            self.last_sample = None
        self.connected = connected
        if connected and frame is not None and frame.frame_id != self.frame_id:
            if self.frame_id is not None and frame.frame_id < self.frame_id:
                # A sender restart may occur between polls of connected. Its
                # clock can keep advancing while its sequence starts over, so
                # timestamp checks alone must not preserve the old calibration.
                self.pause("XR frame sequence restarted; release buttons then ABXY to reset")
                self.source_timestamp = None
                self.last_sample, self.last_body_time = None, None
            self.frame_id = frame.frame_id
            try:
                candidate = self.controller.extract(frame)
                if self.source_timestamp is not None and candidate.timestamp_ns < self.source_timestamp:
                    self.pause("Tracking clock changed; release buttons then ABXY to reset")
                    self.last_sample, self.last_body_time = None, None
                if candidate.timestamp_ns != self.source_timestamp:
                    self.last_sample = candidate
                    self.source_timestamp = candidate.timestamp_ns
                    self.last_body_time = now
            except TrackingUnavailable as exc:
                self.pause(f"{exc}; restore tracking and reset")
                self.last_sample, self.last_body_time = None, None
        available = connected and self.last_body_time is not None and now - self.last_body_time <= self.timeout
        was_available = self.available
        self.available = available
        # Both backends consume the same fresh, UI-filtered XrFrame. Old
        # Blueprint reset events (including delayed dual-trigger requests) are
        # deliberately ignored; neither menu actions nor triggers reset physics.
        if available:
            self.status = self.controller.control_tick(frame, self.last_sample, now)
            self.calibrated = self.controller.control_enabled
        elif self.calibrated or was_available:
            self.pause("Body tracking timed out; restore tracking, release buttons then ABXY to reset")
        self.sample += 1
        return {
            **self.controller.simulation.blueprint_state(), "g1.sample": self.sample,
            "g1.visible": True, "control.message": self.status,
        }
