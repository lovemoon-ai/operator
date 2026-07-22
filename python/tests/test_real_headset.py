"""Opt-in smoke test for the physical headset -> pyoperator state path."""

from __future__ import annotations

import socket
import subprocess
import time
from pathlib import Path
from typing import Optional, Protocol

import pytest

from pyoperator.session import BridgeConfig, XrSession


PACKAGE = "com.lovemoon.operator"
ACTIVITY = "com.godot.game.GodotApp"

pytestmark = [pytest.mark.device, pytest.mark.xr_device]


class XrDevice(Protocol):
    serial: str
    kind: str

    def run(
        self,
        *args: str,
        check: bool = True,
        timeout: float = 30.0,
    ) -> subprocess.CompletedProcess[str]: ...


def _tcp_port() -> int:
    with socket.socket() as sock:
        sock.bind(("0.0.0.0", 0))
        return int(sock.getsockname()[1])


def _udp_port() -> int:
    with socket.socket(type=socket.SOCK_DGRAM) as sock:
        sock.bind(("0.0.0.0", 0))
        return int(sock.getsockname()[1])


def _logcat_tail(device: XrDevice) -> str:
    try:
        pid_result = device.run("shell", "pidof", PACKAGE, check=False)
        pids = pid_result.stdout.strip().split()
        args = ["logcat", "-d", "-v", "threadtime"]
        if pids:
            args.extend(("--pid", pids[0]))
        result = device.run(*args, check=False)
    except (OSError, subprocess.SubprocessError) as error:
        return f"<logcat unavailable: {error}>"
    output = result.stdout + result.stderr
    if not pids:
        relevant = [
            line
            for line in output.splitlines()
            if any(
                marker in line
                for marker in ("godot", "GODOT", "Operator", PACKAGE, "AndroidRuntime")
            )
        ]
        output = "\n".join(relevant)
    return output[-40_000:]


def _prepare_headset(device: XrDevice) -> None:
    """Mirror the proven Quest launch preparation in cicd/02_ego_record.sh."""
    device.run("shell", "am", "force-stop", PACKAGE, check=False)
    device.run("shell", "am", "force-stop", "com.oculus.guardian", check=False)
    device.run(
        "shell",
        "am",
        "force-stop",
        "com.android.permissioncontroller",
        check=False,
    )
    device.run("shell", "input", "keyevent", "KEYCODE_WAKEUP", check=False)
    device.run("shell", "wm", "dismiss-keyguard", check=False)
    device.run(
        "shell",
        "am",
        "broadcast",
        "-a",
        "com.oculus.vrpowermanager.prox_close",
        check=False,
    )
    device.run(
        "shell",
        "am",
        "broadcast",
        "-a",
        "android.intent.action.CLOSE_SYSTEM_DIALOGS",
        check=False,
    )
    device.run("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
    time.sleep(1.0)
    device.run("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
    device.run("logcat", "-c", check=False)


def _launch_teleop(device: XrDevice, pose_port: int) -> None:
    launch = device.run(
        "shell",
        "am",
        "start",
        "-n",
        f"{PACKAGE}/{ACTIVITY}",
        "--es",
        "operator.mode",
        "teleop",
        "--es",
        "operator.teleop.host",
        "127.0.0.1",
        "--es",
        "operator.teleop.port",
        str(pose_port),
    )
    assert "Error" not in launch.stdout, launch.stdout + launch.stderr


def _script_startup_error(logcat: str) -> Optional[str]:
    markers = (
        "SCRIPT ERROR",
        "Parse Error",
        "Failed to load script",
        "FATAL EXCEPTION",
    )
    if any(marker in logcat for marker in markers):
        return logcat
    return None


def _best_effort(device: XrDevice, *args: str) -> None:
    """Keep cleanup failures from replacing the useful assertion/adb error."""
    try:
        device.run(*args, check=False)
    except (OSError, subprocess.SubprocessError):
        pass


def test_pyoperator_receives_real_headset_frames(
    request: pytest.FixtureRequest,
    xr_device: XrDevice,
) -> None:
    """Exercise real OpenXR tracking, Godot framing, TCP, PyO3, and models."""
    pose_port = _tcp_port()
    config = BridgeConfig(
        name="pyoperator_real_headset_test",
        pose_port=pose_port,
        discovery_port=_udp_port(),
        pose_udp_port=_udp_port(),
        telemetry_port=_tcp_port(),
    )
    timeout = float(request.config.getoption("--xr-frame-timeout"))
    minimum = int(request.config.getoption("--xr-min-frames"))
    if timeout <= 0 or minimum <= 0:
        pytest.fail("--xr-frame-timeout and --xr-min-frames must be positive")

    apk = str(request.config.getoption("--xr-apk"))
    if apk:
        apk_path = Path(apk).expanduser().resolve()
        if not apk_path.is_file():
            pytest.fail(f"--xr-apk does not exist: {apk_path}")
        xr_device.run("install", "-r", "-d", str(apk_path), timeout=180.0)
    else:
        installed = xr_device.run("shell", "pm", "path", PACKAGE, check=False)
        if installed.returncode != 0 or "package:" not in installed.stdout:
            pytest.fail(f"{PACKAGE} is not installed; pass --xr-apk")

    reverse = f"tcp:{pose_port}"
    session = XrSession(config)
    frames = []
    try:
        session.start()
        xr_device.run("reverse", reverse, reverse)
        _prepare_headset(xr_device)
        _launch_teleop(xr_device, pose_port)

        deadline = time.monotonic() + timeout
        frame_id = 0
        next_startup_check = time.monotonic() + 3.0
        while len(frames) < minimum and time.monotonic() < deadline:
            frame = session.wait_next(frame_id, timeout=1.0)
            if frame is None:
                now = time.monotonic()
                if now >= next_startup_check:
                    startup_log = _logcat_tail(xr_device)
                    startup_error = _script_startup_error(startup_log)
                    if startup_error is not None:
                        pytest.fail(
                            "headset app failed during teleop startup:\n"
                            f"{startup_error}"
                        )
                    next_startup_check = now + 3.0
                continue
            frame_id = frame.frame_id
            frames.append(frame)

        stats = session.stats()
        assert len(frames) >= minimum, (
            f"received {len(frames)}/{minimum} real XR frames; stats={stats}\n"
            f"device logcat tail:\n{_logcat_tail(xr_device)}"
        )
        assert stats.connected
        assert stats.frames_received >= minimum
        assert all(frame.timestamp_ns > 0 for frame in frames)
        assert all(
            current.timestamp_ns >= previous.timestamp_ns
            for previous, current in zip(frames, frames[1:])
        )
        assert any(frame.head is not None and frame.head.valid for frame in frames), (
            "real OpenXR stream produced no valid head pose\n"
            f"device logcat tail:\n{_logcat_tail(xr_device)}"
        )
    finally:
        session.close()
        _best_effort(xr_device, "shell", "am", "force-stop", PACKAGE)
        _best_effort(xr_device, "reverse", "--remove", reverse)
