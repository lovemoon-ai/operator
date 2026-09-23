"""LightNav: a host that declares headset capture and draws a route in-headset.

One program exercising the whole host-declared composition:

* it **declares** what it wants from the headset in the device descriptor
  (``capture_streams``: 4 Hz left-eye RGB plus head poses, optionally a local
  recording), and the user grants or denies that envelope on the headset;
* it **receives** the granted streams on the session's own media channel
  (``xr.capture.frames()``), with no separate ingest server;
* it **draws** the result with Blueprint ``path`` / ``marker`` / ``label``
  primitives, so the headset renders the route without an APK change;
* it **adjusts** the frame rate inside the granted envelope with
  ``xr.streams_control()`` while the operator stands still.

``--replay`` runs the same navigation logic against synthetic head poses, so
the geometry and the state machine can be exercised without a headset.

Run it with a headset (from the repository root)::

    python examples/lightnav/main.py

and connect Operator XR's Teleop mode to this host.
"""

from __future__ import annotations

import argparse
import math
import threading
import time
from dataclasses import dataclass, field

from operator_xr import (
    Blueprint,
    BlueprintComponent,
    BlueprintTransform,
    BridgeConfig,
    CaptureStream,
    CaptureStreamsConfig,
    LocalTask,
    XrSession,
)

#: The envelope: upper limits, not a schedule. The headset clips anything
#: above them and reports `limit`; the user grants this envelope once.
RGB_MAX_HZ = 4.0
RGB_MAX_BITRATE_BPS = 2_000_000
IDLE_RGB_HZ = 1.0
#: Trail geometry.
WAYPOINT_SPACING_M = 0.6
MAX_TRAIL_POINTS = 512
MOVING_SPEED_MPS = 0.15
GROUND_Y = 0.02


def declaration(record: bool) -> CaptureStreamsConfig:
    return CaptureStreamsConfig(
        streams=(
            CaptureStream(
                "rgb.hevc",
                max_hz=RGB_MAX_HZ,
                max_bitrate_bps=RGB_MAX_BITRATE_BPS,
                eye="left",
            ),
            CaptureStream("head_pose.json", required=True, max_hz=30),
        ),
        # Orchestrating a headset-local recording is optional: a denial only
        # changes StreamsStatus, never the session.
        local_tasks=(
            (LocalTask("record", container="spatialmp4", streams=("rgb.hevc", "head_pose.json")),)
            if record
            else ()
        ),
    )


def blueprint() -> Blueprint:
    """Route, next waypoint and a status line, all bound to state values."""
    return Blueprint(
        blueprint_id="example.lightnav",
        components=(
            BlueprintComponent.path(
                "route",
                points_binding="nav.route",
                visible_binding="nav.route_visible",
                properties={"settings_label": "Route", "width": 0.05, "color": [0.2, 0.8, 1.0, 0.9]},
            ),
            BlueprintComponent.marker(
                "waypoint",
                shape="pin",
                text_binding="nav.waypoint_text",
                position_binding="nav.waypoint",
                visible_binding="nav.route_visible",
                properties={"settings_label": "Next waypoint", "size": 0.25},
            ),
            BlueprintComponent.label(
                "status",
                anchor="head",
                transform=BlueprintTransform(position=(0.0, -0.22, -0.7)),
                text_binding="nav.status",
                properties={"settings_label": "LightNav status", "font_size": 26},
            ),
        ),
    )


