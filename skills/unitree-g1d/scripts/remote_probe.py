#!/usr/bin/env python3
"""Run on the Conductor remote Ubuntu host. Only GET diagnostics and head JPEG capture."""
import argparse
import json
import re
import shlex
import subprocess
import sys

DEFAULT_HOST = "unitree@192.168.124.50"
BASE_URL = "http://192.168.123.163:1448"
CAMERA_PYTHON = "/home/unitree/miniconda3/envs/tv/bin/python"

# This code is sent through SSH to the robot, never executed on the local workstation.
REMOTE_PROGRAM = r'''
import base64, datetime, hashlib, json, math, sys, time, urllib.request, uuid
from pathlib import Path

def now():
    return datetime.datetime.now().astimezone().isoformat()

def artifact_path(value):
    path = Path(value)
    if not path.is_absolute():
        raise ValueError("Robot artifact path must be absolute")
    path = path.resolve()
    root = Path("/home/unitree/ws").resolve()
    if path != root and root not in path.parents:
        raise ValueError("Artifact path must be under /home/unitree/ws")
    return path

def perform(op, cfg):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def get(path):
        # No POST, PUT, DELETE, movement or shutdown interfaces in this helper.
        request = urllib.request.Request(cfg["base_url"] + path, method="GET")
        with opener.open(request, timeout=2) as response:
            return json.load(response)
    if op == "status":
        paths = {
            "health": "/api/core/system/v1/robot/health",
            "speed": "/api/core/motion/v1/speed",
            "info": "/api/core/system/v1/robot/info",
            "sensor_masks": "/api/core/sensors/v1/masks",
        }
        result = {"received_at": now(), "data": {}, "errors": {}}
        for key, path in paths.items():
            try:
                result["data"][key] = get(path)
            except Exception as exc:
                result["errors"][key] = str(exc)
        result["ok"] = not result["errors"]
        return result
    if op == "health-history":
        seconds = float(cfg["seconds"])
        if not math.isfinite(seconds) or not 1 <= seconds <= 60:
            raise ValueError("seconds must be finite, between 1 and 60")
        start = time.monotonic()
        rows = []
        while True:
            row = {"received_at": now(), "elapsed_s": round(time.monotonic() - start, 3)}
            try:
                row["health"] = get("/api/core/system/v1/robot/health")
            except Exception as exc:
                row["error"] = str(exc)
            rows.append(row)
            remaining = seconds - (time.monotonic() - start)
            if remaining <= 0:
                break
            time.sleep(min(1.0, remaining))
        return {"ok": all("error" not in row for row in rows), "samples": rows}
    if op == "capture-head":
        import cv2
        import numpy as np
        import zmq
        directory = artifact_path(cfg["out_dir"])
        context = zmq.Context()
        sock = context.socket(zmq.SUB)
        sock.setsockopt(zmq.SUBSCRIBE, b"")
        sock.setsockopt(zmq.CONFLATE, 1)
        sock.setsockopt(zmq.LINGER, 0)
        try:
            sock.connect("tcp://127.0.0.1:55555")
            if not sock.poll(4000):
                raise RuntimeError("No fresh head camera JPEG within 4 seconds")
            frame = sock.recv()
            received_at = now()
            if len(frame) > 10 * 1024 * 1024 or not frame.startswith(b"\xff\xd8"):
                raise RuntimeError("Invalid or oversized JPEG frame")
            picture = cv2.imdecode(np.frombuffer(frame, dtype=np.uint8), cv2.IMREAD_COLOR)
            if picture is None or picture.ndim != 3 or picture.shape[2] != 3:
                raise RuntimeError("JPEG did not decode to a color image")
            directory.mkdir(parents=True, exist_ok=True)
            name = "head-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8] + ".jpg"
            path = directory / name
            with path.open("xb") as output:
                output.write(frame)
            return {"ok": True, "path": str(path), "received_at": received_at,
                    "timestamp_kind": "host_receive_time_not_exposure_time",
                    "shape": list(picture.shape), "mean_brightness": float(picture.mean()),
                    "bytes": len(frame), "sha256": hashlib.sha256(frame).hexdigest()}
        finally:
            sock.close(0)
            context.term()
    if op == "image-chunk":
        path = artifact_path(cfg["path"])
        offset, count = int(cfg["offset"]), int(cfg["count"])
        if offset < 0 or not 1 <= count <= 30000:
            raise ValueError("offset >= 0 and count in [1, 30000] required")
        if path.stat().st_size > 10 * 1024 * 1024:
            raise ValueError("Image exceeds 10 MiB limit")
        frame = path.read_bytes()
        if not frame.startswith(b"\xff\xd8"):
            raise ValueError("Expected original JPEG")
        encoded = base64.b64encode(frame).decode("ascii")
        if offset >= len(encoded):
            raise ValueError("offset is beyond the image")
        return {"ok": True, "path": str(path), "offset": offset,
                "total_chars": len(encoded), "sha256": hashlib.sha256(frame).hexdigest(),
                "chunk": encoded[offset:offset + count]}
    raise ValueError("Unknown read-only operation")
'''

