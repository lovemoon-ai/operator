#!/usr/bin/env python3
"""Move the G1-D left arm to a nearly straight, forward Cartesian pose via IK."""

from __future__ import annotations

import json
import math
import socket
import struct
import threading
import time
from typing import Any, List


Matrix = List[List[float]]
Vector = List[float]


def matmul(a: Matrix, b: Matrix) -> Matrix:
    return [[sum(a[r][k] * b[k][c] for k in range(3)) for c in range(3)] for r in range(3)]


def matvec(a: Matrix, b: Vector) -> Vector:
    return [sum(a[r][k] * b[k] for k in range(3)) for r in range(3)]


def transpose(a: Matrix) -> Matrix:
    return [[a[c][r] for c in range(3)] for r in range(3)]


def quaternion_matrix(x: float, y: float, z: float, w: float) -> Matrix:
    length = math.sqrt(x * x + y * y + z * z + w * w)
    x, y, z, w = x / length, y / length, z / length, w / length
    return [
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ]


def matrix_quaternion(r: Matrix) -> Vector:
    trace = r[0][0] + r[1][1] + r[2][2]
    if trace > 0:
        scale = math.sqrt(trace + 1.0) * 2.0
        return [(r[2][1] - r[1][2]) / scale, (r[0][2] - r[2][0]) / scale,
                (r[1][0] - r[0][1]) / scale, 0.25 * scale]
    if r[0][0] > r[1][1] and r[0][0] > r[2][2]:
        scale = math.sqrt(1.0 + r[0][0] - r[1][1] - r[2][2]) * 2.0
        return [0.25 * scale, (r[0][1] + r[1][0]) / scale,
                (r[0][2] + r[2][0]) / scale, (r[2][1] - r[1][2]) / scale]
    if r[1][1] > r[2][2]:
        scale = math.sqrt(1.0 + r[1][1] - r[0][0] - r[2][2]) * 2.0
        return [(r[0][1] + r[1][0]) / scale, 0.25 * scale,
                (r[1][2] + r[2][1]) / scale, (r[0][2] - r[2][0]) / scale]
    scale = math.sqrt(1.0 + r[2][2] - r[0][0] - r[1][1]) * 2.0
    return [(r[0][2] + r[2][0]) / scale, (r[1][2] + r[2][1]) / scale,
            0.25 * scale, (r[1][0] - r[0][1]) / scale]


def slerp(a: Vector, b: Vector, fraction: float) -> Vector:
    dot = sum(a[i] * b[i] for i in range(4))
    if dot < 0.0:
        b = [-value for value in b]
        dot = -dot
    dot = min(1.0, max(-1.0, dot))
    if dot > 0.9995:
        mixed = [a[i] + fraction * (b[i] - a[i]) for i in range(4)]
        length = math.sqrt(sum(value * value for value in mixed))
        return [value / length for value in mixed]
    angle = math.acos(dot)
    scale = math.sin(angle)
    left = math.sin((1.0 - fraction) * angle) / scale
    right = math.sin(fraction * angle) / scale
    return [left * a[i] + right * b[i] for i in range(4)]


def axis_angle(axis: Vector, angle: float) -> Matrix:
    length = math.sqrt(sum(value * value for value in axis))
    x, y, z = [value / length for value in axis]
    c, s, t = math.cos(angle), math.sin(angle), 1.0 - math.cos(angle)
    return [
        [t * x * x + c, t * x * y - s * z, t * x * z + s * y],
        [t * x * y + s * z, t * y * y + c, t * y * z - s * x],
        [t * x * z - s * y, t * y * z + s * x, t * z * z + c],
    ]


def rotation_error_rad(target: Matrix, measured: Matrix) -> float:
    delta = matmul(target, transpose(measured))
    cosine = min(1.0, max(-1.0, (delta[0][0] + delta[1][1] + delta[2][2] - 1.0) * 0.5))
    return math.acos(cosine)


def compose(a: tuple[Matrix, Vector], b: tuple[Matrix, Vector]) -> tuple[Matrix, Vector]:
    rotation = matmul(a[0], b[0])
    translated = matvec(a[0], b[1])
    return rotation, [a[1][i] + translated[i] for i in range(3)]


