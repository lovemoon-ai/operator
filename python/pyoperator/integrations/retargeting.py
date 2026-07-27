"""Boundary between Operator data and the `retargeting` compute library.

Dependency direction is one-way: pyoperator knows about retargeting, never the
reverse. Everything Operator-shaped — wire payloads, ``XrFrame`` snapshots,
OpenXR joint sets, quaternion order — is translated here, so the solver library
only ever sees its own canonical types.

Two callers use this module:

- :mod:`pyoperator.services.retargeting` — the Inside Robot remote path, where
  a payload arrives from the headset and joint positions go back to it;
- :class:`PyOperatorRetargeter` — the Outside Python path, where an ``XrFrame``
  is solved in-process and written to a robot.
"""

from __future__ import annotations

from typing import Any, Mapping, Sequence

from ..models import Pose, XrFrame
from ..protocol.retargeting import ProtocolError, RetargetingRequest
from ..protocol.retargeting import RetargetingResult as WireResult
from ..robot import JointTarget, RobotState

#: Body joint sets whose integer joint ids this module can name. The Godot
#: XRBodyTracker order is the vocabulary the Operator app already uses on its
#: own retargeting channel, so both paths produce identical joint names.
GODOT_XR_BODY_TRACKER_V1 = "godot_xr_body_tracker_v1"

GODOT_XR_BODY_TRACKER_JOINTS: tuple[str, ...] = (
    "root", "hips", "spine", "chest", "upper_chest", "neck", "head", "head_tip",
    "left_shoulder", "left_upper_arm", "left_lower_arm", "right_shoulder",
    "right_upper_arm", "right_lower_arm", "left_upper_leg", "left_lower_leg",
    "left_foot", "left_toes", "right_upper_leg", "right_lower_leg", "right_foot",
    "right_toes", "left_hand", "left_palm", "left_wrist", "left_thumb_metacarpal",
    "left_thumb_phalanx_proximal", "left_thumb_phalanx_distal", "left_thumb_tip",
    "left_index_finger_metacarpal", "left_index_finger_phalanx_proximal",
    "left_index_finger_phalanx_intermediate", "left_index_finger_phalanx_distal",
    "left_index_finger_tip", "left_middle_finger_metacarpal",
    "left_middle_finger_phalanx_proximal", "left_middle_finger_phalanx_intermediate",
    "left_middle_finger_phalanx_distal", "left_middle_finger_tip",
    "left_ring_finger_metacarpal", "left_ring_finger_phalanx_proximal",
    "left_ring_finger_phalanx_intermediate", "left_ring_finger_phalanx_distal",
    "left_ring_finger_tip", "left_pinky_finger_metacarpal",
    "left_pinky_finger_phalanx_proximal", "left_pinky_finger_phalanx_intermediate",
    "left_pinky_finger_phalanx_distal", "left_pinky_finger_tip", "right_hand",
    "right_palm", "right_wrist", "right_thumb_metacarpal",
    "right_thumb_phalanx_proximal", "right_thumb_phalanx_distal", "right_thumb_tip",
    "right_index_finger_metacarpal", "right_index_finger_phalanx_proximal",
    "right_index_finger_phalanx_intermediate", "right_index_finger_phalanx_distal",
    "right_index_finger_tip", "right_middle_finger_metacarpal",
    "right_middle_finger_phalanx_proximal", "right_middle_finger_phalanx_intermediate",
    "right_middle_finger_phalanx_distal", "right_middle_finger_tip",
    "right_ring_finger_metacarpal", "right_ring_finger_phalanx_proximal",
    "right_ring_finger_phalanx_intermediate", "right_ring_finger_phalanx_distal",
    "right_ring_finger_tip", "right_pinky_finger_metacarpal",
    "right_pinky_finger_phalanx_proximal", "right_pinky_finger_phalanx_intermediate",
    "right_pinky_finger_phalanx_distal", "right_pinky_finger_tip", "lower_chest",
    "left_scapula", "left_wrist_twist", "right_scapula", "right_wrist_twist",
    "left_foot_twist", "left_heel", "left_middle_foot", "right_foot_twist",
    "right_heel", "right_middle_foot",
)

BODY_JOINT_SETS: dict[str, tuple[str, ...]] = {
    GODOT_XR_BODY_TRACKER_V1: GODOT_XR_BODY_TRACKER_JOINTS,
}


class RetargetingUnavailableError(RuntimeError):
    """The `retargeting` library is not installed in this environment."""


