# Matplotlib Quest Pose Visualization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the newest Quest head and 26-joint hand poses as a changing headless Matplotlib 3D JPEG stream returned to Quest at the existing 20 Hz cadence.

**Architecture:** Add a persistent Agg-based renderer to the existing WebSocket service. The receive path keeps replacing a single latest-pose slot, while the inference task calls the synchronous renderer in a worker thread, packs the JPEG with the existing PINF protocol, and sends it without creating a pose or render backlog.

**Tech Stack:** Python 3.10, asyncio, Matplotlib Agg, Pillow, websockets, unittest.

---

## Workspace Constraint

The remote checkout at `/home/evophys/code/operator` is a dirty detached HEAD with unrelated user changes. Do not create a worktree, branch, or commit. Modify only the exact files named below and use path-scoped `git diff` checks after each task.

## File Map

- Modify `server/requirements-pose-inference.txt`: declare the Matplotlib runtime dependency.
- Modify `server/pose_inference_ws.py`: add geometry helpers, the persistent 3D renderer, and non-blocking inference integration.
- Create `server/tests/test_pose_matplotlib_renderer.py`: renderer geometry, JPEG, animation, and missing-tracking tests.
- Modify `server/tests/test_pose_inference_ws.py`: inject a fast renderer into the cadence test.
- Modify `docs/tutorials/quest-pose-inference.md`: document the real 3D stream and its coordinate/joint conventions.

### Task 1: Install and Declare Matplotlib

**Files:**
- Modify: `server/requirements-pose-inference.txt:1-3`

- [ ] **Step 1: Add the dependency**

Append exactly:

```text
matplotlib>=3.8,<4
```

- [ ] **Step 2: Install the remote environment**

Run:

```bash
cd /home/evophys/code/operator
uv pip install --python server/.venv/bin/python -r server/requirements-pose-inference.txt
```

Expected: pip exits 0 and installs Matplotlib plus its required packages into `server/.venv`.

- [ ] **Step 3: Verify headless imports**

Run:

```bash
server/.venv/bin/python -c 'import matplotlib; matplotlib.use("Agg"); from matplotlib.backends.backend_agg import FigureCanvasAgg; print(matplotlib.__version__, matplotlib.get_backend())'
```

Expected: a Matplotlib 3.x version followed by `Agg`.

- [ ] **Step 4: Check scope**

Run:

```bash
git diff -- server/requirements-pose-inference.txt
```

Expected: only the single Matplotlib requirement is added.

### Task 2: Add Tested Pose Geometry Helpers

**Files:**
- Create: `server/tests/test_pose_matplotlib_renderer.py`
- Modify: `server/pose_inference_ws.py:6-29,150-169`

- [ ] **Step 1: Write the failing geometry tests**

Create `server/tests/test_pose_matplotlib_renderer.py` with:

```python
import math
import unittest

from server.pose_inference_ws import (
    HAND_BONES,
    _plot_coordinates,
    _rotate_vector_by_quaternion,
)


class PoseGeometryTests(unittest.TestCase):
    def test_identity_quaternion_preserves_forward_vector(self):
        actual = _rotate_vector_by_quaternion(
            (0.0, 0.0, 0.0, 1.0),
            (0.0, 0.0, -1.0),
        )
        self.assertEqual(actual, (0.0, 0.0, -1.0))

    def test_positive_quarter_turn_around_y_rotates_forward_to_left(self):
        half_angle = math.pi / 4.0
        actual = _rotate_vector_by_quaternion(
            (0.0, math.sin(half_angle), 0.0, math.cos(half_angle)),
            (0.0, 0.0, -1.0),
        )
        self.assertAlmostEqual(actual[0], -1.0, places=6)
        self.assertAlmostEqual(actual[1], 0.0, places=6)
        self.assertAlmostEqual(actual[2], 0.0, places=6)

    def test_plot_coordinates_use_right_forward_up_axes(self):
        self.assertEqual(
            _plot_coordinates((2.0, 4.0, 1.0), (1.0, 2.0, 3.0)),
            (1.0, 2.0, 2.0),
        )

    def test_hand_bones_cover_all_five_fingertips(self):
        connected_indices = {index for edge in HAND_BONES for index in edge}
        self.assertTrue({5, 10, 15, 20, 25}.issubset(connected_indices))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests and confirm RED**

Run:

```bash
server/.venv/bin/python -m unittest server.tests.test_pose_matplotlib_renderer -v
```

Expected: import failure for `HAND_BONES` or the geometry helpers because they do not exist yet.

- [ ] **Step 3: Add the minimal geometry implementation**

In `server/pose_inference_ws.py`, add these constants and helpers after the timing constants:

```python
HAND_BONES: tuple[tuple[int, int], ...] = (
    (1, 0),
    (1, 2), (2, 3), (3, 4), (4, 5),
    (0, 6), (6, 7), (7, 8), (8, 9), (9, 10),
    (0, 11), (11, 12), (12, 13), (13, 14), (14, 15),
    (0, 16), (16, 17), (17, 18), (18, 19), (19, 20),
    (0, 21), (21, 22), (22, 23), (23, 24), (24, 25),
)