def left_forward(q: Vector) -> tuple[Matrix, Vector]:
    transform: tuple[Matrix, Vector] = ([[1.0, 0.0, 0.0], [0.0, 1.0, 0.0],
                                         [0.0, 0.0, 1.0]], [0.0, 0.0, 0.0])

    def append(position: Vector, fixed: Matrix, axis: Vector, angle: float) -> None:
        nonlocal transform
        transform = compose(transform, ([[1.0, 0.0, 0.0], [0.0, 1.0, 0.0],
                                         [0.0, 0.0, 1.0]], position))
        transform = compose(transform, (fixed, [0.0, 0.0, 0.0]))
        transform = compose(transform, (axis_angle(axis, angle), [0.0, 0.0, 0.0]))

    identity = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
    append([0.0039563, 0.10022, 0.23778],
           quaternion_matrix(0.1392014837, 1.38722044e-5, -9.868683842e-5, 0.9902640744),
           [0.0, 1.0, 0.0], q[0])
    append([0.0, 0.038, -0.013831],
           quaternion_matrix(-0.1391717738, 0.0, 0.0, 0.9902682553),
           [1.0, 0.0, 0.0], q[1])
    append([0.0, 0.00624, -0.1032], identity, [0.0, 0.0, 1.0], q[2])
    append([0.015783, 0.0, -0.080518], identity, [0.0, 1.0, 0.0], q[3])
    append([0.1, 0.00188791, -0.01], identity, [1.0, 0.0, 0.0], q[4])
    append([0.038, 0.0, 0.0], identity, [0.0, 1.0, 0.0], q[5])
    append([0.046, 0.0, 0.0], identity, [0.0, 0.0, 1.0], q[6])
    return compose(transform, (identity, [0.0415, 0.003, 0.0]))


def send(sock: socket.socket, message: dict[str, Any]) -> None:
    payload = json.dumps(message, separators=(",", ":")).encode()
    sock.sendall(struct.pack("<I", len(payload)) + payload)


