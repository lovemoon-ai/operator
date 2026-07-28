#!/usr/bin/env python3
"""Compatibility entry point for the pyoperator Live Feed server."""

from __future__ import annotations

import sys
from pathlib import Path


# Keep this historical checkout command working without requiring installation.
PYTHON_ROOT = Path(__file__).resolve().parents[2] / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from pyoperator.live_feed import main  # noqa: E402


if __name__ == "__main__":
    raise SystemExit(main())
