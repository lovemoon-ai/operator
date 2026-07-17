package com.spatialmp4.capturecommon

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class RgbFrameIndexRecorderTest {
    @get:Rule
    val temporaryFolder = TemporaryFolder()

    @Test
    fun disabledSidecarStillAllocatesMp4FrameIndexes() {
        val root = temporaryFolder.newFolder("session")
        root.resolve("left_camera_frames.jsonl").writeText("stale\n")
        val recorder = RgbFrameIndexRecorder()

        assertTrue(recorder.open(root, "left", writeSidecar = false))
        assertEquals(0L, recorder.nextIndex("left"))
        assertEquals(1L, recorder.nextIndex("left"))
        assertFalse(recorder.append("left", "{\"frame_index\":0}"))
        recorder.close()

        assertFalse(
            "disabling the mirror must remove a stale file in a reused provider directory",
            root.resolve("left_camera_frames.jsonl").exists()
        )
    }

    @Test
    fun enabledSidecarMirrorsTheSameIndexSequence() {
        val root = temporaryFolder.newFolder("session")
        val recorder = RgbFrameIndexRecorder()

        assertTrue(recorder.open(root, "right", writeSidecar = true))
        assertEquals(0L, recorder.nextIndex("right"))
        assertTrue(recorder.append("right", "{\"frame_index\":0}"))
        recorder.close()

        assertEquals(
            "{\"frame_index\":0}\n",
            root.resolve("right_camera_frames.jsonl").readText()
        )
    }
}
