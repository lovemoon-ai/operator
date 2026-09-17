#!/usr/bin/env python3
"""Reject direct tracker lifecycle/data calls outside the shared service.

Static ownership contract only; this does not replace Pico device coverage.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "xr" / "scripts"
OWNER = SCRIPTS / "xr" / "tracking_session_service.gd"
METHODS = (
    "start_body_tracking", "stop_body_tracking", "sample_body_joints",
    "request_motion_trackers", "sample_motion_trackers",
    "start_body_tracking_calibration_app", "get_tracking_continuity_state",
    "set_tracking_monitor_enabled",
)
methods = "(?:" + "|".join(METHODS) + ")"
CALL = re.compile(r"\.\s*(?:call\s*\(\s*[\"']" + methods + r"[\"']|" + methods + r"\s*\()")
errors = []
for path in sorted(SCRIPTS.rglob("*.gd")):
    if path == OWNER or "test_support" in path.parts:
        continue
    source = re.sub(r"(?m)^[ \t]*#.*$", "", path.read_text())
    for match in CALL.finditer(source):
        line = source.count("\n", 0, match.start()) + 1
        errors.append(f"{path.relative_to(ROOT)}:{line}: use TrackingSessionService instead of {match.group()}")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print("validate_tracking_ownership: OK")
