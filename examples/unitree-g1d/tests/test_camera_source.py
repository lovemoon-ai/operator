#!/usr/bin/env python3

import importlib.util
from pathlib import Path
import sys


def load_module(path: Path):
    spec = importlib.util.spec_from_file_location("teleimager_h264", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    module = load_module(Path(sys.argv[1]).resolve())

    left = module.build_ffmpeg_command("/usr/bin/ffmpeg", 30, "left")
    assert left[0] == "/usr/bin/ffmpeg"
    left_filter = left[left.index("-vf") + 1]
    assert "crop=iw/2:ih:0:0" in left_filter
    assert "curves=master=" in left_filter
    assert "colorbalance=" in left_filter
    assert "libx264" in left
    assert "repeat-headers=1" in left
    assert left[-3:] == ["-f", "h264", "pipe:1"]

    right = module.build_ffmpeg_command("ffmpeg", 24, "right")
    assert "crop=iw/2:ih:iw/2:0" in right[right.index("-vf") + 1]
    assert right[right.index("-g") + 1] == "24"

    stereo = module.build_ffmpeg_command("ffmpeg", 30, "stereo")
    assert "-vf" not in stereo

    uncorrected = module.build_ffmpeg_command("ffmpeg", 30, "left", False)
    assert uncorrected[uncorrected.index("-vf") + 1] == "crop=iw/2:ih:0:0"
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