def _rotate_vector_by_quaternion(
    quaternion: tuple[float, float, float, float],
    vector: tuple[float, float, float],
) -> tuple[float, float, float]:
    x, y, z, w = quaternion
    vx, vy, vz = vector
    tx = 2.0 * (y * vz - z * vy)
    ty = 2.0 * (z * vx - x * vz)
    tz = 2.0 * (x * vy - y * vx)
    return (
        vx + w * tx + y * tz - z * ty,
        vy + w * ty + z * tx - x * tz,
        vz + w * tz + x * ty - y * tx,
    )


def _plot_coordinates(
    position: tuple[float, float, float],
    origin: tuple[float, float, float],
) -> tuple[float, float, float]:
    return (
        position[0] - origin[0],
        -(position[2] - origin[2]),
        position[1] - origin[1],
    )


def _tracked_position(value: Any) -> tuple[float, float, float] | None:
    if not isinstance(value, dict) or value.get("tracked") is not True:
        return None
    position = value.get("position")
    if not isinstance(position, (list, tuple)) or len(position) != 3:
        return None
    if not all(isinstance(component, (int, float)) for component in position):
        return None
    return tuple(float(component) for component in position)
```

- [ ] **Step 4: Run the geometry tests and confirm GREEN**

Run:

```bash
server/.venv/bin/python -m unittest server.tests.test_pose_matplotlib_renderer -v
```

Expected: four tests pass.

- [ ] **Step 5: Check scope**

Run:

```bash
git diff -- server/pose_inference_ws.py server/tests/test_pose_matplotlib_renderer.py
```

Expected: only geometry constants/helpers and their tests are present.

### Task 3: Build the Persistent Headless 3D Renderer

**Files:**
- Modify: `server/tests/test_pose_matplotlib_renderer.py`
- Modify: `server/pose_inference_ws.py:6-29,150-169`

- [ ] **Step 1: Add failing JPEG and tracking tests**

Extend the test file imports with:

```python
import io
import json
from pathlib import Path

from PIL import Image

from server.pose_inference_ws import MatplotlibPoseRenderer
```

Add:

```python
class MatplotlibPoseRendererTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sample_path = (
            Path(__file__).resolve().parents[1]
            / "samples"
            / "quest_pose_frame_000001.json"
        )
        cls.pose = json.loads(sample_path.read_text(encoding="utf-8"))

    def test_complete_pose_renders_decodable_960_by_540_jpeg(self):
        width, height, jpeg = MatplotlibPoseRenderer().render(self.pose, 1)

        self.assertEqual((width, height), (960, 540))
        with Image.open(io.BytesIO(jpeg)) as image:
            self.assertEqual(image.format, "JPEG")
            self.assertEqual(image.size, (960, 540))
            self.assertGreater(len(image.getcolors(maxcolors=960 * 540)), 8)

    def test_image_sequence_changes_the_encoded_frame(self):
        renderer = MatplotlibPoseRenderer()

        first = renderer.render(self.pose, 1)[2]
        second = renderer.render(self.pose, 2)[2]

        self.assertNotEqual(first, second)

    def test_untracked_and_malformed_joints_still_render(self):
        pose = {
            "frame_id": 5,
            "head": {"tracked": False},
            "left": {"tracking": False, "joints": []},
            "right": {
                "tracking": True,
                "joints": [
                    {"tracked": False},
                    {"tracked": True, "position": [1.0, 2.0]},
                    {"tracked": True, "position": [0.1, 1.8, -0.2]},
                ],
            },
        }

        width, height, jpeg = MatplotlibPoseRenderer().render(pose, 1)

        self.assertEqual((width, height), (960, 540))
        with Image.open(io.BytesIO(jpeg)) as image:
            image.verify()
