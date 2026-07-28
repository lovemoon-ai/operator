package com.spatialmp4.livefeed

import android.util.Base64
import android.util.Log
import com.spatialmp4.contract.CONTRACT_VERSION
import com.spatialmp4.contract.Intrinsics
import com.spatialmp4.contract.RgbStreamConfig
import com.spatialmp4.contract.RgbVideoCodec
import com.spatialmp4.contract.SessionConfig
import com.spatialmp4.contract.SpatialDataSink
import com.spatialmp4.contract.SpatialDataSinkRegistry
import java.io.BufferedOutputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import org.json.JSONArray
import org.json.JSONObject

open class LivePushPlugin(godot: Godot) : GodotPlugin(godot), SpatialDataSink {
    override val contractVersion: Int
        get() = CONTRACT_VERSION

    override fun getPluginName(): String = "LivePushPlugin"

    override fun getPluginSignals(): Set<SignalInfo> = setOf(
        SignalInfo("live_feed_connected", String::class.java),
        SignalInfo("live_feed_disconnected", String::class.java),
        SignalInfo("live_feed_error", String::class.java),
        SignalInfo("live_capture_connected", String::class.java),
        SignalInfo("live_capture_disconnected", String::class.java),
        SignalInfo("live_capture_error", String::class.java)
    )

    @Volatile private var serverHost: String = DEFAULT_HOST
    @Volatile private var serverPort: Int = DEFAULT_PORT
    @Volatile private var streamName: String = ""
    @Volatile private var authToken: String = ""
    @Volatile private var connectTimeoutMs: Int = DEFAULT_CONNECT_TIMEOUT_MS
    @Volatile private var queue: ArrayBlockingQueue<QueuedFrame> = ArrayBlockingQueue(DEFAULT_QUEUE_FRAMES)
    @Volatile private var socket: Socket? = null
    @Volatile private var output: DataOutputStream? = null
    @Volatile private var senderThread: Thread? = null
    @Volatile private var lastEndpoint: String = ""
    private val running = AtomicBoolean(false)

    private val metricFramesSent = AtomicLong(0L)
    private val metricBytesSent = AtomicLong(0L)
    private val metricFramesDropped = AtomicLong(0L)
    private val metricBytesDropped = AtomicLong(0L)
    private val metricDepthFramesCompressed = AtomicLong(0L)
    private val metricDepthBytesRaw = AtomicLong(0L)
    private val metricDepthBytesWire = AtomicLong(0L)

    @UsedByGodot
    fun configureServer(
        host: String,
        port: Int,
        name: String,
        token: String,
        maxQueueFrames: Int,
        timeoutMs: Int
    ): Boolean {
        if (running.get()) {
            emitError("Cannot reconfigure live-push server while streaming")
            return false
        }
        val trimmedHost = host.trim()
        if (trimmedHost.isEmpty()) {
            emitError("Live-push server host is empty")
            return false
        }
        if (port !in 1..65535) {
            emitError("Live-push server port is out of range: $port")
            return false
        }
        serverHost = trimmedHost
        serverPort = port
        streamName = name.trim()
        authToken = token
        connectTimeoutMs = timeoutMs.coerceAtLeast(250)
        val capacity = maxQueueFrames.coerceIn(MIN_QUEUE_FRAMES, MAX_QUEUE_FRAMES)
        queue = ArrayBlockingQueue(capacity)
        SpatialDataSinkRegistry.register(this)
        Log.i(TAG, "Configured live-push server $serverHost:$serverPort queue=$capacity")
        return true
    }

    @UsedByGodot
    fun isConnected(): Boolean = running.get() && socket?.isConnected == true && socket?.isClosed == false

    @UsedByGodot
    fun finishLiveFeed(): String = finishSession()

    @UsedByGodot
    fun finishLiveCapture(): String = finishSession()

