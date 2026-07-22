from pyoperator import xr_bridge


xr_bridge.start()
try:
    frame_id = 0
    while True:
        frame = xr_bridge.wait_next(frame_id, timeout=1.0)
        if frame is None:
            stats = xr_bridge.stats()
            status = "waiting for first XR state frame" if stats.connected else "waiting for headset"
            print(f"{status}...", stats)
            continue
        frame_id = frame.frame_id
        right = frame.controllers.right
        print(frame.timestamp_ns, right.pose.position if right else None)
finally:
    xr_bridge.stop()