def summarize_health(health):
    """Interpret reported alarms; never infer camera damage or motion clearance."""
    if not isinstance(health, dict):
        return {"health_available": False, "motion_clearance_assessed": False}
    entries = health.get("baseError") or []
    codes = set()
    for entry in entries:
        try:
            value = entry.get("errorCode")
            codes.add(int(value, 0) if isinstance(value, str) else int(value))
        except (TypeError, ValueError, AttributeError):
            continue
    return {
        "health_available": True,
        "emergency_stop_reported": bool(health.get("hasSystemEmergencyStop") or 33620224 in codes),
        "brake_released_reported": 33621760 in codes,
        "depth_warning_reported": bool(health.get("hasDepthCameraDisconnected") or 17041920 in codes),
        "reported_error_or_fatal": bool(health.get("hasError") or health.get("hasFatal")),
        "raw_alarm_count": len(entries),
        "depth_camera_identity": "not_determined_by_this_helper",
        "motion_clearance_assessed": False,
    }

def build_command(args):
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*@[A-Za-z0-9][A-Za-z0-9.-]*", args.host):
        raise ValueError("host must be a user@hostname or user@IPv4 address")
    config = {"base_url": BASE_URL}
    if args.operation == "health-history":
        config["seconds"] = args.seconds
    elif args.operation == "capture-head":
        config["out_dir"] = args.out_dir
    elif args.operation == "image-chunk":
        config.update(path=args.path, offset=args.offset, count=args.count)
    source = REMOTE_PROGRAM + "\ntry:\n    result = perform(" + repr(args.operation) + ", json.loads(" + repr(json.dumps(config)) + "))\n    print(json.dumps(result, ensure_ascii=False, allow_nan=False))\n    sys.exit(0 if result.get('ok') else 2)\nexcept Exception as exc:\n    print(json.dumps({'ok':False, 'error':str(exc)}))\n    sys.exit(2)\n"
    interpreter = CAMERA_PYTHON if args.operation == "capture-head" else "python3"
    remote = "PYTHONDONTWRITEBYTECODE=1 " + shlex.quote(interpreter) + " -c " + shlex.quote(source)
    return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o",
            "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2", args.host, remote]

def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", default=DEFAULT_HOST, help="SSH destination reachable from remote Ubuntu")
    sub = p.add_subparsers(dest="operation", required=True)
    sub.add_parser("status", help="GET health, speed, device info and sensor masks")
    history = sub.add_parser("health-history", help="Sample raw health for a bounded duration")
    history.add_argument("--seconds", type=float, default=10)
    camera = sub.add_parser("capture-head", help="Save a new original head JPEG on the robot")
    camera.add_argument("--out-dir", default="/home/unitree/ws/g1d-artifacts")
    chunk = sub.add_parser("image-chunk", help="Read at most 30000 base64 chars of a robot JPEG")
    chunk.add_argument("--path", required=True)
    chunk.add_argument("--offset", type=int, default=0)
    chunk.add_argument("--count", type=int, default=30000)
    return p

def main(argv=None):
    args = parser().parse_args(argv)
    try:
        if args.operation == "health-history":
            import math
            if not math.isfinite(args.seconds) or not 1 <= args.seconds <= 60:
                raise ValueError("seconds must be finite, between 1 and 60")
        timeout = args.seconds + 25 if args.operation == "health-history" else 30
        result = subprocess.run(build_command(args), capture_output=True, text=True, timeout=timeout)
        if not result.stdout.strip():
            raise RuntimeError("SSH/read-only probe failed: " + result.stderr.strip()[:1200])
        payload = json.loads(result.stdout)
        if args.operation == "status":
            payload["interpretation"] = summarize_health(payload.get("data", {}).get("health"))
        elif args.operation == "health-history":
            observations = [summarize_health(row.get("health")) for row in payload.get("samples", [])]
            payload["depth_warning_samples"] = sum(x.get("depth_warning_reported", False) for x in observations)
            payload["camera_failure_inferred"] = False
        print(json.dumps(payload, ensure_ascii=False, allow_nan=False))
        return 0 if result.returncode == 0 and payload.get("ok") else 2
    except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
        print(json.dumps({"ok": False, "error": str(exc), "motion_command_sent": False}, ensure_ascii=False))
        return 2

if __name__ == "__main__":
    raise SystemExit(main())