    @UsedByGodot
    fun popMetricsJson(): String {
        return JSONObject()
            .put("frames_sent", metricFramesSent.getAndSet(0L))
            .put("bytes_sent", metricBytesSent.getAndSet(0L))
            .put("frames_dropped", metricFramesDropped.getAndSet(0L))
            .put("bytes_dropped", metricBytesDropped.getAndSet(0L))
            .put("depth_frames_compressed", metricDepthFramesCompressed.getAndSet(0L))
            .put("depth_bytes_raw", metricDepthBytesRaw.getAndSet(0L))
            .put("depth_bytes_wire", metricDepthBytesWire.getAndSet(0L))
            .put("queue_depth", queue.size)
            .put("connected", isConnected())
            .toString()
    }

    override fun startSession(config: SessionConfig): Boolean {
        if (running.get()) {
            emitError("Live-push session already running")
            return false
        }
        val endpoint = "$serverHost:$serverPort"
        val newSocket = Socket()
        return try {
            newSocket.tcpNoDelay = true
            newSocket.keepAlive = true
            newSocket.connect(InetSocketAddress(serverHost, serverPort), connectTimeoutMs)
            socket = newSocket
            output = DataOutputStream(BufferedOutputStream(newSocket.getOutputStream(), SOCKET_BUFFER_BYTES))
            running.set(true)
            lastEndpoint = endpoint
            senderThread = Thread({ senderLoop() }, "LiveFeedServerWriter").apply {
                isDaemon = true
                start()
            }
            val sessionJson = sessionConfigJson(config)
                .put("stream_name", streamName)
                .put("auth_token", authToken)
                .put("protocol", "operator.live_feed.v1")
            enqueueImportant(Frame(TYPE_SESSION_START, 0, 0L, 0L, sessionJson.toString().toByteArray(Charsets.UTF_8)))
            emitConnected(endpoint)
            Log.i(TAG, "Live-push connected to $endpoint")
            true
        } catch (error: Exception) {
            closeSocket()
            emitError("Failed to connect live-push server $endpoint: ${error.message}")
            false
        }
    }

    override fun finishSession(): String {
        val endpoint = lastEndpoint
        if (!running.get() && socket == null) {
            SpatialDataSinkRegistry.unregister(this)
            return endpoint
        }
        val endPayload = JSONObject()
            .put("stream_name", streamName)
            .put("reason", "finish")
            .toString()
            .toByteArray(Charsets.UTF_8)
        enqueueImportant(Frame(TYPE_SESSION_END, 0, 0L, 0L, endPayload))
        running.set(false)
        senderThread?.joinQuietly(FINISH_JOIN_MS)
        closeSocket()
        SpatialDataSinkRegistry.unregister(this)
        emitDisconnected(endpoint)
        Log.i(TAG, "Live-push disconnected from $endpoint")
        return if (endpoint.isEmpty()) "" else "tcp://$endpoint/$streamName"
    }

    override fun onRgbCsd(config: RgbStreamConfig) {
        val codec = RgbVideoCodec.normalize(config.codec)
        val payload = JSONObject()
            .put("width", config.width)
            .put("height", config.height)
            .put("fps", config.fps)
            .put("codec", codec)
            .put("bitstream_format", "${codec}_annexb")
            .put("packet_format", "access_unit")
            .put("stereo_layout", if (config.camCount > 1) "side_by_side" else "mono")
            .put("camera_count", config.camCount)
            .put("cameras", JSONArray(config.cameras.map { it.toJson() }))
            .put("csd_base64", Base64.encodeToString(config.csd, Base64.NO_WRAP))
            .toString()
            .toByteArray(Charsets.UTF_8)
        enqueue(Frame(TYPE_RGB_CSD, 0, 0L, 0L, payload), droppable = false)
    }

    override fun onRgbPacket(data: ByteBuffer, ptsNs: Long, durationNs: Long, isKeyframe: Boolean) {
        val copy = data.slice()
        val payload = ByteArray(copy.remaining())
        copy.get(payload)
        val flags = if (isKeyframe) FLAG_KEYFRAME else 0
        enqueue(Frame(TYPE_RGB_PACKET, flags, ptsNs, durationNs, payload), droppable = true)
    }

