#!/usr/bin/env python3
"""Example 2 - bidirectional Live Feed: headset -> pyoperator -> headset.

The headset pushes its head pose; this script turns the recent trajectory into a
coloured point cloud and streams it back, where the headset renders it in 3D.

    headset --OLCP :63910--> LiveFeedReceiver --> HeadTrailProcessor
                                                       |
    headset <--OLCP :63912-- ResultPublisher <---------+

The processing is deliberately trivial (a head-pose trail) so the example stays
about the *round trip*: receive, compute, encode, publish, render.  Swap
:class:`HeadTrailProcessor` for a real algorithm and nothing else has to change
- the transport and the main loop stay identical.

Run::

    python python/examples/live_feed_roundtrip.py

Then start Live Feed mode on the headset.  Confirm the loop closed with::

    adb logcat -s godot | grep "Live-pull rendered chunk"

Note on time domains: OLCP ``pts_ns`` is the headset's monotonic clock, not host
wall time.  Results are stamped with the pts of the pose that produced them so
the headset can correlate them; never compare those values to ``time.time()``.
"""

from __future__ import annotations

import argparse
import collections
import math
import sys
import time
from pathlib import Path

# Allow running straight from a source checkout without installing.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pyoperator.live_feed import (  # noqa: E402
    DensePoint,
    HeadPoseSample,
    LiveFeedReceiver,
    LiveFeedSession,
    PoseSample,
    ReceiverConfig,
    SessionStartSample,
)


#: The headset's dense-map view truncates a chunk at 120k points; stay well under.
MAX_TRAIL_POINTS = 60_000

ROUNDTRIP_CAPTURE_REQUEST = {
    "schema": "operator.capture_request.v1",
    "protocol": "operator.live_feed.v2",
    "algorithm": "head_trail",
    "selected_streams": ["session.json", "head_pose.json"],
    "result_streams": [
        "status.json",
        "dense_map.point_cloud_delta",
        "camera_trajectory.json",
    ],
    "limits": {},
    "stream_frame_types": {},
}


