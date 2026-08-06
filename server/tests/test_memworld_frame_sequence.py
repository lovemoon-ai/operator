import io
import unittest
import zipfile

from server.memworld_frame_sequence import unpack_jpeg_sequence


def jpeg_bytes(index: int) -> bytes:
    return b"\xff\xd8" + index.to_bytes(2, "big") + b"\xff\xd9"


def frame_zip(
    *,
    frame_count: int = 17,
    extra_name: str | None = None,
    corrupt_index: int | None = None,
) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as archive:
        for index in range(frame_count):
            payload = b"not-jpeg" if index == corrupt_index else jpeg_bytes(index)
            archive.writestr(f"frames/{index:03d}.jpg", payload)
        if extra_name is not None:
            archive.writestr(extra_name, jpeg_bytes(99))
    return output.getvalue()


class MemWorldFrameSequenceTests(unittest.TestCase):
    def test_unpacks_exactly_17_ordered_jpegs_as_tuple(self):
        frames = unpack_jpeg_sequence(frame_zip())

        self.assertIsInstance(frames, tuple)
        self.assertEqual(len(frames), 17)
        self.assertEqual(frames[0], jpeg_bytes(0))
        self.assertEqual(frames[-1], jpeg_bytes(16))

    def test_rejects_missing_frame(self):
        with self.assertRaisesRegex(ValueError, "exactly 17"):
            unpack_jpeg_sequence(frame_zip(frame_count=16))

    def test_rejects_extra_file(self):
        with self.assertRaisesRegex(ValueError, "exactly 17"):
            unpack_jpeg_sequence(frame_zip(extra_name="manifest.json"))

    def test_rejects_non_jpeg_frame(self):
        with self.assertRaisesRegex(ValueError, "JPEG"):
            unpack_jpeg_sequence(frame_zip(corrupt_index=4))


if __name__ == "__main__":
    unittest.main()