    override fun onDepthMetadata(width: Int, height: Int, intrinsics: Intrinsics) {
        val payload = JSONObject()
            .put("width", width)
            .put("height", height)
            .put("intrinsics", intrinsics.toJson())
            .put("wire_compression", "zlib_optional")
            .toString()
            .toByteArray(Charsets.UTF_8)
        enqueue(Frame(TYPE_DEPTH_METADATA, 0, 0L, 0L, payload), droppable = false)
    }

    override fun onDepthFrame(payload: ByteArray, ptsNs: Long, durationNs: Long) {
        if (!running.get()) {
            return
        }
        val encoded = encodeDepth(payload)
        val flags = if (encoded.compressed) FLAG_COMPRESSED_ZLIB else 0
        enqueue(Frame(TYPE_DEPTH_FRAME, flags, ptsNs, durationNs, encoded.payload), droppable = true)
    }

    override fun onError(message: String) {
        emitError(message)
    }

    @UsedByGodot
    fun writeDepthFrame(
        timestampNs: Long,
        width: Int,
        height: Int,
        payloadU16Mm: ByteArray,
        fovLeft: Double,
        fovRight: Double,
        fovTop: Double,
        fovBottom: Double,
        metadataJson: String
    ): Boolean {
        if (!running.get()) {
            return false
        }
        val json = JSONObject()
            .put("width", width)
            .put("height", height)
            .put("fov_left", fovLeft)
            .put("fov_right", fovRight)
            .put("fov_top", fovTop)
            .put("fov_bottom", fovBottom)
        if (metadataJson.isNotBlank()) {
            json.put("metadata_json", metadataJson)
        }
        val encoded = encodeDepth(payloadU16Mm)
        if (encoded.compressed) {
            json
                .put("wire_compression", "zlib")
                .put("uncompressed_size_bytes", encoded.uncompressedSize)
        }
        val flags = FLAG_COMPOSITE_JSON or (
            if (encoded.compressed) FLAG_COMPRESSED_ZLIB else 0
        )
        return enqueue(
            Frame(
                TYPE_DEPTH_FRAME,
                flags,
                timestampNs,
                DEFAULT_DEPTH_DURATION_NS,
                jsonPayload(json, encoded.payload),
            ),
            droppable = true
        )
    }

    @UsedByGodot
    fun writeHeadPose(
        timestampNs: Long,
        px: Double,
        py: Double,
        pz: Double,
        qx: Double,
        qy: Double,
        qz: Double,
        qw: Double,
        trackingValid: Boolean
    ): Boolean {
        val payload = JSONObject()
            .put("position", JSONObject().put("x", px).put("y", py).put("z", pz))
            .put("rotation", JSONObject().put("x", qx).put("y", qy).put("z", qz).put("w", qw))
            .put("tracking_valid", trackingValid)
            .toString()
            .toByteArray(Charsets.UTF_8)
        return enqueue(Frame(TYPE_HEAD_POSE, 0, timestampNs, DEFAULT_POSE_DURATION_NS, payload), droppable = true)
    }

    @UsedByGodot
    fun writeControllerPose(
        source: String,
        timestampNs: Long,
        px: Double,
        py: Double,
        pz: Double,
        qx: Double,
        qy: Double,
        qz: Double,
        qw: Double,
        trackingValid: Boolean
    ): Boolean {
        val payload = JSONObject()
            .put("source", source)
            .put("position", JSONObject().put("x", px).put("y", py).put("z", pz))
            .put("rotation", JSONObject().put("x", qx).put("y", qy).put("z", qz).put("w", qw))
            .put("tracking_valid", trackingValid)
            .toString()
            .toByteArray(Charsets.UTF_8)
        return enqueue(Frame(TYPE_CONTROLLER_POSE, 0, timestampNs, DEFAULT_POSE_DURATION_NS, payload), droppable = true)
    }

