"""Print raw XR snapshots; intentionally does not publish Teleop UI."""

from pyoperator import XrSession


def main() -> None:
    with XrSession() as session:
        frame_id = 0
        while session.is_running:
            frame = session.wait_next(frame_id, timeout=1.0)
            if frame is None:
                stats = session.stats()
                status = (
                    "waiting for first XR state frame"
                    if stats.connected
                    else "waiting for headset"
                )
                print(f"{status}...", stats)
                continue
            frame_id = frame.frame_id
            right = frame.controllers.right
            print(frame.timestamp_ns, right.pose.position if right else None)


if __name__ == "__main__":
    main()
