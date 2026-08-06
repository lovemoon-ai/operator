from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
QUEST_PLUGIN = (
    ROOT
    / "xr/android_plugin/questcapture/src/main/java/com/spatialmp4/questcapture"
    / "QuestCapturePlugin.kt"
)
CAPTURE_FACADE = ROOT / "xr/addons/quest_capture_android/api/XRCaptureProvider.gd"
MEMWORLD_CLIENT = ROOT / "xr/addons/memworld/memworld_client.gd"
MEMWORLD_DISPLAY = ROOT / "xr/addons/pose-inference/pose_inference_display.gd"
MEMWORLD_APP = ROOT / "xr/scenes/memworld_app.gd"
MODE_SELECT = ROOT / "xr/scripts/app/launcher/mode_select.gd"


class MemWorldQuestSourceTests(unittest.TestCase):
    def test_plugin_exposes_metadata_only_query(self):
        source = QUEST_PLUGIN.read_text(encoding="utf-8")
        self.assertIn(
            "fun queryPassthroughCameraMetadataJson(eye: String): String",
            source,
        )
        body = source.split(
            "fun queryPassthroughCameraMetadataJson", 1
        )[1].split("@UsedByGodot", 1)[0]
        self.assertNotIn("openEyeCamera", body)
        self.assertNotIn("ImageReader.newInstance", body)
        self.assertIn('"metadata_only", true', body)

    def test_facade_exposes_metadata_only_query(self):
        source = CAPTURE_FACADE.read_text(encoding="utf-8")
        self.assertIn("func query_passthrough_camera_metadata_json", source)


    def test_memworld_client_sends_calibration_in_hello(self):
        source = MEMWORLD_CLIENT.read_text(encoding="utf-8")
        self.assertIn('["memWorld", "memworld", "mem_world"]', source)
        self.assertIn('"protocol": "operator.memworld.v1"', source)
        self.assertIn('"calibration": _calibration', source)
        self.assertIn("func _send_pose()", source)
        self.assertIn('const MAGIC := "PINF"', source)

    def test_memworld_client_has_room_for_full_image_packets(self):
        source = MEMWORLD_CLIENT.read_text(encoding="utf-8")
        self.assertIn(
            "const WEBSOCKET_INBOUND_BUFFER_BYTES := 16 * 1024 * 1024",
            source,
        )
        self.assertIn(
            "_socket.inbound_buffer_size = WEBSOCKET_INBOUND_BUFFER_BYTES",
            source,
        )

    def test_memworld_display_reuses_one_texture(self):
        source = MEMWORLD_DISPLAY.read_text(encoding="utf-8")
        self.assertIn("var _texture: ImageTexture", source)
        self.assertEqual(source.count("ImageTexture.create_from_image(image)"), 1)
        self.assertIn("_texture.update(image)", source)

    def test_memworld_scene_queries_metadata_without_starting_capture(self):
        source = MEMWORLD_APP.read_text(encoding="utf-8")
        self.assertIn("query_passthrough_camera_metadata_json", source)
        self.assertNotIn("start_cameras(", source)
        self.assertNotIn("startCameras", source)

    def test_mode_select_routes_memworld(self):
        source = MODE_SELECT.read_text(encoding="utf-8")
        self.assertIn('const MODE_MEMWORLD := "memworld"', source)
        self.assertIn('const MEMWORLD_SCENE := "res://scenes/memworld_app.tscn"', source)
        self.assertIn("MODE_MEMWORLD:", source)


if __name__ == "__main__":
    unittest.main()
