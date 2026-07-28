"""Live Feed: receive OLCP capture streams from an XR headset and return results.

The Live Feed transport is separate from :mod:`pyoperator.xr_bridge`: the bridge
exposes low-bandwidth pose/controller snapshots to a local Python process, while
this package accepts high-bandwidth OLCP capture streams (RGB, depth, pose,
hands) and streams algorithm results back to the headset.

Typical one-way use::

    from pyoperator.live_feed import LiveFeedReceiver, ReceiverConfig

    with LiveFeedReceiver(ReceiverConfig()) as receiver:
        for session in receiver.sessions():
            for sample in session.samples():
                print(sample.kind, sample.pts_ns)

Add results to close the loop::

    for sample in session.samples():
        if sample.kind == "head_pose":
            session.results.publish_points(map_id="trail", points=[...])
"""

from . import qr
from .cli import main
from .decoders import RgbHevcDecoder
from .models import (
    CONTROLLER_BUTTON_BITS,
    ControllerInputSample,
    ControllerPoseSample,
    DepthCameraModel,
    DepthFrameSample,
    DepthMetadataSample,
    HandJoint,
    HandJointsSample,
    HeadPoseSample,
    PoseSample,
    RgbCameraModel,
    RgbConfigSample,
    RgbFrame,
    RgbPacketSample,
    Sample,
    SessionEndSample,
    SessionStartSample,
    Transform,
    UnknownSample,
    apply_transform,
    compose_transform,
    decode_button_mask,
    depth_model_from_metadata,
    identity_matrix,
    identity_transform,
    invert_transform,
    parse_sample,
    rgb_cameras_from_config,
    sample_kinds,
    transform_to_matrix,
)
from .protocol import (
    AlgorithmDemand,
    CapturePlan,
    QUEST_CAPTURE_PROFILE,
    StreamEvent,
    XrCapabilities,
    build_capture_request,
    capabilities_from_session_start,
    decode_depth_frame_payload,
    decode_transport_payload,
    get_demand,
    pack_composite_payload,
    pack_frame,
    parse_composite_payload,
    read_frame,
    validate_demand,
)
from .results import (
    POINT_FORMAT,
    DensePoint,
    ResultChannel,
    ResultPublisher,
    monotonic_pts_ns,
    pack_dense_points,
)
from .runtime import (
    DroppingQueue,
    LiveFeedReceiver,
    LiveFeedSession,
    ReceiverConfig,
    SessionQueues,
    SessionRecorder,
    SessionStats,
)
from .server import LiveFeedServer

__all__ = [
    "AlgorithmDemand",
    "CONTROLLER_BUTTON_BITS",
    "CapturePlan",
    "ControllerInputSample",
    "ControllerPoseSample",
    "DensePoint",
    "DepthCameraModel",
    "DepthFrameSample",
    "DepthMetadataSample",
    "DroppingQueue",
    "HandJoint",
    "HandJointsSample",
    "HeadPoseSample",
    "LiveFeedReceiver",
    "LiveFeedServer",
    "LiveFeedSession",
    "POINT_FORMAT",
    "PoseSample",
    "QUEST_CAPTURE_PROFILE",
    "ReceiverConfig",
    "ResultChannel",
    "ResultPublisher",
    "RgbCameraModel",
    "RgbConfigSample",
    "RgbFrame",
    "RgbHevcDecoder",
    "RgbPacketSample",
    "Sample",
    "SessionEndSample",
    "SessionQueues",
    "SessionRecorder",
    "SessionStartSample",
    "SessionStats",
    "StreamEvent",
    "Transform",
    "UnknownSample",
    "XrCapabilities",
    "apply_transform",
    "build_capture_request",
    "capabilities_from_session_start",
    "compose_transform",
    "decode_button_mask",
    "decode_depth_frame_payload",
    "decode_transport_payload",
    "depth_model_from_metadata",
    "get_demand",
    "identity_matrix",
    "identity_transform",
    "invert_transform",
    "main",
    "monotonic_pts_ns",
    "pack_composite_payload",
    "pack_dense_points",
    "pack_frame",
    "parse_composite_payload",
    "parse_sample",
    "qr",
    "read_frame",
    "rgb_cameras_from_config",
    "sample_kinds",
    "transform_to_matrix",
    "validate_demand",
]