```

- [ ] **Step 2: Run the renderer tests and confirm RED**

Run:

```bash
server/.venv/bin/python -m unittest server.tests.test_pose_matplotlib_renderer.MatplotlibPoseRendererTests -v
```

Expected: import failure because `MatplotlibPoseRenderer` is not defined.

- [ ] **Step 3: Add imports and the renderer**

Add these imports near the top of `server/pose_inference_ws.py`:

```python
import threading

try:
    import matplotlib
    matplotlib.use("Agg")
    from matplotlib.backends.backend_agg import FigureCanvasAgg
    from matplotlib.figure import Figure
    from PIL import Image
except ImportError as error:
    raise SystemExit(
        "Matplotlib pose rendering dependencies are missing; "
        "run uv pip install --python server/.venv/bin/python "
        "-r server/requirements-pose-inference.txt"
    ) from error
```

Add the lock after `HAND_BONES`:

```python
_MATPLOTLIB_RENDER_LOCK = threading.Lock()
```

Replace the old animated image function with:

```python
class MatplotlibPoseRenderer:
    WIDTH = 960
    HEIGHT = 540
    DPI = 100
    BACKGROUND = "#10192c"

    def __init__(self) -> None:
        self._figure = Figure(
            figsize=(self.WIDTH / self.DPI, self.HEIGHT / self.DPI),
            dpi=self.DPI,
            facecolor=self.BACKGROUND,
        )
        self._canvas = FigureCanvasAgg(self._figure)
        self._axes = self._figure.add_subplot(111, projection="3d")
        self._origin: tuple[float, float, float] | None = None

    def render(
        self,
        pose: dict[str, Any],
        image_sequence: int,
    ) -> tuple[int, int, bytes]:
        with _MATPLOTLIB_RENDER_LOCK:
            self._draw_frame(pose, image_sequence)
            self._canvas.draw()
            rgba = Image.frombuffer(
                "RGBA",
                (self.WIDTH, self.HEIGHT),
                self._canvas.buffer_rgba(),
                "raw",
                "RGBA",
                0,
                1,
            )
            output = io.BytesIO()
            rgba.convert("RGB").save(
                output,
                format="JPEG",
                quality=80,
                optimize=True,
            )
            return self.WIDTH, self.HEIGHT, output.getvalue()

    def _draw_frame(self, pose: dict[str, Any], image_sequence: int) -> None:
        axes = self._axes
        axes.clear()
        axes.set_facecolor(self.BACKGROUND)
        axes.set_xlim(-0.9, 0.9)
        axes.set_ylim(-0.9, 0.9)
        axes.set_zlim(-1.0, 0.5)
        axes.set_box_aspect((1.8, 1.8, 1.5))
        axes.view_init(elev=16.0, azim=-72.0)
        axes.set_xlabel("X right", color="white")
        axes.set_ylabel("-Z forward", color="white")
        axes.set_zlabel("Y up", color="white")
        axes.tick_params(colors="#b7c9db")
        axes.grid(True, alpha=0.25)
        axes.set_title("Operator Quest Pose", color="white")

        head = pose.get("head")
        head_position = _tracked_position(head)
        if head_position is not None and self._origin is None:
            self._origin = head_position
        origin = self._origin or (0.0, 0.0, 0.0)

        if head_position is not None:
            hx, hy, hz = _plot_coordinates(head_position, origin)
            axes.scatter([hx], [hy], [hz], color="#56e39f", s=90, label="head")
            rotation = head.get("rotation") if isinstance(head, dict) else None
            if (
                isinstance(rotation, (list, tuple))
                and len(rotation) == 4
                and all(isinstance(value, (int, float)) for value in rotation)
            ):
                forward = _rotate_vector_by_quaternion(
                    tuple(float(value) for value in rotation),
                    (0.0, 0.0, -0.25),
                )
                fx, fy, fz = _plot_coordinates(forward, (0.0, 0.0, 0.0))
                axes.quiver(
                    hx, hy, hz,
                    fx, fy, fz,
                    color="#56e39f",
                    linewidth=3.0,
                    arrow_length_ratio=0.2,
                )

        self._draw_hand(pose.get("left"), origin, "#50c8ff", "left")
        self._draw_hand(pose.get("right"), origin, "#ff9f43", "right")

        left_tracking = bool(
            isinstance(pose.get("left"), dict)
            and pose["left"].get("tracking") is True
        )
        right_tracking = bool(
            isinstance(pose.get("right"), dict)
            and pose["right"].get("tracking") is True
        )
        axes.text2D(
            0.02,
            0.96,
            (
                f"pose={pose.get('frame_id', '?')}  image={image_sequence}\n"
                f"left={left_tracking}  right={right_tracking}"
            ),
            transform=axes.transAxes,
            color="white",
            fontsize=10,
            verticalalignment="top",
        )

    def _draw_hand(
        self,
        hand: Any,
        origin: tuple[float, float, float],
        color: str,
        label: str,
    ) -> None:
        if not isinstance(hand, dict) or hand.get("tracking") is not True:
            return
        joints = hand.get("joints")
        if not isinstance(joints, list):
            return

        plotted: dict[int, tuple[float, float, float]] = {}
        for index, joint in enumerate(joints[:26]):
            position = _tracked_position(joint)
            if position is not None:
                plotted[index] = _plot_coordinates(position, origin)

        if not plotted:
            return
        axes = self._axes
        axes.scatter(
            [value[0] for value in plotted.values()],
            [value[1] for value in plotted.values()],
            [value[2] for value in plotted.values()],
            color=color,
            s=14,
            label=label,
        )
        for start, end in HAND_BONES:
            if start not in plotted or end not in plotted:
                continue
            first = plotted[start]
            second = plotted[end]
            axes.plot(
                [first[0], second[0]],
                [first[1], second[1]],
                [first[2], second[2]],
                color=color,
                linewidth=2.0,
            )