class HeadTrailProcessor:
    """Turns a stream of head poses into a renderable point-cloud trail.

    Poses are thinned by distance (not by count) so a stationary user does not
    fill the buffer with duplicate points, and each retained position is drawn
    as a small 3D cross so it is visible from any angle in the headset.
    """

    def __init__(
        self,
        max_poses: int = 300,
        min_step_m: float = 0.01,
        publish_interval_s: float = 0.35,
        marker_size_m: float = 0.015,
    ) -> None:
        self.max_poses = max_poses
        self.min_step_m = min_step_m
        self.publish_interval_s = publish_interval_s
        self.marker_size_m = marker_size_m
        self.poses: collections.deque[PoseSample] = collections.deque(maxlen=max_poses)
        self.accepted = 0
        self.rejected = 0
        self._last_publish = 0.0
        self._last_kept: tuple[float, float, float] | None = None

    def add(self, sample: HeadPoseSample) -> bool:
        """Record a head pose. Returns ``True`` if it was kept."""
        if not sample.tracking_valid:
            self.rejected += 1
            return False
        position = sample.position
        if not all(math.isfinite(value) for value in position):
            self.rejected += 1
            return False
        if self._last_kept is not None and math.dist(self._last_kept, position) < self.min_step_m:
            self.rejected += 1
            return False
        self._last_kept = position
        self.poses.append(sample.pose)
        self.accepted += 1
        return True

    def should_publish(self, now: float | None = None) -> bool:
        now = time.monotonic() if now is None else now
        if not self.poses:
            return False
        return (now - self._last_publish) >= self.publish_interval_s

    def mark_published(self, now: float | None = None) -> None:
        self._last_publish = time.monotonic() if now is None else now

    def points(self) -> list[DensePoint]:
        """Build the trail as coloured points, oldest blue -> newest orange."""
        poses = list(self.poses)
        if not poses:
            return []

        offsets = self._marker_offsets()
        # Keep the payload inside the headset's per-chunk budget even if
        # max_poses is raised.
        budget = max(1, MAX_TRAIL_POINTS // len(offsets))
        if len(poses) > budget:
            poses = poses[-budget:]

        points: list[DensePoint] = []
        last = len(poses) - 1
        for index, pose in enumerate(poses):
            alpha = index / last if last > 0 else 1.0
            red, green, blue = self._trail_color(alpha)
            x, y, z = pose.transform[1]
            for dx, dy, dz in offsets:
                points.append(
                    DensePoint(
                        x=x + dx,
                        y=y + dy,
                        z=z + dz,
                        r=red,
                        g=green,
                        b=blue,
                        a=255,
                        confidence=0.25 + 0.75 * alpha,
                    )
                )
        return points

    def _marker_offsets(self) -> tuple[tuple[float, float, float], ...]:
        size = self.marker_size_m
        return (
            (0.0, 0.0, 0.0),
            (size, 0.0, 0.0),
            (-size, 0.0, 0.0),
            (0.0, size, 0.0),
            (0.0, -size, 0.0),
            (0.0, 0.0, size),
            (0.0, 0.0, -size),
        )

    @staticmethod
    def _trail_color(alpha: float) -> tuple[int, int, int]:
        """Blue (oldest) -> orange (newest)."""
        alpha = min(1.0, max(0.0, alpha))
        red = int(40 + 215 * alpha)
        green = int(90 + 90 * alpha)
        blue = int(235 - 205 * alpha)
        return (red, green, blue)


def run_session(session: LiveFeedSession, args: argparse.Namespace) -> None:
    """Consume one headset session and stream the trail back."""
    publisher = session.results
    if publisher is None:
        print("no result publisher; nothing to send back", file=sys.stderr, flush=True)
        return

    processor = HeadTrailProcessor(
        max_poses=args.max_poses,
        min_step_m=args.min_step_m,
        publish_interval_s=args.publish_interval,
        marker_size_m=args.marker_size,
    )

    map_id = args.map_id
    # A fresh reconstruction: tell the headset to drop whatever it still shows.
    publisher.reset_map(map_id, reason="new head-trail session")
    publisher.publish_status(
        "running",
        algorithm="head_trail",
        message="head pose trail processor started",
        max_poses=args.max_poses,
        publish_interval_s=args.publish_interval,
    )

    published = 0
    last_report = time.monotonic()

    for sample in session.samples():
        if isinstance(sample, SessionStartSample):
            print(f"session {sample.session_id} started; streaming trail to map '{map_id}'", flush=True)
            continue
        if isinstance(sample, HeadPoseSample):
            processor.add(sample)

        if not processor.should_publish():
            continue

        points = processor.points()
        if not points:
            processor.mark_published()
            continue

        # Always the same chunk_id with operation=upsert: the headset replaces
        # the chunk in place, so its memory stays flat no matter how long we run.
        publisher.publish_points(
            map_id=map_id,
            chunk_id=f"{map_id}_trail",
            points=points,
            operation="upsert",
            pts_ns=sample.pts_ns,
        )
        publisher.publish_trajectory(map_id, list(processor.poses), pts_ns=sample.pts_ns)
        processor.mark_published()
        published += 1

        now = time.monotonic()
        if now - last_report >= 2.0:
            last_report = now
            print(
                f"trail poses={len(processor.poses)} points={len(points)} "
                f"updates={published} map_version={publisher.map_version(map_id)} "
                f"| {session.stats.summary()}",
                flush=True,
            )

    publisher.publish_status(
        "stopped",
        algorithm="head_trail",
        poses_accepted=processor.accepted,
        poses_rejected=processor.rejected,
        updates_published=published,
        map_version=publisher.map_version(map_id),
    )
    print(
        f"session ended: accepted={processor.accepted} rejected={processor.rejected} "
        f"updates={published}",
        flush=True,
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="0.0.0.0", help="bind address for the push listener")
    parser.add_argument("--push-port", type=int, default=63910, help="OLCP live-push port")
    parser.add_argument("--result-port", type=int, default=63912, help="OLCP live-pull port")
    parser.add_argument("--map-id", default="head-trail", help="map id rendered by the headset")
    parser.add_argument("--max-poses", type=int, default=300, help="trail length in poses")
    parser.add_argument("--min-step-m", type=float, default=0.01, help="minimum movement to record a pose")
    parser.add_argument("--publish-interval", type=float, default=0.35, help="seconds between result updates")
    parser.add_argument("--marker-size", type=float, default=0.015, help="half-size of each trail marker (m)")
    parser.add_argument("--record-dir", type=Path, default=None, help="also persist the raw stream here")
    parser.add_argument("--auth-token", default="", help="require this token in session_start")
    parser.add_argument("--no-qr", action="store_true", help="do not print the connection QR code")
    parser.add_argument("--once", action="store_true", help="exit after the first session ends")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    config = ReceiverConfig(
        host=args.host,
        push_port=args.push_port,
        result_host=args.host,
        result_port=args.result_port,
        accept_results=True,
        publish_results=True,
        capture_request=ROUNDTRIP_CAPTURE_REQUEST,
        auth_token=args.auth_token,
        record_dir=args.record_dir,
        show_qr=not args.no_qr,
        banner_label="Live Feed roundtrip",
    )

    print(f"streaming head-trail results to map '{args.map_id}'", flush=True)
    try:
        with LiveFeedReceiver(config) as receiver:
            for session in receiver.sessions():
                run_session(session, args)
                if session.error is not None:
                    print(f"stream error: {session.error}", file=sys.stderr, flush=True)
                if args.once:
                    break
    except KeyboardInterrupt:
        print("\ninterrupted", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
