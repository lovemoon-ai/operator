"""Test-side helpers for driving a Live Feed server without a headset.

The OLCP payload builders and the push client live in
:mod:`pyoperator.live_feed.simulator` so tests and the shipped simulator CLI
cannot drift apart. This module only adds test-only extras (the stub ffmpeg).
"""

from __future__ import annotations

import os
import stat
import sys
import textwrap
from pathlib import Path

from pyoperator.live_feed.simulator import (  # noqa: F401 - re-exported for tests
    SyntheticHeadset,
    controller_input_payload,
    controller_pose_payload,
    depth_frame_frame,
    hand_joints_payload,
    head_pose_payload,
    rgb_csd_payload,
    session_start_payload,
    stream_session,
    walk_position,
)


#: Historical alias: tests refer to the push client as ``FakeHeadset``.
FakeHeadset = SyntheticHeadset


FAKE_FFMPEG_SOURCE = textwrap.dedent(
    """\
    #!{python}
    import os, sys
    size = int(os.environ["FAKE_FFMPEG_FRAME_BYTES"])
    frames = int(os.environ["FAKE_FFMPEG_FRAMES"])
    for index in range(frames):
        sys.stdout.buffer.write(bytes([index % 256]) * size)
    sys.stdout.buffer.flush()
    while sys.stdin.buffer.read(4096):
        pass
    """
)


def make_fake_ffmpeg(directory: Path, frame_bytes: int, frames: int) -> str:
    """Write a stub ``ffmpeg`` that emits ``frames`` raw RGB frames.

    Lets the decoder's subprocess plumbing be tested on any host; real codec
    behaviour stays covered by the device E2E script. Sets the environment the
    stub reads, so callers should clean those keys up.
    """
    path = directory / "fake-ffmpeg"
    path.write_text(FAKE_FFMPEG_SOURCE.format(python=sys.executable))
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    os.environ["FAKE_FFMPEG_FRAME_BYTES"] = str(frame_bytes)
    os.environ["FAKE_FFMPEG_FRAMES"] = str(frames)
    return str(path)


def clear_fake_ffmpeg_env() -> None:
    os.environ.pop("FAKE_FFMPEG_FRAME_BYTES", None)
    os.environ.pop("FAKE_FFMPEG_FRAMES", None)
