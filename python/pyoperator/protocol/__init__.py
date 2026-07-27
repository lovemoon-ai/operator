"""Wire contracts Operator clients speak.

pyoperator owns every protocol the Operator XR app talks, so the app depends on
one Python package rather than on each capability library. Compute libraries
(e.g. `retargeting`) stay transport-free and are called by the services in
:mod:`pyoperator.services`.
"""

from .retargeting import (
    PROTOCOL_VERSION,
    ProtocolError,
    RetargetingRequest,
    RetargetingResult,
    error_message,
    parse_frame_envelope,
    parse_hello,
)

__all__ = [
    "PROTOCOL_VERSION",
    "ProtocolError",
    "RetargetingRequest",
    "RetargetingResult",
    "error_message",
    "parse_frame_envelope",
    "parse_hello",
]