    @UsedByGodot
    fun writeHandJointsJson(hand: String, timestampNs: Long, jointsJson: String): Boolean {
        val payload = JSONObject()
            .put("hand", hand)
            .put("joints_json", jointsJson)
            .toString()
            .toByteArray(Charsets.UTF_8)
        return enqueue(Frame(TYPE_HAND_JOINTS, 0, timestampNs, DEFAULT_HAND_DURATION_NS, payload), droppable = true)
    }

    @UsedByGodot
    fun writeControllerInput(
        controller: String,
        timestampNs: Long,
        packetType: Int,
        availableMask: Long,
        pressedMask: Long,
        touchedMask: Long,
        changedMask: Long,
        triggerValue: Double,
        gripValue: Double,
        thumbstickX: Double,
        thumbstickY: Double,
        trackpadX: Double,
        trackpadY: Double
    ): Boolean {
        val payload = JSONObject()
            .put("controller", controller)
            .put("packet_type", packetType)
            .put("available_mask", availableMask)
            .put("pressed_mask", pressedMask)
            .put("touched_mask", touchedMask)
            .put("changed_mask", changedMask)
            .put("trigger_value", triggerValue)
            .put("grip_value", gripValue)
            .put("thumbstick", JSONObject().put("x", thumbstickX).put("y", thumbstickY))
            .put("trackpad", JSONObject().put("x", trackpadX).put("y", trackpadY))
            .toString()
            .toByteArray(Charsets.UTF_8)
        return enqueue(Frame(TYPE_CONTROLLER_INPUT, 0, timestampNs, DEFAULT_INPUT_DURATION_NS, payload), droppable = true)
    }

    private fun senderLoop() {
        val out = output
        if (out == null) {
            emitError("Live-push output stream is not available")
            running.set(false)
            return
        }
        try {
            while (running.get() || queue.isNotEmpty()) {
                val queued = queue.poll(QUEUE_POLL_MS, TimeUnit.MILLISECONDS) ?: continue
                val frame = queued.frame
                writeFrame(out, frame)
                metricFramesSent.incrementAndGet()
                metricBytesSent.addAndGet(frame.payload.size.toLong())
            }
            out.flush()
        } catch (error: Exception) {
            running.set(false)
            emitError("Live-push send failed: ${error.message}")
        } finally {
            try {
                out.flush()
            } catch (_: Exception) {
            }
        }
    }

    private fun writeFrame(out: DataOutputStream, frame: Frame) {
        out.write(MAGIC)
        out.writeByte(PROTOCOL_VERSION)
        out.writeByte(frame.type)
        out.writeShort(frame.flags)
        out.writeLong(frame.ptsNs)
        out.writeLong(frame.durationNs)
        out.writeInt(frame.payload.size)
        out.write(frame.payload)
    }

    private fun enqueueImportant(frame: Frame): Boolean = enqueue(frame, droppable = false)

