"""pytest hardware selection for opt-in Operator XR device tests."""

from __future__ import annotations

from dataclasses import dataclass
import os
import shutil
import subprocess
from typing import Sequence

import pytest


@dataclass(frozen=True)
class AdbXrDevice:
    adb: str
    serial: str
    kind: str
    identity: str

    def run(
        self,
        *args: str,
        check: bool = True,
        timeout: float = 30.0,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [self.adb, "-s", self.serial, *args],
            check=check,
            capture_output=True,
            text=True,
            timeout=timeout,
        )


def pytest_addoption(parser: pytest.Parser) -> None:
    group = parser.getgroup("pyoperator device tests")
    group.addoption(
        "--run-device",
        action="store_true",
        help="run tests that require a physical XR device",
    )
    group.addoption(
        "--require-device",
        action="store_true",
        help="fail instead of skip when the requested XR device is unavailable",
    )
    group.addoption(
        "--xr-device",
        choices=("auto", "quest", "pico"),
        default="auto",
        help="physical XR device family to select (default: auto)",
    )
    group.addoption(
        "--adb-serial",
        default=(
            os.environ.get("ADB_SERIAL")
            or os.environ.get("ANDROID_SERIAL")
            or os.environ.get("PICO_SERIAL")
            or os.environ.get("QUEST_SERIAL")
            or ""
        ),
        help="adb serial for the XR device",
    )
    group.addoption(
        "--xr-apk",
        default="",
        help="optional APK to install before the real-headset test",
    )
    group.addoption(
        "--xr-frame-timeout",
        type=float,
        default=45.0,
        help="seconds to wait for real XrStateFrame samples",
    )
    group.addoption(
        "--xr-min-frames",
        type=int,
        default=10,
        help="minimum real frames required by the device smoke test",
    )


def _unavailable(request: pytest.FixtureRequest, reason: str) -> None:
    if request.config.getoption("--require-device"):
        pytest.fail(reason, pytrace=False)
    pytest.skip(reason)


def _adb_devices(adb: str) -> list[str]:
    result = subprocess.run(
        [adb, "devices"],
        check=False,
        capture_output=True,
        text=True,
        timeout=10.0,
    )
    if result.returncode != 0:
        return []
    return [
        line.split()[0]
        for line in result.stdout.splitlines()[1:]
        if len(line.split()) >= 2 and line.split()[1] == "device"
    ]


def _device_identity(adb: str, serial: str) -> str:
    command: Sequence[str] = (
        adb,
        "-s",
        serial,
        "shell",
        "getprop",
    )
    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        timeout=10.0,
    )
    return result.stdout.lower()


def _device_kind(identity: str) -> str | None:
    if any(
        token in identity
        for token in (
            "oculus",
            "meta",
            "quest",
            "hollywood",
            "eureka",
            "panther",
            "seacliff",
        )
    ):
        return "quest"
    if "pico" in identity or "picovr" in identity:
        return "pico"
    return None


@pytest.fixture(scope="session")
def xr_device(request: pytest.FixtureRequest) -> AdbXrDevice:
    """Return a real Quest/Pico, or visibly skip the collected device case."""
    if not request.config.getoption("--run-device"):
        _unavailable(
            request,
            "real XR headset test disabled; pass --run-device to enable it",
        )

    adb_name = os.environ.get("ADB", "adb")
    adb = shutil.which(adb_name)
    if adb is None:
        _unavailable(request, f"adb executable not found: {adb_name}")
        raise AssertionError("unreachable")

    requested_serial = str(request.config.getoption("--adb-serial"))
    requested_kind = str(request.config.getoption("--xr-device"))
    serials = _adb_devices(adb)
    if requested_serial:
        if requested_serial not in serials:
            _unavailable(request, f"adb device {requested_serial!r} is not connected")
            raise AssertionError("unreachable")
        serials = [requested_serial]

    matches: list[AdbXrDevice] = []
    for serial in serials:
        identity = _device_identity(adb, serial)
        kind = _device_kind(identity)
        if kind is not None and requested_kind in ("auto", kind):
            matches.append(AdbXrDevice(adb, serial, kind, identity))

    if not matches:
        _unavailable(request, f"no connected {requested_kind} Quest/Pico headset found via adb")
        raise AssertionError("unreachable")
    if len(matches) > 1:
        serial_list = ", ".join(device.serial for device in matches)
        pytest.fail(
            f"multiple XR devices match ({serial_list}); pass --adb-serial",
            pytrace=False,
        )
    return matches[0]