def receive_exact(sock: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError("adapter closed")
        data.extend(chunk)
    return bytes(data)


def receive(sock: socket.socket) -> dict[str, Any]:
    size = struct.unpack("<I", receive_exact(sock, 4))[0]
    return json.loads(receive_exact(sock, size))


def command(
    pose: dict[str, Any] | None = None,
    reset: bool = False,
    prefer_forward: bool = False,
) -> dict[str, Any]:
    buttons: dict[str, bool] = {}
    poses: dict[str, Any] = {}
    if pose is not None:
        buttons["left_enable"] = True
        poses["left_end_effector"] = pose
    if prefer_forward:
        buttons["left_prefer_forward"] = True
    if reset:
        buttons["reset"] = True
    return {"type": "Command", "axes": {}, "buttons": buttons, "poses": poses,
            "timestamp_ns": time.time_ns()}


def main() -> int:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(2.0)
    sock.connect("/tmp/operator-g1d.sock")
    send(sock, {"type": "Hello"})
    if receive(sock).get("type") != "Descriptor" or receive(sock).get("type") != "Blueprint":
        raise RuntimeError("bad adapter handshake")

    telemetry: list[dict[str, Any]] = []
    lock = threading.Lock()
    running = True
    telemetry_sequence = 0

    def read_loop() -> None:
        nonlocal telemetry_sequence
        sock.settimeout(0.5)
        while running:
            try:
                frame = receive(sock)
            except (socket.timeout, ConnectionError, OSError):
                continue
            if frame.get("type") == "Telemetry":
                values = dict(frame.get("values", {}))
                telemetry_sequence += 1
                values["_local_sequence"] = telemetry_sequence
                with lock:
                    telemetry.append(values)

    reader = threading.Thread(target=read_loop, daemon=True)
    reader.start()

    def latest() -> dict[str, Any]:
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline:
            with lock:
                if telemetry:
                    return telemetry[-1]
            time.sleep(0.02)
        raise TimeoutError("no telemetry")

    identity_pose = {"position": [0.0, 0.0, 0.0], "rotation": [0.0, 0.0, 0.0, 1.0]}
    basis: Matrix = [[0.0, 0.0, -1.0], [-1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]
    goal_q = [-math.pi / 2.0, 0.40, 0.0, math.pi / 2.0,
              -math.pi / 2.0, 0.0, 0.0]
    try:
        initial = latest()
        stable_deadline = time.monotonic() + 3.0
        while True:
            all_q = [float(value) for value in initial.get("joint_positions_rad", [])]
            all_dq = [float(value) for value in initial.get("joint_velocities_rad_s", [])]
            if len(all_dq) == 29 and max(abs(value) for value in all_dq[15:29]) <= 0.10:
                break
            if time.monotonic() >= stable_deadline:
                raise RuntimeError("arms are not stationary")
            time.sleep(0.10)
            initial = latest()
        if not initial.get("lowstate_fresh") or len(all_q) != 29 or len(all_dq) != 29:
            raise RuntimeError("joint feedback is not fresh and complete")
        if int(initial.get("motor_fault_count", -1)) != 0:
            raise RuntimeError("upper-body motor fault")
        start_q = all_q[15:22]
        goal_rotation, goal_position = left_forward(goal_q)
        send(sock, command(reset=True))
        time.sleep(0.15)

        target_command_pose = identity_pose
        for chunk_start in (1, 8, 15):
            sample = latest()
            measured = [float(value) for value in sample["joint_positions_rad"]][15:22]
            reference_rotation, reference_position = left_forward(measured)
            for _ in range(5):
                send(sock, command(identity_pose))
                time.sleep(1.0 / 72.0)
            for stage in range(chunk_start, min(chunk_start + 7, 21)):
                fraction = stage / 20.0
                waypoint_q = [
                    start_q[i] + fraction * (goal_q[i] - start_q[i]) for i in range(7)
                ]
                target_rotation, target_position = left_forward(waypoint_q)
                robot_delta = [target_position[i] - reference_position[i] for i in range(3)]
                if math.sqrt(sum(value * value for value in robot_delta)) > 0.34:
                    raise RuntimeError(f"stage {stage} Cartesian delta exceeds 34 cm")
                xr_delta = matvec(transpose(basis), robot_delta)
                robot_rotation_delta = matmul(target_rotation, transpose(reference_rotation))
                xr_rotation_delta = matmul(
                    matmul(transpose(basis), robot_rotation_delta), basis
                )
                target_command_pose = {
                    "position": xr_delta,
                    "rotation": matrix_quaternion(xr_rotation_delta),
                }
                settled_samples = 0
                last_telemetry_sequence = -1
                deadline = time.monotonic() + 6.0
                while time.monotonic() < deadline:
                    send(sock, command(target_command_pose, prefer_forward=stage == 20))
                    time.sleep(1.0 / 72.0)
                    sample = latest()
                    sequence = int(sample.get("_local_sequence", -1))
                    if sequence == last_telemetry_sequence:
                        continue
                    last_telemetry_sequence = sequence
                    q = [float(value) for value in sample.get("joint_positions_rad", [])]
                    dq = [float(value) for value in sample.get("joint_velocities_rad_s", [])]
                    if len(q) != 29 or len(dq) != 29:
                        continue
                    measured_rotation, measured_position = left_forward(q[15:22])
                    position_error = math.sqrt(sum(
                        (target_position[i] - measured_position[i]) ** 2 for i in range(3)
                    ))
                    orientation_error = rotation_error_rad(target_rotation, measured_rotation)
                    max_speed = max(abs(value) for value in dq[15:22])
                    if position_error <= 0.06 and orientation_error <= 0.18 and max_speed <= 0.12:
                        settled_samples += 1
                        if settled_samples >= 5:
                            break
                    else:
                        settled_samples = 0
                    stop_reason = str(sample.get("stop_reason", ""))
                    if stop_reason and stop_reason not in ("-",):
                        raise RuntimeError(f"stage {stage} stopped: {stop_reason}")
                if settled_samples < 5:
                    raise RuntimeError(
                        f"stage {stage} did not settle: position_error={position_error}, "
                        f"orientation_error={orientation_error}, max_speed={max_speed}"
                    )
            if chunk_start != 15:
                for _ in range(4):
                    send(sock, command())
                    time.sleep(1.0 / 72.0)
                time.sleep(0.05)

        hold_deadline = time.monotonic() + 5.0
        while time.monotonic() < hold_deadline:
            send(sock, command(target_command_pose, prefer_forward=True))
            time.sleep(1.0 / 72.0)

        final = latest()
        final_q = [float(value) for value in final["joint_positions_rad"]][15:22]
        _, final_position = left_forward(final_q)
        print(json.dumps({
            "ok": True,
            "left_arm_positions_rad": final_q,
            "elbow_degrees": math.degrees(final_q[3]),
            "end_position_m": final_position,
            "goal_position_m": goal_position,
            "position_error_m": math.sqrt(sum(
                (goal_position[i] - final_position[i]) ** 2 for i in range(3)
            )),
        }, ensure_ascii=False))
        return 0
    finally:
        try:
            send(sock, command())
            send(sock, {"type": "Stop", "reason": "arm_forward_ik_smoke_complete"})
        except OSError:
            pass
        running = False
        reader.join(timeout=1.0)
        sock.close()


if __name__ == "__main__":
    raise SystemExit(main())