@dataclass
class Navigator:
    """Trail, waypoint and phase. Pure geometry: no protocol, no I/O."""

    trail: list[tuple[float, float, float]] = field(default_factory=list)
    frames: int = 0
    rgb_packets: int = 0
    last_position: tuple[float, float, float] | None = None
    last_move_ns: int = 0
    moving: bool = False

    def observe_head(self, position: tuple[float, float, float], pts_ns: int) -> None:
        self.frames += 1
        x, _y, z = position
        previous = self.last_position
        self.last_position = position
        if previous is not None:
            elapsed_s = max((pts_ns - self.last_move_ns) / 1e9, 1e-6)
            travelled = math.dist((x, z), (previous[0], previous[2]))
            self.moving = travelled / elapsed_s >= MOVING_SPEED_MPS
        self.last_move_ns = pts_ns
        if not self.trail or math.dist((x, z), (self.trail[-1][0], self.trail[-1][2])) >= WAYPOINT_SPACING_M:
            self.trail.append((x, GROUND_Y, z))
            del self.trail[:-MAX_TRAIL_POINTS]

    def waypoint(self) -> tuple[float, float, float]:
        """One spacing ahead of the current heading, on the ground."""
        if len(self.trail) < 2:
            return self.trail[-1] if self.trail else (0.0, GROUND_Y, -WAYPOINT_SPACING_M)
        (x0, _, z0), (x1, _, z1) = self.trail[-2], self.trail[-1]
        heading = math.atan2(x1 - x0, z1 - z0)
        return (
            x1 + math.sin(heading) * WAYPOINT_SPACING_M,
            GROUND_Y,
            z1 + math.cos(heading) * WAYPOINT_SPACING_M,
        )

    def state(self) -> dict[str, object]:
        points: list[float] = []
        for point in self.trail:
            points.extend(point)
        waypoint = self.waypoint()
        return {
            "nav.route": points,
            "nav.route_visible": len(self.trail) >= 2,
            "nav.waypoint": list(waypoint),
            "nav.waypoint_text": "%.1f m" % math.dist(
                (waypoint[0], waypoint[2]),
                (self.trail[-1][0], self.trail[-1][2]) if self.trail else (0.0, 0.0),
            ),
            "nav.status": "LightNav: %d poses, %d rgb frames, %s"
            % (self.frames, self.rgb_packets, "moving" if self.moving else "holding"),
        }


def consume(session: XrSession, navigator: Navigator) -> None:
    """Granted media arrives as live_feed samples on the session's channel."""
    for sample in session.capture.frames(timeout=0.25):
        if sample.kind == "head_pose" and sample.tracking_valid:
            navigator.observe_head(tuple(sample.position), sample.pts_ns)
        elif sample.kind == "rgb_packet":
            navigator.rgb_packets += 1
        elif sample.kind == "session_start":
            print("headset media session started")
        elif sample.kind == "session_end":
            print("headset media session ended")


def run(record: bool) -> None:
    config = BridgeConfig(capture_streams=declaration(record))
    navigator = Navigator()
    reported: str | None = None
    requested_hz = RGB_MAX_HZ

    with XrSession(config) as session:
        session.blueprint.set_blueprint(blueprint())
        reader = threading.Thread(target=consume, args=(session, navigator), daemon=True)
        reader.start()
        print("LightNav running; grant the capture request in the headset. Ctrl-C to stop.")
        try:
            while session.is_running:
                time.sleep(0.2)
                session.blueprint.update(navigator.state())

                status = session.streams_status()
                if status is None:
                    # No headset yet (or it has not answered): nothing to
                    # control. Waiting here is the normal startup state.
                    continue
                line = str(status.to_dict())
                if line != reported:
                    reported = line
                    print("StreamsStatus:", line)
                    # Track what the headset delivers: a reconnected headset
                    # starts at the envelope again and must be asked again.
                    rgb = status.stream("rgb.hevc")
                    if rgb is not None and rgb.hz is not None:
                        requested_hz = rgb.hz
                if not status.is_active("rgb.hevc"):
                    continue
                # Standing still needs no 4 Hz camera. Staying inside the
                # granted envelope means the user is never asked again.
                wanted = RGB_MAX_HZ if navigator.moving else IDLE_RGB_HZ
                if wanted == requested_hz:
                    continue
                try:
                    session.streams_control({"rgb.hevc": {"hz": wanted}})
                except RuntimeError as error:
                    # The headset disconnected between the status and here.
                    print("streams_control skipped:", error)
                    continue
                requested_hz = wanted
        except KeyboardInterrupt:
            print("stopping")


def replay(seconds: float) -> None:
    """The same navigator, fed a synthetic walk. No headset, no network."""
    navigator = Navigator()
    steps = int(seconds * 30)
    for step in range(steps):
        angle = step / 30.0
        navigator.observe_head(
            (math.sin(angle) * 2.0, 1.6, -math.cos(angle) * 2.0), int(step * 33_333_333)
        )
    state = navigator.state()
    print("trail points:", len(navigator.trail))
    print("waypoint:", [round(value, 3) for value in state["nav.waypoint"]])
    print(state["nav.status"])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replay", action="store_true", help="run the navigator without a headset")
    parser.add_argument("--seconds", type=float, default=6.0, help="--replay walk length")
    parser.add_argument(
        "--record",
        action="store_true",
        help="also ask the headset to record the granted streams locally",
    )
    args = parser.parse_args()
    if args.replay:
        replay(args.seconds)
    else:
        run(args.record)


if __name__ == "__main__":
    main()