def require_retargeting():
    """Import the compute library, or explain how to install it."""
    try:
        import retargeting
    except ImportError as exc:  # pragma: no cover - environment dependent
        raise RetargetingUnavailableError(
            "the retargeting library is required: "
            "pip install 'pyoperator[retargeting]' (the solver package lives in "
            "the retargeting repository, `pip install ./python` there)"
        ) from exc
    return retargeting


# -- wire payload -> canonical input ---------------------------------------


def input_from_payload(
    payload: Mapping[str, Any], input_type: str, timestamp_ns: int = 0
):
    """Convert one wire frame payload into the canonical solver input.

    Raises :class:`ProtocolError` with a stable code so the transport can report
    *why* a frame was rejected without inspecting solver internals.
    """
    rt = require_retargeting()
    if input_type == rt.END_EFFECTOR_INPUT_V1:
        return _end_effector_input(rt, payload, timestamp_ns)
    if input_type == rt.SKELETON_INPUT_V1:
        return _skeleton_input(rt, payload, timestamp_ns)
    raise ProtocolError("unsupported_input_type", f"unsupported input type '{input_type}'")


def _end_effector_input(rt, payload: Mapping[str, Any], timestamp_ns: int):
    try:
        pose = rt.JointPose.create(
            payload.get("position"),
            payload.get("orientation_wxyz", (1.0, 0.0, 0.0, 0.0)),
            field_name="payload",
        )
    except rt.InvalidInputError as exc:
        raise _wire_error(exc) from exc
    grippers = {}
    gripper = payload.get("gripper")
    if isinstance(gripper, (int, float)) and not isinstance(gripper, bool):
        grippers["end_effector"] = float(gripper)
    return rt.EndEffectorInput(
        timestamp_ns=int(payload.get("timestamp_ns", timestamp_ns)),
        targets={"end_effector": pose},
        grippers=grippers,
    )


def _skeleton_input(rt, payload: Mapping[str, Any], timestamp_ns: int):
    # The app nests the tracking frame under "frame"; accept the bare form too
    # so replay tools can post joints directly.
    frame = payload.get("frame") if isinstance(payload.get("frame"), Mapping) else payload
    raw_joints = frame.get("joints")
    if not isinstance(raw_joints, Mapping):
        raise ProtocolError("invalid_frame", "payload.joints must be an object")
    joints = {}
    try:
        for name, record in raw_joints.items():
            pose = _joint_pose_from_record(rt, record, str(name))
            if pose is not None:
                joints[str(name)] = pose
    except rt.InvalidInputError as exc:
        raise _wire_error(exc) from exc
    if not joints:
        raise ProtocolError("invalid_frame", "payload.joints has no valid joint")
    return rt.SkeletonInput(
        timestamp_ns=int(frame.get("timestamp_ns", timestamp_ns)),
        joints=joints,
        coordinate_space=str(frame.get("coordinate_space", "xr_origin")),
    )


def _joint_pose_from_record(rt, record: Any, name: str):
    """One canonical joint record: ``{valid, pose: {p: xyz, q: xyzw}}``."""
    if not isinstance(record, Mapping) or not record.get("valid", False):
        return None
    pose = record.get("pose")
    if not isinstance(pose, Mapping):
        return None
    position = pose.get("p")
    rotation = pose.get("q", (0.0, 0.0, 0.0, 1.0))
    if not isinstance(rotation, Sequence) or len(rotation) != 4:
        rotation = (0.0, 0.0, 0.0, 1.0)
    return rt.JointPose.create(
        position, _xyzw_to_wxyz(rotation), field_name=f"joints.{name}"
    )


# -- canonical result -> wire ----------------------------------------------


def result_to_wire(result, request: RetargetingRequest) -> WireResult:
    """Attach transport identity to a solve result the library produced."""
    return WireResult(
        frame_id=request.frame_id,
        timestamp_ns=request.timestamp_ns,
        profile_id=result.profile_id,
        output_type=result.output.output_type,
        positions=result.output.positions,
        joint_names=result.output.joint_names,
        status=result.status,
        iterations=result.iterations,
        solve_time_us=result.solve_time_us,
        metrics=result.metrics.as_dict(),
        degradation=dict(result.degradation),
    )


# -- XrFrame -> canonical input (Outside Python path) ----------------------