```

- [ ] **Step 4: Run renderer tests and confirm GREEN**

Run:

```bash
server/.venv/bin/python -m unittest server.tests.test_pose_matplotlib_renderer -v
```

Expected: eight tests pass and no GUI/display error appears.

- [ ] **Step 5: Check scope**

Run:

```bash
git diff -- server/pose_inference_ws.py server/tests/test_pose_matplotlib_renderer.py
```

Expected: geometry and renderer changes only.

### Task 4: Integrate Rendering Without Blocking Pose Reception

**Files:**
- Modify: `server/tests/test_pose_inference_ws.py:156-178`
- Modify: `server/pose_inference_ws.py:188-217`

- [ ] **Step 1: Make the cadence test require renderer injection**

Inside `test_inference_sends_multiple_fixed_rate_images_for_latest_pose`, add:

```python
        class Renderer:
            def render(self, pose, image_sequence):
                return 2, 1, f"jpeg-{pose['frame_id']}-{image_sequence}".encode()
```

Change task creation to:

```python
        task = asyncio.create_task(
            run_inference(
                connection,
                latest,
                ConnectionStats(),
                renderer=Renderer(),
            )
        )
```

- [ ] **Step 2: Run the cadence test and confirm RED**

Run:

```bash
server/.venv/bin/python -m unittest server.tests.test_pose_inference_ws.FakeStreamTests -v
```

Expected: `TypeError` because `run_inference` does not accept `renderer`.

- [ ] **Step 3: Inject the renderer and move work off the event loop**

Change the function to:

```python
async def run_inference(
    connection: Any,
    latest: LatestPose,
    stats: ConnectionStats,
    renderer: Any | None = None,
) -> None:
    """Render and emit the newest pose without accumulating frames."""
    renderer = MatplotlibPoseRenderer() if renderer is None else renderer
    loop = asyncio.get_running_loop()
    next_frame_at = loop.time()
    source_pose: dict[str, Any] | None = None
    image_sequence = 0
    while True:
        pose = latest.take()
        if pose is not None:
            source_pose = pose
        if source_pose is None:
            log_stats(stats)
            await asyncio.sleep(0.005)
            continue
        await asyncio.sleep(max(0.0, next_frame_at - loop.time()))
        pose = latest.take()
        if pose is not None:
            source_pose = pose
        image_sequence += 1
        width, height, jpeg = await asyncio.to_thread(
            renderer.render,
            source_pose,
            image_sequence,
        )
        packet = pack_image_frame(
            source_pose["frame_id"],
            source_pose["capture_time_ns"],
            width,
            height,
            jpeg,
        )
        await connection.send(packet)
        stats.record_image(len(packet))
        stats.record_pose_to_image_latency(
            time.perf_counter_ns() - source_pose["_server_received_ns"]
        )
        log_stats(stats)
        next_frame_at += FRAME_INTERVAL_SECONDS
        if next_frame_at < loop.time():
            next_frame_at = loop.time()
