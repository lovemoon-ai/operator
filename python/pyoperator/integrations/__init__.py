"""Adapters between pyoperator's wire/XR types and external capability libraries.

Each integration is optional: importing :mod:`pyoperator` never requires the
library it adapts, and the adapted library never learns about pyoperator.
"""

from .revo2 import (
    CHANNELS as REVO2_CHANNELS,
    COMMAND_FLAG_HOLD as REVO2_COMMAND_FLAG_HOLD,
    CurrentEma,
    Revo2HandFeedback,
    axis_name as revo2_axis_name,
    command_packet_v2 as revo2_command_packet_v2,
    command_targets as revo2_command_targets,
    gesture_targets as revo2_gesture_targets,
    hand_enabled as revo2_hand_enabled,
    merge_descriptor as merge_revo2_descriptor,
    target_packet_v2 as revo2_target_packet_v2,
    telemetry_values as revo2_telemetry_values,
)
from .revo2_udp import Revo2UdpHostedAdapter, make_revo2_descriptor

__all__ = [
    "REVO2_CHANNELS",
    "REVO2_COMMAND_FLAG_HOLD",
    "CurrentEma",
    "Revo2HandFeedback",
    "Revo2UdpHostedAdapter",
    "make_revo2_descriptor",
    "merge_revo2_descriptor",
    "revo2_axis_name",
    "revo2_command_packet_v2",
    "revo2_command_targets",
    "revo2_gesture_targets",
    "revo2_hand_enabled",
    "revo2_target_packet_v2",
    "revo2_telemetry_values",
]