def skeleton_input_from_frame(frame: XrFrame):
    """Canonical skeleton from an ``XrFrame`` body snapshot, or ``None``.

    Returns ``None`` when the frame carries no usable body tracking; an unknown
    joint set is an error rather than a guess, because mis-named joints would
    retarget silently and wrongly.
    """
    rt = require_retargeting()
    body = frame.body
    if body is None or not body.active or not body.joints:
        return None
    try:
        names = BODY_JOINT_SETS[body.joint_set]
    except KeyError as exc:
        raise ProtocolError(
            "unsupported_joint_set",
            f"body joint set '{body.joint_set}' has no canonical joint names",
        ) from exc
    joints = {}
    for joint in body.joints:
        if not joint.tracked or not joint.pose.valid or joint.joint >= len(names):
            continue
        joints[names[joint.joint]] = rt.JointPose.create(
            joint.pose.position, _xyzw_to_wxyz(joint.pose.rotation)
        )
    if not joints:
        return None
    return rt.SkeletonInput(
        timestamp_ns=body.sample_timestamp_ns or frame.timestamp_ns,
        joints=joints,
        coordinate_space=frame.coordinate_space or "xr_origin",
    )


def end_effector_input_from_pose(pose: Pose, timestamp_ns: int = 0, gripper: float | None = None):
    """Canonical end-effector target from an Operator pose (xyzw rotation)."""
    rt = require_retargeting()
    return rt.EndEffectorInput(
        timestamp_ns=timestamp_ns or pose.sample_timestamp_ns,
        targets={
            "end_effector": rt.JointPose.create(
                pose.position, _xyzw_to_wxyz(pose.rotation)
            )
        },
        grippers={"end_effector": float(gripper)} if gripper is not None else {},
    )


class PyOperatorRetargeter:
    """A pyoperator :class:`~pyoperator.retargeting.Retargeter` backed by a
    retargeting profile.

    Use it in an Outside Python control loop when the robot is driven from the
    host: ``XrFrame`` in, :class:`~pyoperator.robot.JointTarget` out, solved by
    exactly the same profile and solver the Inside Remote service would use.

    ``source`` selects how the frame becomes solver input:

    - ``"body"`` — canonical skeleton from body tracking (humanoid profiles);
    - ``"controller"`` — a controller pose as an end-effector target, with the
      deadman-anchored mapping of
      :class:`~pyoperator.retargeting.PoseDeltaRetargeter`.
    """

    def __init__(
        self,
        profile_id: str,
        *,
        runtime=None,
        source: str = "body",
        pose_retargeter=None,
        hold_on_failure: bool = True,
    ) -> None:
        rt = require_retargeting()
        self.runtime = runtime or rt.RetargetingRuntime()
        self.profile = self.runtime.describe_profile(profile_id)
        if source not in {"body", "controller"}:
            raise ValueError("source must be 'body' or 'controller'")
        self.source = source
        self.hold_on_failure = hold_on_failure
        self._session = self.runtime.create_session(profile_id)
        self._pose_retargeter = pose_retargeter
        if self.source == "controller" and self._pose_retargeter is None:
            from ..retargeting import PoseDeltaRetargeter

            self._pose_retargeter = PoseDeltaRetargeter()
        self._last_target: JointTarget | None = None

    @property
    def session(self):
        return self._session

    def reset(self) -> None:
        self._session.reset()
        self._last_target = None
        if self._pose_retargeter is not None:
            self._pose_retargeter.reset()

    def close(self) -> None:
        self._session.close()

    def retarget(self, frame: XrFrame, robot_state: RobotState) -> JointTarget | None:
        source_input, gripper = self._input_for(frame, robot_state)
        if source_input is None:
            return None
        rt = require_retargeting()
        result = self._session.solve(source_input)
        if not rt.is_usable(result.status):
            # Snapping to an unconverged solution is worse than not moving.
            return self._last_target if self.hold_on_failure else None
        target = JointTarget.from_sequence(
            result.output.positions, gripper=gripper, timestamp_ns=frame.timestamp_ns
        )
        self._last_target = target
        return target

    def _input_for(self, frame: XrFrame, robot_state: RobotState):
        if self.source == "body":
            return skeleton_input_from_frame(frame), None
        command = self._pose_retargeter.retarget(frame, robot_state)
        if command is None:
            return None, None
        return (
            end_effector_input_from_pose(
                command.ee_pose, frame.timestamp_ns, command.gripper
            ),
            command.gripper,
        )


def _xyzw_to_wxyz(rotation: Sequence[float]) -> tuple[float, float, float, float]:
    """Operator/OpenXR quaternions are xyzw; retargeting uses wxyz."""
    x, y, z, w = (float(value) for value in rotation)
    return (w, x, y, z)


def _wire_error(exc: Exception) -> ProtocolError:
    """The library's input error as a wire error, keeping its reason code."""
    return ProtocolError(getattr(exc, "code", "invalid_frame"), str(exc))
