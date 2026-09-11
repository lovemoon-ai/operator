"""Replace ``DemoRobot`` with calls from your robot vendor's Python SDK.

This is the complete Outside Robot shape: one ``XrSession`` owns both the
tracking/control stream and a source-authored Blueprint.
"""

from __future__ import annotations

import threading
import time
from types import MappingProxyType

from pyoperator import (
    Pose,
    PoseDeltaRetargeter,
    BlueprintComponent,
    BlueprintEvent,
    BlueprintTransform,
    RobotState,
    Blueprint,
    XrSession,
)
from pyoperator.control_loop import run


def build_blueprint() -> Blueprint:
    return Blueprint(
        blueprint_id="example.custom_robot",
        components=(
            BlueprintComponent.label(
                "instructions",
                text="Unlock from the palm menu, then hold right grip to move.",
                anchor="head",
                transform=BlueprintTransform(position=(0.0, -0.18, -0.7)),
                properties={
                    "font_size": 28,
                    "settings_label": "Control instructions",
                },
            ),
            BlueprintComponent.status_lamp(
                "robot_status",
                text="Waiting for robot",
                anchor="right_controller",
                state_binding="robot.status",
                text_binding="robot.status_text",
                properties={"settings_label": "Robot status"},
                user_overridable=False,
            ),
            BlueprintComponent.palm_menu(
                "control_gate",
                title="Robot control",
                action="toggle_control",
                value_binding="control.enabled",
                available_binding="control.available",
                locked_text="Unlock control",
                unlocked_text="Lock control",
                properties={"settings_label": "Palm control menu"},
            ),
            BlueprintComponent.controller_help(
                properties={"settings_label": "Controller help"},
            ),
            BlueprintComponent.control_frame(
                properties={"settings_label": "Robot control frame"},
            ),
            BlueprintComponent.operation_trajectory(
                properties={"settings_label": "Operation trajectory"},
            ),
        ),
    )


class DemoRobot:
    def __init__(self, session: XrSession, control_enabled: threading.Event) -> None:
        self._blueprint = session.blueprint
        self._control_enabled = control_enabled
        # Blueprint events arrive on a helper thread. Real vendor SDK calls
        # should remain serialized even when a palm-menu event requests a stop.
        self._io_lock = threading.Lock()
        self._connected = False
        self._motion_active = False

    def connect(self) -> None:
        with self._io_lock:
            self._connected = True
            print("robot connected")
        self._blueprint.update(
            {
                "robot.status": "active",
                "robot.status_text": "Robot connected · control locked",
                "control.available": True,
            }
        )

    def disconnect(self) -> None:
        with self._io_lock:
            self._connected = False
            self._control_enabled.clear()
            print("robot disconnected")
        self._blueprint.update(
            {
                "robot.status": "inactive",
                "robot.status_text": "Robot disconnected",
                "control.enabled": False,
                "control.available": False,
            }
        )

    def read_state(self) -> RobotState:
        with self._io_lock:
            timestamp_ns = time.time_ns()
            return RobotState(
                timestamp_ns=timestamp_ns,
                ee_poses=MappingProxyType(
                    {
                        "end_effector": Pose(
                            valid=True,
                            sample_timestamp_ns=timestamp_ns,
                            position=(0.3, 0.0, 0.2),
                        )
                    }
                ),
            )

    def write(self, command: object) -> None:
        if not self._control_enabled.is_set():
            return
        with self._io_lock:
            if not self._control_enabled.is_set():
                return
            first_command = not self._motion_active
            self._motion_active = True
            print("target", command)
        if first_command:
            self._blueprint.update(
                {
                    "robot.status": "active",
                    "robot.status_text": "Teleoperation active",
                }
            )

    def stop(self, reason: str = "stop") -> None:
        with self._io_lock:
            self._motion_active = False
            connected = self._connected
            print("safe stop:", reason)
        if connected:
            self._blueprint.update(
                {
                    "robot.status": "warning",
                    "robot.status_text": f"Stopped · {reason}",
                }
            )

    def set_control_enabled(self, enabled: bool) -> None:
        if enabled:
            self._control_enabled.set()
        else:
            self._control_enabled.clear()
            self.stop("locked from palm menu")
        self._blueprint.update(
            {
                "control.enabled": enabled,
                "robot.status": "active" if enabled else "warning",
                "robot.status_text": (
                    "Control unlocked · hold right grip"
                    if enabled
                    else "Control locked"
                ),
            }
        )


class ControlGateRetargeter:
    def __init__(
        self,
        delegate: PoseDeltaRetargeter,
        control_enabled: threading.Event,
    ) -> None:
        self._delegate = delegate
        self._control_enabled = control_enabled

    def reset(self) -> None:
        self._delegate.reset()

    def retarget(self, frame, robot_state):
        if not self._control_enabled.is_set():
            self._delegate.reset()
            return None
        return self._delegate.retarget(frame, robot_state)


def consume_blueprint_events(
    session: XrSession,
    robot: DemoRobot,
    stop_event: threading.Event,
) -> None:
    while not stop_event.is_set() and session.is_running:
        event: BlueprintEvent | None = session.blueprint.poll_event(timeout=0.1)
        if event is None:
            continue
        if event.component_id == "control_gate" and event.action == "toggle_control":
            robot.set_control_enabled(bool(event.value))


def main() -> None:
    control_enabled = threading.Event()
    event_stop = threading.Event()
    control_stop = threading.Event()

    with XrSession() as session:
        session.blueprint.set_blueprint(build_blueprint())
        session.blueprint.update(
            {
                "robot.status": "inactive",
                "robot.status_text": "Waiting for robot",
                "control.enabled": False,
                "control.available": False,
            }
        )
        robot = DemoRobot(session, control_enabled)
        event_thread = threading.Thread(
            target=consume_blueprint_events,
            args=(session, robot, event_stop),
            name="blueprint-events",
            daemon=True,
        )
        event_thread.start()
        try:
            run(
                robot,
                ControlGateRetargeter(
                    PoseDeltaRetargeter(hand="right", deadman_input="grip"),
                    control_enabled,
                ),
                session=session,
                stop_event=control_stop,
            )
        except KeyboardInterrupt:
            print("stopping custom robot example")
        finally:
            control_stop.set()
            event_stop.set()
            event_thread.join(timeout=1.0)
            session.blueprint.clear()


if __name__ == "__main__":
    main()
