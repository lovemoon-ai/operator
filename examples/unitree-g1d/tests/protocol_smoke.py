#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time


def send_frame(sock: socket.socket, payload: dict) -> None:
    encoded = json.dumps(payload, separators=(",", ":")).encode()
    sock.sendall(struct.pack("<I", len(encoded)) + encoded)


def receive_exact(sock: socket.socket, length: int) -> bytes:
    chunks = []
    remaining = length
    while remaining:
        chunk = sock.recv(remaining)
        if not chunk:
            raise RuntimeError("adapter closed the socket")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def receive_frame(sock: socket.socket) -> dict:
    length = struct.unpack("<I", receive_exact(sock, 4))[0]
    return json.loads(receive_exact(sock, length))


def wait_for_socket(path: Path, process: subprocess.Popen) -> None:
    for _ in range(200):
        if process.poll() is not None:
            raise RuntimeError(f"adapter exited early with {process.returncode}")
        if path.exists():
            return
        time.sleep(0.01)
    raise RuntimeError("adapter socket was not created")


def main() -> int:
    binary = Path(sys.argv[1]).resolve()
    descriptor = Path(sys.argv[2]).resolve()
    blueprint = Path(sys.argv[3]).resolve()
    spec = Path(sys.argv[4]).resolve()
    normalized_spec = json.loads(spec.read_text())
    common_properties = normalized_spec.pop("common_properties", {})
    common_bindings = normalized_spec.pop("common_bindings", {})
    for primitive in normalized_spec["primitives"].values():
        primitive["properties"] = {
            **common_properties,
            **primitive.get("properties", {}),
        }
        primitive["bindings"] = {
            **common_bindings,
            **primitive.get("bindings", {}),
        }
    canonical_spec = json.dumps(
        normalized_spec, separators=(",", ":"), sort_keys=True
    ).encode()
    expected_spec_hash = hashlib.sha256(canonical_spec).hexdigest()
    with tempfile.TemporaryDirectory(prefix="operator-g1d-test-") as directory:
        socket_path = Path(directory) / "adapter.sock"
        process = subprocess.Popen(
            [
                str(binary),
                "--backend",
                "mock",
                "--listen",
                f"uds:{socket_path}",
                "--descriptor",
                str(descriptor),
                "--blueprint",
                str(blueprint),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=os.environ.copy(),
        )
        try:
            wait_for_socket(socket_path, process)
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(2.0)
                client.connect(str(socket_path))
                send_frame(client, {"type": "Hello"})
                descriptor_message = receive_frame(client)
                assert descriptor_message["type"] == "Descriptor"
                assert descriptor_message["device"]["type"] == "unitree_g1d"
                assert descriptor_message["capabilities"]["blueprint_v1"] is True
                mappings = {
                    (mapping["source"], mapping["target"])
                    for mapping in descriptor_message["input_mapping"]
                }
                mappings_by_target = {
                    mapping["target"]: mapping
                    for mapping in descriptor_message["input_mapping"]
                }
                assert {
                    ("left_joystick_y", "base_linear"),
                    ("right_joystick_x", "base_yaw"),
                    ("button_x", "arm_ready"),
                    ("button_y", "arm_init"),
                    ("head_pose", "operator_frame"),
                    ("left_arm_pose", "left_end_effector"),
                    ("right_arm_pose", "right_end_effector"),
                    ("left_arm_grip", "left_enable"),
                    ("right_arm_grip", "right_enable"),
                    ("left_trigger", "revo1_left_grasp"),
                    ("left_controller_active", "left_hand_enable"),
                    ("right_trigger", "revo1_right_grasp"),
                    ("right_controller_active", "right_hand_enable"),
                }.issubset(mappings)
                assert mappings_by_target["base_yaw"]["invert"] is True
                assert {
                    button["name"]
                    for button in descriptor_message["control_schema"]["buttons"]
                } == {
                    "emergency_stop",
                    "reset",
                    "arm_ready",
                    "arm_init",
                    "left_enable",
                    "right_enable",
                    "left_hand_enable",
                    "right_hand_enable",
                }
                assert descriptor_message["capabilities"]["dual_arm"] is True
                assert descriptor_message["capabilities"]["deadman"] is True
                assert descriptor_message["capabilities"]["dexterous_hands"] is True
                assert (
                    descriptor_message["capabilities"]["blueprint_spec_sha256"]
                    == expected_spec_hash
                )

                blueprint_message = receive_frame(client)
                assert blueprint_message["type"] == "Blueprint"
                assert blueprint_message["blueprint"]["schema"] == "operator.blueprint.v1"
                assert blueprint_message["blueprint"]["blueprint_id"] == "unitree.g1d.status"
                component_types = [
                    component["type"]
                    for component in blueprint_message["blueprint"]["components"]
                ]
                assert component_types.count("video_panel") == 1
                assert component_types.count("controller_help") == 0
                components = {
                    component["id"]: component
                    for component in blueprint_message["blueprint"]["components"]
                }
                assert components["g1d_connection"]["anchor"] == "left_controller"
                assert components["g1d_motion"]["anchor"] == "right_controller"
                assert components["g1d_connection"]["transform"]["position"][2] < 0
                assert components["g1d_motion"]["transform"]["position"][2] < 0

                send_frame(
                    client,
                    {
                        "type": "Command",
                        "axes": {},
                        "buttons": {"reset": True},
                        "poses": {},
                        "timestamp_ns": 1,
                    },
                )
                send_frame(
                    client,
                    {
                        "type": "Command",
                        "axes": {"base_linear": 0.5, "base_yaw": 0.0},
                        "buttons": {},
                        "poses": {},
                        "timestamp_ns": 2,
                    },
                )

                saw_base = False
                saw_blueprint_state = False
                deadline = time.monotonic() + 2.0
                while time.monotonic() < deadline:
                    message = receive_frame(client)
                    if message.get("type") == "BlueprintState":
                        state = message["state"]
                        assert state["schema"] == "operator.blueprint_state.v1"
                        assert state["blueprint_id"] == "unitree.g1d.status"
                        assert state["sequence"] > 0
                        assert "g1d.motion_state" in state["values"]
                        saw_blueprint_state = True
                        continue
                    if message.get("type") != "Telemetry":
                        continue
                    values = message["values"]
                    if values.get("control_mode") == "base" and values.get("base_vx_mps", 0) > 0:
                        saw_base = True
                        break
                assert saw_base, "mock adapter never entered base mode"
                assert saw_blueprint_state, "mock adapter never published Blueprint state"

                send_frame(client, {"type": "Stop", "reason": "smoke test"})
                event = receive_frame(client)
                while event.get("type") in ("Telemetry", "BlueprintState"):
                    event = receive_frame(client)
                assert event == {"kind": "estop", "msg": "smoke test", "type": "Event"}
                send_frame(client, {"type": "Shutdown"})
            process.wait(timeout=3)
            assert process.returncode == 0, process.returncode
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
            if process.returncode not in (0, -15):
                stdout, stderr = process.communicate()
                raise RuntimeError(
                    f"adapter failed with {process.returncode}\nstdout:\n{stdout}\nstderr:\n{stderr}"
                )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