    private fun enqueue(frame: Frame, droppable: Boolean): Boolean {
        if (!running.get()) {
            return false
        }
        val queued = QueuedFrame(frame, droppable)
        if (queue.offer(queued)) {
            return true
        }
        if (droppable) {
            val dropped = removeDropCandidate(frame.type)
            if (dropped != null) {
                recordDroppedFrame(dropped.frame)
            }
            if (queue.offer(queued)) {
                return true
            }
            recordDroppedFrame(frame)
            return false
        }

        val dropped = removeDropCandidate(null)
        if (dropped != null) {
            recordDroppedFrame(dropped.frame)
            if (queue.offer(queued)) {
                return true
            }
        }
        try {
            if (queue.offer(queued, IMPORTANT_OFFER_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                return true
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        emitError("Live-push queue is full of non-droppable frames; dropping critical frame type=${frame.type}")
        recordDroppedFrame(frame)
        return false
    }

    /**
     * Preserve tracking and depth under RGB congestion.
     *
     * A new droppable frame first evicts an older lower-priority frame, then an
     * older frame of its own type. It never evicts a different stream at the
     * same or higher priority. Important control/config frames may evict the
     * globally lowest-priority droppable frame.
     */
    private fun removeDropCandidate(incomingType: Int?): QueuedFrame? {
        val incomingPriority = incomingType?.let(::framePriority)
        var lowerPriorityCandidate: QueuedFrame? = null
        var lowerPriority = Int.MAX_VALUE
        var sameTypeCandidate: QueuedFrame? = null

        for (candidate in queue) {
            if (!candidate.droppable) {
                continue
            }
            val candidatePriority = framePriority(candidate.frame.type)
            if (incomingType == null) {
                if (candidatePriority < lowerPriority) {
                    lowerPriority = candidatePriority
                    lowerPriorityCandidate = candidate
                }
                continue
            }
            if (
                incomingPriority != null
                && candidatePriority < incomingPriority
                && candidatePriority < lowerPriority
            ) {
                lowerPriority = candidatePriority
                lowerPriorityCandidate = candidate
            } else if (
                sameTypeCandidate == null
                && candidate.frame.type == incomingType
            ) {
                sameTypeCandidate = candidate
            }
        }

        val selected = lowerPriorityCandidate ?: sameTypeCandidate ?: return null
        return if (queue.remove(selected)) selected else null
    }

    private fun framePriority(type: Int): Int = when (type) {
        TYPE_RGB_PACKET -> PRIORITY_RGB
        TYPE_DEPTH_FRAME -> PRIORITY_DEPTH
        TYPE_HEAD_POSE,
        TYPE_CONTROLLER_POSE,
        TYPE_HAND_JOINTS,
        TYPE_CONTROLLER_INPUT -> PRIORITY_TRACKING
        else -> PRIORITY_CONTROL
    }

    private fun encodeDepth(payload: ByteArray): DepthTransportCodec.Encoded {
        val encoded = DepthTransportCodec.encode(payload)
        metricDepthBytesRaw.addAndGet(encoded.uncompressedSize.toLong())
        metricDepthBytesWire.addAndGet(encoded.payload.size.toLong())
        if (encoded.compressed) {
            metricDepthFramesCompressed.incrementAndGet()
        }
        return encoded
    }

    private fun recordDroppedFrame(frame: Frame) {
        metricFramesDropped.incrementAndGet()
        metricBytesDropped.addAndGet(frame.payload.size.toLong())
    }

    private fun closeSocket() {
        try {
            output?.close()
        } catch (_: Exception) {
        }
        try {
            socket?.close()
        } catch (_: Exception) {
        }
        output = null
        socket = null
        senderThread = null
    }

    private fun emitError(message: String) {
        Log.e(TAG, message)
        emitSignal("live_feed_error", message)
        emitSignal("live_capture_error", message)
    }

    private fun emitConnected(endpoint: String) {
        emitSignal("live_feed_connected", endpoint)
        emitSignal("live_capture_connected", endpoint)
    }

    private fun emitDisconnected(endpoint: String) {
        emitSignal("live_feed_disconnected", endpoint)
        emitSignal("live_capture_disconnected", endpoint)
    }

    private fun sessionConfigJson(config: SessionConfig): JSONObject {
        return JSONObject()
            .put("contract_version", contractVersion)
            .put("partial_path", config.partialPath)
            .put("final_path", config.finalPath)
            .put("session_start_unix_us", config.sessionStartUnixUs)
            .put("session_start_godot_ticks_us", config.sessionStartGodotTicksUs)
            .put("rgb_width", config.rgbWidth)
            .put("rgb_height", config.rgbHeight)
            .put("rgb_fps", config.rgbFps)
            .put("rgb_camera_count", config.rgbCameraCount)
            .put("depth_expected", config.depthExpected)
            .put("head_pose_expected", config.headPoseExpected)
            .put("controller_pose_expected", config.controllerPoseExpected)
            .put("hand_joints_expected", config.handJointsExpected)
            .put("controller_input_expected", config.controllerInputExpected)
            .put("rgb_icam_base64", Base64.encodeToString(config.rgbIcam, Base64.NO_WRAP))
            .put("rgb_ecam_base64", Base64.encodeToString(config.rgbEcam, Base64.NO_WRAP))
            .put("rgb_dstr_base64", Base64.encodeToString(config.rgbDstr, Base64.NO_WRAP))
    }

    private fun jsonPayload(json: JSONObject, bytes: ByteArray): ByteArray {
        val jsonBytes = json.toString().toByteArray(Charsets.UTF_8)
        return ByteBuffer.allocate(Int.SIZE_BYTES + jsonBytes.size + bytes.size)
            .order(ByteOrder.BIG_ENDIAN)
            .putInt(jsonBytes.size)
            .put(jsonBytes)
            .put(bytes)
            .array()
    }

    private fun Intrinsics.toJson(): JSONObject {
        return JSONObject()
            .put("fx", fx)
            .put("fy", fy)
            .put("cx", cx)
            .put("cy", cy)
            .put("extrinsics_3x4", JSONArray(extrinsics3x4))
            .put("distortion", JSONArray(distortion))
            .put("width", width)
            .put("height", height)
    }

    private fun Thread.joinQuietly(timeoutMs: Long) {
        try {
            join(timeoutMs)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private data class Frame(
        val type: Int,
        val flags: Int,
        val ptsNs: Long,
        val durationNs: Long,
        val payload: ByteArray
    )

    private data class QueuedFrame(
        val frame: Frame,
        val droppable: Boolean
    )

    companion object {
        private const val TAG = "LivePush"
        private const val DEFAULT_HOST = "127.0.0.1"
        private const val DEFAULT_PORT = 63910
        private const val DEFAULT_CONNECT_TIMEOUT_MS = 2500
        private const val DEFAULT_QUEUE_FRAMES = 256
        private const val MIN_QUEUE_FRAMES = 16
        private const val MAX_QUEUE_FRAMES = 2048
        private const val SOCKET_BUFFER_BYTES = 256 * 1024
        private const val FINISH_JOIN_MS = 1500L
        private const val QUEUE_POLL_MS = 100L
        private const val IMPORTANT_OFFER_TIMEOUT_MS = 250L
        private val MAGIC = byteArrayOf('O'.code.toByte(), 'L'.code.toByte(), 'C'.code.toByte(), 'P'.code.toByte())
        private const val PROTOCOL_VERSION = 1

        private const val TYPE_SESSION_START = 1
        private const val TYPE_RGB_CSD = 2
        private const val TYPE_RGB_PACKET = 3
        private const val TYPE_DEPTH_METADATA = 4
        private const val TYPE_DEPTH_FRAME = 5
        private const val TYPE_HEAD_POSE = 6
        private const val TYPE_CONTROLLER_POSE = 7
        private const val TYPE_HAND_JOINTS = 8
        private const val TYPE_CONTROLLER_INPUT = 9
        private const val TYPE_SESSION_END = 10

        private const val FLAG_KEYFRAME = 1
        private const val FLAG_COMPOSITE_JSON = 2
        private const val FLAG_COMPRESSED_ZLIB = 4

        private const val PRIORITY_RGB = 0
        private const val PRIORITY_DEPTH = 1
        private const val PRIORITY_TRACKING = 2
        private const val PRIORITY_CONTROL = 3

        private const val DEFAULT_DEPTH_DURATION_NS = 200_000_000L
        private const val DEFAULT_POSE_DURATION_NS = 11_111_000L
        private const val DEFAULT_HAND_DURATION_NS = 33_333_000L
        private const val DEFAULT_INPUT_DURATION_NS = 1_000_000L
    }
}

class LiveFeedServerPlugin(godot: Godot) : LivePushPlugin(godot) {
    override fun getPluginName(): String = "LiveFeedServerPlugin"
}

class LiveCaptureServerPlugin(godot: Godot) : LivePushPlugin(godot) {
    override fun getPluginName(): String = "LiveCaptureServerPlugin"
}
