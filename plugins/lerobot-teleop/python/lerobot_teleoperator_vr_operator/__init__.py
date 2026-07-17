"""Operator XR headset teleoperator plugin for LeRobot.

Importing this package registers the `vr_operator` teleoperator type, so stock
LeRobot entry points can use it with no source changes::

    lerobot-teleoperate --teleop.type=vr_operator \\
        --teleop.urdf_path=/path/to/so101_new_calib.urdf \\
        --robot.type=so101_follower --robot.port=/dev/ttyACM0 \\
        --robot.max_relative_target=5

`register_third_party_plugins()` finds this package by importing the
*distribution* name, which is why the distribution and the module must both be
`lerobot_teleoperator_vr_operator` (underscores, matching prefix).

Re-exporting `VROperator` here is load-bearing, not tidiness:
`make_device_from_device_class` derives the device class from the config class
name (`VROperatorConfig` -> `VROperator`) and probes the parent module first.
Its other candidate, `...vroperator` (lowercased, no underscore), never matches
`vr_operator.py`; the `config_` -> stripped rewrite candidate does, but this
re-export is what makes the parent-module candidate hit immediately.
"""

from .config_vr_operator import VROperatorConfig
from .vr_operator import VROperator

__all__ = ["VROperator", "VROperatorConfig"]
