#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13,<3.14"
# dependencies = [
#     "rerun-sdk==0.33.*",
#     "numpy>=1.26.0",
#     "scipy>=1.11.0",
#     "opencv-python>=4.8.0",
# ]
# ///
"""Pico SpatialMP4 -> Rerun .rrd converter.

The heavy implementation lives in spatialmp4_to_rrd.py. This wrapper mirrors
SpatialMP4's dedicated visualize_rerun_pico.py entrypoint by forcing the Pico
device profile, while keeping all ingest-specific logging and artifacts in one
converter.
"""

from __future__ import annotations

import runpy
import sys
from pathlib import Path


def _force_pico_device_type(argv: list[str]) -> list[str]:
    cleaned: list[str] = []
    skip_next = False
    for arg in argv:
        if skip_next:
            skip_next = False
            continue
        if arg == "--device-type":
            skip_next = True
            continue
        if arg.startswith("--device-type="):
            continue
        cleaned.append(arg)
    cleaned.extend(["--device-type", "pico"])
    return cleaned


if __name__ == "__main__":
    target = Path(__file__).with_name("spatialmp4_to_rrd.py")
    sys.argv = _force_pico_device_type(sys.argv)
    sys.argv[0] = str(target)
    runpy.run_path(str(target), run_name="__main__")
