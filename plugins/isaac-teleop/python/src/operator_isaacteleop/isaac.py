"""Lazy bindings to public IsaacTeleop APIs.

No import in this module executes until a binding method is called.  This is
important because Isaac Sim owns a specialized Python environment and because
the transport unit tests must run on ordinary CPython.
"""

from __future__ import annotations

import importlib
from collections.abc import Callable
from dataclasses import dataclass
from enum import Enum
from typing import Any


class IsaacTeleopUnavailable(RuntimeError):
    pass


class PortableExecutionState(str, Enum):
    STOPPED = "stopped"
    PAUSED = "paused"
    RUNNING = "running"


@dataclass(frozen=True, slots=True)
class PortableExecutionEvents:
    reset: bool = False
    execution_state: PortableExecutionState = PortableExecutionState.STOPPED


class LazyIsaacTeleopBindings:
    """Resolver for the small public API surface used by this plugin."""

    def __init__(self, module_loader: Callable[[str], Any] | None = None) -> None:
        self._module_loader = module_loader or importlib.import_module

    def module(self, name: str):
        """Import a dependency on demand; public for standard adapters/tests."""

        try:
            return self._module_loader(name)
        except ImportError as exc:
            raise IsaacTeleopUnavailable(
                "IsaacTeleop is not importable. Install the plugin wheel inside the "
                "Isaac Sim environment and install/pin NVIDIA IsaacTeleop there."
            ) from exc

    def value_input(self, name: str, tensor_type: Any) -> Any:
        module = self.module("isaacteleop.retargeting_engine.interface.value_input")
        return module.ValueInput(name, tensor_type)

    def graph_time(self, time_ns: int) -> Any:
        module = self.module("isaacteleop.retargeting_engine.interface.retargeter_core_types")
        return module.GraphTime(sim_time_ns=time_ns, real_time_ns=time_ns)

    def execution_events(self, events: PortableExecutionEvents) -> Any:
        module = self.module("isaacteleop.retargeting_engine.interface.execution_events")
        state = module.ExecutionState(events.execution_state.value)
        return module.ExecutionEvents(reset=events.reset, execution_state=state)


def action_to_torch(result: Any, *, output_name: str = "action", device: str | None = None):
    """Convert a standard IsaacTeleop action output through DLPack lazily."""

    action = result[output_name][0] if isinstance(result, dict) else result
    try:
        torch = importlib.import_module("torch")
    except ImportError as exc:
        raise IsaacTeleopUnavailable("Torch is required to convert an IsaacTeleop action") from exc
    tensor = torch.from_dlpack(action)
    kwargs: dict[str, Any] = {"dtype": torch.float32}
    if device is not None:
        kwargs["device"] = device
    return tensor.to(**kwargs)
