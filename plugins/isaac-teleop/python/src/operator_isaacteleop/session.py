"""Dependency-injected external session and Isaac Lab-style device facade."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any, Protocol

from .isaac import (
    LazyIsaacTeleopBindings,
    PortableExecutionEvents,
    PortableExecutionState,
    action_to_torch,
)
from .model import ControlSample, ExternalInputBundle
from .protocol import Kind


class SessionProtocol(Protocol):
    def step(
        self, *, external_inputs: dict[str, Any], graph_time: Any, execution_events: Any
    ) -> Any: ...


_INPUT_NAMES = {
    Kind.HEAD: "operator_head",
    Kind.LEFT_CONTROLLER: "operator_left_controller",
    Kind.RIGHT_CONTROLLER: "operator_right_controller",
    Kind.LEFT_HAND: "operator_left_hand",
    Kind.RIGHT_HAND: "operator_right_hand",
    Kind.BODY: "operator_body",
    Kind.ANCHOR: "world_T_anchor",
}


class PortableStateManager:
    """Bootstrap/test fallback for STOPPED/PAUSED/RUNNING toggles.

    Production factories run upstream ``DefaultTeleopStateManager`` as the
    session's ``teleop_control_pipeline``. This fallback mirrors its state
    sequence for dependency-free smoke tests.
    """

    def __init__(self) -> None:
        self.state = PortableExecutionState.STOPPED
        self._previous_toggle = False
        self._previous_reset = False

    def update(self, control: ControlSample | None) -> PortableExecutionEvents:
        if control is None:
            self.state = PortableExecutionState.STOPPED
            self._previous_toggle = False
            self._previous_reset = False
            return PortableExecutionEvents(False, self.state)
        reset = control.reset and not self._previous_reset
        toggle = control.run_toggle and not self._previous_toggle
        self._previous_reset = control.reset
        self._previous_toggle = control.run_toggle
        if control.kill or not control.deadman:
            self.state = PortableExecutionState.STOPPED
            return PortableExecutionEvents(True, self.state)
        if toggle:
            if self.state is PortableExecutionState.STOPPED:
                self.state = PortableExecutionState.PAUSED
            elif self.state is PortableExecutionState.PAUSED:
                self.state = PortableExecutionState.RUNNING
            else:
                self.state = PortableExecutionState.PAUSED
        return PortableExecutionEvents(reset, self.state)


class CanonicalInputAdapter:
    """Build leaf-keyed external inputs with injectable TensorGroup converters.

    A converter receives a canonical value and returns a RetargeterIO object,
    normally ``{ValueInput.VALUE: TensorGroup(...)}``.  Without converters the
    canonical value is passed through, which keeps fake-session tests simple.
    """

    def __init__(
        self,
        converters: dict[Kind, Callable[[Any], Any]] | None = None,
        input_names: dict[Kind, str] | None = None,
    ) -> None:
        self.converters = converters or {}
        self.input_names = {**_INPUT_NAMES, **(input_names or {})}

    def __call__(self, bundle: ExternalInputBundle) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for kind, sample in bundle.samples.items():
            if kind is Kind.CONTROL or kind not in self.input_names:
                continue
            converter = self.converters.get(kind)
            result[self.input_names[kind]] = converter(sample.value) if converter else sample.value
        return result


class ExternalTeleopSession:
    """Drive a TeleopSession-compatible object entirely from Operator inputs.

    Current upstream IsaacTeleop LIVE sessions still initialize OpenXR even when
    all graph leaves are external.  Production use therefore requires the
    plugin's pinned ``SessionMode.EXTERNAL`` upstream patch (or an equivalent
    injected session).  This class intentionally does not copy or monkey-patch
    TeleopSession private implementation.
    """

    def __init__(
        self,
        session: SessionProtocol,
        *,
        input_adapter: Callable[[ExternalInputBundle], dict[str, Any]] | None = None,
        event_adapter: Callable[[PortableExecutionEvents], Any] | None = None,
        graph_time_adapter: Callable[[int], Any] | None = None,
        state_manager: PortableStateManager | None = None,
        execution_events_provider: Callable[[ControlSample | None], Any] | None = None,
        session_control_pipeline: bool = False,
    ) -> None:
        self.session = session
        self.input_adapter = input_adapter or CanonicalInputAdapter()
        self.event_adapter = event_adapter or (lambda events: events)
        self.graph_time_adapter = graph_time_adapter or (lambda value: value)
        self.state_manager = state_manager or PortableStateManager()
        self.execution_events_provider = execution_events_provider
        self.session_control_pipeline = session_control_pipeline
        self._entered = False

    @classmethod
    def for_isaacteleop(
        cls,
        session: SessionProtocol,
        *,
        input_adapter: Callable[[ExternalInputBundle], dict[str, Any]],
        execution_events_provider: Callable[[ControlSample | None], Any] | None = None,
        session_control_pipeline: bool = True,
        bindings: LazyIsaacTeleopBindings | None = None,
    ) -> ExternalTeleopSession:
        bindings = bindings or LazyIsaacTeleopBindings()
        return cls(
            session,
            input_adapter=input_adapter,
            graph_time_adapter=bindings.graph_time,
            execution_events_provider=execution_events_provider,
            session_control_pipeline=session_control_pipeline,
        )

    def step(self, bundle: ExternalInputBundle, *, execution_events: Any | None = None) -> Any:
        control_timed = bundle.get(Kind.CONTROL)
        control = control_timed.value if control_timed is not None else None
        if control is not None and not isinstance(control, ControlSample):
            raise TypeError("CTRL channel did not contain ControlSample")
        if execution_events is None:
            if self.session_control_pipeline:
                # The patched EXTERNAL TeleopSession runs its configured
                # teleop_control_pipeline and creates official ExecutionEvents.
                pass
            elif self.execution_events_provider is not None:
                execution_events = self.execution_events_provider(control)
            else:
                execution_events = self.event_adapter(self.state_manager.update(control))
        return self.session.step(
            external_inputs=self.input_adapter(bundle),
            graph_time=self.graph_time_adapter(bundle.graph_time_ns),
            execution_events=execution_events,
        )

    def __enter__(self) -> ExternalTeleopSession:
        enter = getattr(self.session, "__enter__", None)
        if enter is not None:
            entered = enter()
            if entered is not None:
                self.session = entered
        self._entered = True
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        exit_method = getattr(self.session, "__exit__", None)
        if self._entered and exit_method is not None:
            exit_method(exc_type, exc_value, traceback)
        self._entered = False


class ReceiverProtocol(Protocol):
    def start(self, *, background: bool = True) -> Any: ...
    def snapshot(self, *, now_ns: int | None = None) -> ExternalInputBundle: ...
    def close(self) -> None: ...


class OperatorIsaacTeleopDevice:
    """Isaac Lab-style ``advance/reset/add_callback`` facade."""

    def __init__(
        self,
        receiver: ReceiverProtocol,
        session: ExternalTeleopSession,
        *,
        action_adapter: Callable[[Any], Any] | None = None,
        device: str | None = None,
    ) -> None:
        self.receiver = receiver
        self.session = session
        self.action_adapter = action_adapter or (
            lambda result: action_to_torch(result, device=device)
        )
        self._callbacks: dict[str, list[Callable[[], None]]] = {}
        self._entered = False

    def add_callback(self, key: str, callback: Callable[[], None]) -> None:
        self._callbacks.setdefault(key, []).append(callback)

    def reset(self) -> None:
        self.session.state_manager = PortableStateManager()
        for callback in self._callbacks.get("reset", ()):
            callback()

    def advance(self) -> Any | None:
        bundle = self.receiver.snapshot()
        result = self.session.step(bundle)
        for callback in self._callbacks.get("step", ()):
            callback()
        return self.action_adapter(result)

    def __enter__(self) -> OperatorIsaacTeleopDevice:
        self.receiver.start(background=True)
        self.session.__enter__()
        self._entered = True
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        try:
            if self._entered:
                self.session.__exit__(exc_type, exc_value, traceback)
        finally:
            self.receiver.close()
            self._entered = False
