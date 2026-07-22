"""Replace DemoRobot with the calls from your robot vendor's Python SDK."""

import threading
import time
from types import MappingProxyType

from pyoperator import Pose, PoseDeltaRetargeter, RobotState
from pyoperator.control_loop import run


class DemoRobot:
    def connect(self) -> None:
        print("robot connected")

    def disconnect(self) -> None:
        print("robot disconnected")

    def read_state(self) -> RobotState:
        return RobotState(
            timestamp_ns=time.time_ns(),
            ee_poses=MappingProxyType(
                {
                    "end_effector": Pose(
                        valid=True,
                        sample_timestamp_ns=time.time_ns(),
                        position=(0.3, 0.0, 0.2),
                    )
                }
            ),
        )

    def write(self, command) -> None:
        print("target", command)

    def stop(self, reason: str = "stop") -> None:
        print("safe stop:", reason)


run(
    DemoRobot(),
    PoseDeltaRetargeter(hand="right", deadman_input="grip"),
    stop_event=threading.Event(),
)
