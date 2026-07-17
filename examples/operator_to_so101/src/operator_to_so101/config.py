"""Configuration for the Operator controller input."""

from dataclasses import dataclass, field

_DEFAULT_BASE_T_ANCHOR = [
    [0.0, 0.0, -1.0, 0.0],
    [-1.0, 0.0, 0.0, 0.0],
    [0.0, 1.0, 0.0, 0.0],
    [0.0, 0.0, 0.0, 1.0],
]


@dataclass(kw_only=True)
class OperatorControllerConfig:
    """Operator UDS input and physical-arm safety settings.

    Operator owns OpenXR and rendering. ``xr-bridge`` forwards canonical
    controller/control packets to ``socket_path``; this process owns that UDS
    receiver and LeRobot owns the follower serial port.
    """

    socket_path: str = "/tmp/operator-isaacteleop.sock"
    token: int | None = 0
    max_age_ms: float = 100.0
    hand_side: str = "right"
    clutch_threshold: float = 0.5
    max_ee_step_m: float = 0.03
    require_run_toggle: bool = True
    wait_timeout_s: float = 60.0
    base_T_anchor: list[list[float]] = field(
        default_factory=lambda: [row.copy() for row in _DEFAULT_BASE_T_ANCHOR]
    )

    def __post_init__(self) -> None:
        if self.hand_side != "right":
            raise ValueError(
                "operator_to_so101 v1 requires hand_side='right' because Operator CTRL "
                "deadman/run/reset is generated from the right controller"
            )
        if not 0.0 <= self.clutch_threshold <= 1.0:
            raise ValueError("clutch_threshold must be in [0, 1]")
        if not 0.0 < self.max_ee_step_m <= 0.1:
            raise ValueError("max_ee_step_m must be in (0, 0.1]")
        if self.max_age_ms <= 0.0:
            raise ValueError("max_age_ms must be positive")
        if self.wait_timeout_s <= 0.0:
            raise ValueError("wait_timeout_s must be positive")
        if self.token is not None and not 0 <= self.token <= 0xFFFFFFFF:
            raise ValueError("token must fit in an unsigned 32-bit integer")
