"""Small example-local contract. Algorithms own references and physics."""
from typing import Protocol, Any

from pyoperator.models import XrFrame


class Controller(Protocol):
    key: str
    name: str
    simulation: Any
    dt: float

    def extract(self, frame: XrFrame) -> Any: ...
    def pause(self) -> None: ...
    def reset(self) -> None: ...
    @property
    def control_enabled(self) -> bool: ...
    def control_tick(self, frame: XrFrame, sample: Any, now: float) -> str: ...