```

The existing `websocket_handler` keeps calling `run_inference(connection, latest, stats)`, so production receives the Matplotlib renderer automatically.

- [ ] **Step 4: Verify the cadence test is GREEN**

Run:

```bash
server/.venv/bin/python -m unittest server.tests.test_pose_inference_ws.FakeStreamTests -v
```

Expected: the existing multiple-frame/latest-pose assertions pass using the injected fast renderer.

- [ ] **Step 5: Run the complete server suite**

Run:

```bash
server/.venv/bin/python -m unittest discover -s server/tests -v
```

Expected: all existing and new tests pass.

### Task 5: Document and Benchmark the 20 Hz Renderer

**Files:**
- Modify: `docs/tutorials/quest-pose-inference.md:190-214`

- [ ] **Step 1: Update the tutorial**

Replace the old real-model replacement paragraph with:

```markdown
## Matplotlib Pose Visualization

The default server image is a headless Matplotlib 3D rendering of the newest
Quest pose. It draws the head and its forward direction, the left hand in cyan,
and the right hand in orange. Each hand follows the OpenXR 26-joint order.

The plot uses the first tracked head position as its stable origin and maps XR
coordinates `[x, y, z]` to chart coordinates `[x, -z, y]`, labeled right,
forward, and up. Untracked joints are omitted without stopping the image stream.

Rendering runs in a worker thread. The WebSocket receive path continues accepting
uncapped pose frames while the image loop selects the newest pose every 50 ms.
If rendering exceeds that interval, the server skips catch-up work and resumes
from the current time rather than building latency.
```

Keep the model-adapter guidance after this section, changing its first sentence to explain that callers may replace `MatplotlibPoseRenderer.render` with a model adapter returning `(width, height, jpeg_bytes)`.

- [ ] **Step 2: Benchmark the checked-in pose**

Run:

```bash
server/.venv/bin/python - <<'PY'
import json
import time
from pathlib import Path
from server.pose_inference_ws import MatplotlibPoseRenderer

pose = json.loads(
    Path("server/samples/quest_pose_frame_000001.json").read_text()
)
renderer = MatplotlibPoseRenderer()
renderer.render(pose, 0)
start = time.perf_counter()
count = 40
for sequence in range(1, count + 1):
    renderer.render(pose, sequence)
elapsed = time.perf_counter() - start
fps = count / elapsed
print(f"render_fps={fps:.1f} average_ms={elapsed * 1000 / count:.1f}")
if fps < 20.0:
    raise SystemExit("renderer is slower than the required 20 Hz")
PY
```

Expected: exit 0 with `render_fps` at least 20.0 and average render time at most 50 ms. If it fails, profile drawing and JPEG encoding separately, then reduce antialiasing or JPEG quality while preserving 960x540 output and all skeleton content.

- [ ] **Step 3: Smoke-test the HTTP/QR service**

Run the service in one terminal:

```bash
cd /home/evophys/code/operator
server/.venv/bin/python server/pose_inference_ws.py
```

From another remote terminal run:

```bash
curl -fsS -D - http://127.0.0.1:63920/ -o /tmp/operator-pose-qr.html
grep -q 'Operator Pose Inference' /tmp/operator-pose-qr.html
```

Expected: HTTP 200, HTML content type, and grep exit 0. Stop only the temporary service after the check.

- [ ] **Step 4: Run final verification**

Run:

```bash
server/.venv/bin/python -m unittest discover -s server/tests -v
server/.venv/bin/python -m compileall -q server
git diff --check --   server/requirements-pose-inference.txt   server/pose_inference_ws.py   server/tests/test_pose_inference_ws.py   server/tests/test_pose_matplotlib_renderer.py   docs/tutorials/quest-pose-inference.md
```

Expected: tests pass, compilation exits 0, and `git diff --check` prints nothing.

- [ ] **Step 5: Inspect only the intended changes**

Run:

```bash
git status --short --   server/requirements-pose-inference.txt   server/pose_inference_ws.py   server/tests/test_pose_inference_ws.py   server/tests/test_pose_matplotlib_renderer.py   docs/tutorials/quest-pose-inference.md
```

Expected: exactly the five planned paths are modified or created. Do not stage or commit them in the detached dirty checkout.
