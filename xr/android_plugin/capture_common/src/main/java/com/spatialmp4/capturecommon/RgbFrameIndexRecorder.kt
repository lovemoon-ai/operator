package com.spatialmp4.capturecommon

import java.io.BufferedWriter
import java.io.File
import java.io.FileWriter
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * Keeps the MP4 rgb_frame_index sequence independent from its optional JSONL
 * debug mirror. A disabled or failed sidecar must never suppress the metadata
 * record sent to SpatialDataSink.
 */
class RgbFrameIndexRecorder {
    private val writers = ConcurrentHashMap<String, BufferedWriter>()
    private val counters = ConcurrentHashMap<String, AtomicLong>()

    fun open(root: File, eye: String, writeSidecar: Boolean): Boolean {
        closeEye(eye)
        counters[eye] = AtomicLong(0L)

        val target = File(root, "${eye}_camera_frames.jsonl")
        if (!writeSidecar) {
            target.delete()
            return true
        }

        return try {
            target.parentFile?.mkdirs()
            writers[eye] = BufferedWriter(FileWriter(target, false))
            true
        } catch (_: Exception) {
            false
        }
    }

    fun nextIndex(eye: String): Long? = counters[eye]?.getAndIncrement()

    fun append(eye: String, recordText: String): Boolean {
        val writer = writers[eye] ?: return false
        return try {
            synchronized(writer) {
                writer.write(recordText)
                writer.write("\n")
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    fun close() {
        writers.keys.toList().forEach(::closeEye)
        counters.clear()
    }

    private fun closeEye(eye: String) {
        val writer = writers.remove(eye) ?: return
        try {
            writer.flush()
            writer.close()
        } catch (_: Exception) {
        }
    }
}
