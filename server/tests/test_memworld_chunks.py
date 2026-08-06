import io
import json
import unittest
import zipfile

import numpy as np
from PIL import Image

from server.memworld_chunks import (
    LatestChunkSlot,
    LatestWindowQueue,
    ProjectedSample,
    RollingChunkWindow,
    pack_live_chunk,
)


def sample(index: int) -> ProjectedSample:
    image = Image.new("RGB", (640, 352), (index % 255, 0, 0))
    output = io.BytesIO()
    image.save(output, format="PNG")
    return ProjectedSample(
        frame_id=index,
        capture_time_ns=index * 100,
        server_received_ns=index * 100 + 1,
        calibration_id="cal-1",
        c2w=np.eye(4, dtype=np.float32),
        keypoint_png=output.getvalue(),
    )


class MemWorldChunkTests(unittest.TestCase):
    def test_window_reuses_last_sample_as_next_chunk_anchor(self):
        window = RollingChunkWindow(17)
        chunks = []
        for index in range(33):
            chunk = window.add(sample(index))
            if chunk is not None:
                chunks.append(chunk)
        self.assertEqual(len(chunks), 2)
        self.assertEqual((chunks[0].first_frame_id, chunks[0].last_frame_id), (0, 16))
        self.assertEqual((chunks[1].first_frame_id, chunks[1].last_frame_id), (16, 32))
        self.assertIs(chunks[0].samples[-1], chunks[1].samples[0])
        self.assertEqual([chunk.chunk_id for chunk in chunks], [1, 2])
        self.assertEqual(window.fill, 1)

    def test_zip_contains_c2ws_and_keypoint_frames(self):
        window = RollingChunkWindow(17)
        chunk = None
        for index in range(17):
            chunk = window.add(sample(index))
        payload = pack_live_chunk(chunk)
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            manifest = json.loads(archive.read("manifest.json"))
            c2ws = np.load(archive.open("c2ws.npy"))
            names = [name for name in archive.namelist() if name.startswith("keypoints/")]
        self.assertEqual(manifest["frame_count"], 17)
        self.assertEqual(c2ws.shape, (17, 4, 4))
        self.assertEqual(len(names), 17)

    def test_pending_slot_keeps_only_newest_chunk(self):
        window = RollingChunkWindow(2)
        chunk_1 = None
        chunk_2 = None
        for index in range(2):
            chunk_1 = window.add(sample(index))
        chunk_2 = window.add(sample(2))
        slot = LatestChunkSlot()
        slot.submit(chunk_1)
        slot.submit(chunk_2)
        self.assertEqual(slot.pending.chunk_id, chunk_2.chunk_id)
        self.assertEqual(slot.skipped, 1)
        running = slot.start_next()
        self.assertEqual(running.chunk_id, chunk_2.chunk_id)
        slot.finish(running.chunk_id)
        self.assertIsNone(slot.running)

    def test_latest_window_dispatches_recent_17_after_each_16_new_samples(self):
        queue = LatestWindowQueue(frames_per_chunk=17, stride=16)
        for index in range(17):
            queue.add(sample(index))
        first = queue.start_next()
        self.assertEqual(
            (first.first_frame_id, first.last_frame_id),
            (0, 16),
        )
        queue.finish(first.chunk_id)

        for index in range(17, 32):
            queue.add(sample(index))
        self.assertIsNone(queue.start_next())
        queue.add(sample(32))
        second = queue.start_next()
        self.assertEqual(
            (second.first_frame_id, second.last_frame_id),
            (16, 32),
        )
        queue.finish(second.chunk_id)
        self.assertEqual(queue.snapshot()["skipped_samples"], 0)

    def test_latest_window_catches_up_without_queuing_stale_windows(self):
        queue = LatestWindowQueue(frames_per_chunk=17, stride=16)
        for index in range(17):
            queue.add(sample(index))
        first = queue.start_next()
        for index in range(17, 38):
            queue.add(sample(index))
        self.assertIsNone(queue.start_next())
        queue.finish(first.chunk_id)

        newest = queue.start_next()
        self.assertEqual(
            (newest.first_frame_id, newest.last_frame_id),
            (21, 37),
        )
        status = queue.snapshot()
        self.assertEqual(status["skipped_samples"], 5)
        self.assertIsNone(status["pending_chunk"])


if __name__ == "__main__":
    unittest.main()
