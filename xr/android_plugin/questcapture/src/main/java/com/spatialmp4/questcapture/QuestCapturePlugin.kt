package com.spatialmp4.questcapture

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.graphics.Rect
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.StreamConfigurationMap
import android.media.Image
import android.media.ImageReader
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.util.Size
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedWriter
import java.io.File
import java.io.FileWriter
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

class QuestCapturePlugin(godot: Godot) : GodotPlugin(godot) {
    private val mainActivity: Activity?
        get() = getActivity()

    private var sessionDir: File? = null
    private var backgroundThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null
    private var cameraManager: CameraManager? = null

    private val sessions = ConcurrentHashMap<String, EyeCameraSession>()
    private val frameIndexWriters = ConcurrentHashMap<String, BufferedWriter>()
    private val frameIndexCounters = ConcurrentHashMap<String, AtomicLong>()
    private var finalMp4Path: File? = null
    private var partialMp4Path: File? = null
    private var sidecarDir: File? = null
    // nativeWriterHandle migrated to SpatialMp4MuxerPlugin in Stage 2b. The
    // provider now hands the muxer a SessionConfig and lets it own the handle.
    private var hevcEncoder: StereoHevcEncoder? = null
    private var leftMetadata = "{}"
    private var rightMetadata = "{}"
    private var sessionStartUnixUs = 0L
    private var sessionStartGodotTicksUs = 0L
    private var configureGodotTicksUs = 0L
    private var configureElapsedRealtimeNs = 0L
    private var configureClockMonotonicNs = 0L
    private var configureUnixTimeMs = 0L
    private var recordDepth = true
    private var recordHeadPose = true
    private var recordControllerPose = true
    private var recordHandData = true
    private var recordControllerInput = true
    private var stereoRgb = true
    private var rgbBitrate = DEFAULT_RGB_BITRATE
    private var rgbFps = DEFAULT_RGB_FPS
    // depthStreamConfigured + lastDepthPtsUs migrated to SpatialMp4MuxerPlugin
    // alongside the writer handle (Stage 2b).
    @Volatile private var acceptingFrames = false

    // 1Hz metrics counters: incremented from camera / encoder / JNI threads,
    // popped + reset whenever GDScript calls popMetricsJson().
    private val metricCameraFramesLeft = AtomicLong(0L)
    private val metricCameraFramesRight = AtomicLong(0L)
    private val metricFrameIndexWrites = AtomicLong(0L)
    private val metricEncoderPairsOffered = AtomicLong(0L)
    private val metricEncoderMonoOffered = AtomicLong(0L)
    private val metricEncoderPacketsOut = AtomicLong(0L)
    // metricNativeWrite* counters migrated to SpatialMp4MuxerPlugin in Stage
    // 2b; GDScript hosts that want them call muxer.popMuxerMetricsJson().

    // Stage 2a forward-compatibility hook: GDScript host calls bindMuxer once
    // both Godot plugins are available so future stages can route RGB / depth
    // through SpatialDataSink without another GDScript round-trip. In Stage 2a
    // this reference is stored but unused; Stage 2c flips the RGB packet path
    // to call muxerSink.onRgbPacket(...) instead of SpatialMp4Native directly.
    @Volatile private var muxerSink: com.spatialmp4.contract.SpatialDataSink? = null

    override fun getPluginName(): String = "QuestCapturePlugin"

    override fun getPluginSignals(): Set<SignalInfo> {
        return setOf(
            SignalInfo("camera_ready", String::class.java, String::class.java),
            SignalInfo("camera_frame_saved", String::class.java, String::class.java, java.lang.Long::class.java),
            SignalInfo("camera_error", String::class.java)
        )
    }

    @UsedByGodot
    fun configureSession(path: String): Boolean {
        return configureSessionInternal(
            path,
            sessionStartUnixUs = 0L,
            sessionStartGodotTicksUs = 0L,
            configureGodotTicksUs = 0L
        )
    }

    @UsedByGodot
    fun configureSessionWithTime(
        path: String,
        sessionStartUnixUs: Long,
        sessionStartGodotTicksUs: Long,
        configureGodotTicksUs: Long
    ): Boolean {
        return configureSessionInternal(
            path,
            sessionStartUnixUs,
            sessionStartGodotTicksUs,
            configureGodotTicksUs
        )
    }

    @UsedByGodot
    fun configureSpatialMp4SessionWithTime(
        finalPath: String,
        partialPath: String,
        sidecarPath: String,
        sessionStartUnixUs: Long,
        sessionStartGodotTicksUs: Long,
        configureGodotTicksUs: Long,
        recordDepth: Boolean,
        recordHeadPose: Boolean,
        recordControllerPose: Boolean,
        recordHandData: Boolean,
        recordControllerInput: Boolean,
        stereoRgb: Boolean,
        rgbBitrate: Int,
        rgbFps: Int
    ): Boolean {
        return configureSessionInternal(
            sidecarPath,
            sessionStartUnixUs,
            sessionStartGodotTicksUs,
            configureGodotTicksUs,
            finalPath,
            partialPath,
            recordDepth,
            recordHeadPose,
            recordControllerPose,
            recordHandData,
            recordControllerInput,
            stereoRgb,
            rgbBitrate,
            rgbFps
        )
    }

    private fun configureSessionInternal(
        path: String,
        sessionStartUnixUs: Long,
        sessionStartGodotTicksUs: Long,
        configureGodotTicksUs: Long,
        finalPath: String? = null,
        partialPath: String? = null,
        recordDepth: Boolean = true,
        recordHeadPose: Boolean = true,
        recordControllerPose: Boolean = true,
        recordHandData: Boolean = true,
        recordControllerInput: Boolean = true,
        stereoRgb: Boolean = true,
        rgbBitrate: Int = DEFAULT_RGB_BITRATE,
        rgbFps: Int = DEFAULT_RGB_FPS
    ): Boolean {
        val dir = File(path)
        try {
            if (!ensureDirectory(dir)) {
                emitSignal("camera_error", "Failed to create session directory: $path")
                return false
            }
            finalPath?.let { File(it).parentFile?.let(::ensureDirectory) }
            partialPath?.let {
                val file = File(it)
                file.parentFile?.let(::ensureDirectory)
                file.delete()
            }
        } catch (error: Exception) {
            emitSignal("camera_error", "Failed to prepare session directory: $path (${error.message})")
            return false
        }

        sessionDir = dir
        sidecarDir = dir
        finalMp4Path = finalPath?.let { File(it) }
        partialMp4Path = partialPath?.let { File(it) }
        this.sessionStartUnixUs = sessionStartUnixUs
        this.sessionStartGodotTicksUs = sessionStartGodotTicksUs
        this.configureGodotTicksUs = configureGodotTicksUs
        this.recordDepth = recordDepth
        this.recordHeadPose = recordHeadPose
        this.recordControllerPose = recordControllerPose
        this.recordHandData = recordHandData
        this.recordControllerInput = recordControllerInput
        this.stereoRgb = stereoRgb
        this.rgbBitrate = if (rgbBitrate > 0) rgbBitrate else DEFAULT_RGB_BITRATE
        this.rgbFps = if (rgbFps > 0) rgbFps else DEFAULT_RGB_FPS
        // Capture all clock anchors back-to-back so the deltas between them stay
        // sub-microsecond. CLOCK_MONOTONIC is the same clock Godot's
        // Time.get_ticks_usec() uses on Android, and is also what Camera2 reports
        // for SENSOR_INFO_TIMESTAMP_SOURCE_UNKNOWN (the Quest3 default). The
        // elapsedRealtime nanos are CLOCK_BOOTTIME, used for REALTIME sources.
        configureClockMonotonicNs = System.nanoTime()
        configureElapsedRealtimeNs = SystemClock.elapsedRealtimeNanos()
        configureUnixTimeMs = System.currentTimeMillis()
        try {
            writeAndroidTimebase(dir, leftTimestampSource = null, rightTimestampSource = null)
        } catch (error: Exception) {
            emitSignal("camera_error", "Failed to write timebase in session directory: $path (${error.message})")
            sessionDir = null
            return false
        }
        return true
    }

    @UsedByGodot
    fun requestStoragePermission() {
        val activity = mainActivity ?: return
        if (hasStoragePermission()) {
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val packageUri = Uri.parse("package:${activity.packageName}")
            try {
                activity.startActivity(
                    Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, packageUri)
                )
            } catch (_: Exception) {
                activity.startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
            return
        }
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
            REQUEST_STORAGE_PERMISSION
        )
    }

    @UsedByGodot
    fun hasStoragePermission(): Boolean {
        val activity = mainActivity ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            ContextCompat.checkSelfPermission(activity, Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }
    }

    @UsedByGodot
    fun ensureOutputDirectory(path: String): Boolean {
        if (path.isBlank()) {
            emitSignal("camera_error", "Capture output path is empty")
            return false
        }
        if (!hasStoragePermission()) {
            requestStoragePermission()
            emitSignal("camera_error", "Shared-storage permission is required for: $path")
            return false
        }
        val dir = File(path)
        return try {
            if (!ensureDirectory(dir)) {
                emitSignal("camera_error", "Failed to create capture output directory: $path")
                false
            } else {
                val probe = File(dir, ".spatialmp4_write_probe")
                probe.writeText("probe")
                probe.delete()
                true
            }
        } catch (error: Exception) {
            emitSignal("camera_error", "Capture output directory is not writable: $path (${error.message})")
            false
        }
    }

    @UsedByGodot
    fun getStorageUsageJson(path: String): String {
        // Report the filesystem totals for the volume that backs `path`, plus
        // how much the SpatialMP4 capture tree currently occupies, so the
        // settings panel can show "how much room is left" before a recording.
        val requested = if (path.isBlank()) {
            Environment.getExternalStorageDirectory().absolutePath
        } else {
            path
        }
        return try {
            // StatFs needs an existing directory; walk up to the nearest
            // existing ancestor of the (possibly not-yet-created) save root.
            var probe = File(requested)
            while (!probe.exists() && probe.parentFile != null) {
                probe = probe.parentFile!!
            }
            val statPath = if (probe.exists()) {
                probe.absolutePath
            } else {
                Environment.getExternalStorageDirectory().absolutePath
            }
            val stat = android.os.StatFs(statPath)
            val blockSize = stat.blockSizeLong
            val totalBytes = stat.blockCountLong * blockSize
            val availableBytes = stat.availableBlocksLong * blockSize
            val freeBytes = stat.freeBlocksLong * blockSize
            val usedBytes = totalBytes - freeBytes
            val captureRoot = File(requested)
            val captureBytes = if (captureRoot.exists()) directorySize(captureRoot) else 0L
            JSONObject()
                .put("path", statPath)
                .put("total_bytes", totalBytes)
                .put("free_bytes", freeBytes)
                .put("available_bytes", availableBytes)
                .put("used_bytes", usedBytes)
                .put("capture_dir_bytes", captureBytes)
                .toString()
        } catch (error: Exception) {
            JSONObject().put("error", error.message ?: "unknown").toString()
        }
    }

    private fun directorySize(target: File): Long {
        if (!target.exists()) return 0L
        if (target.isFile) return target.length()
        var sum = 0L
        val children = target.listFiles() ?: return 0L
        for (child in children) {
            sum += directorySize(child)
        }
        return sum
    }

    @UsedByGodot
    fun requestCameraPermission() {
        val activity = mainActivity ?: return
        val missing = requiredPermissions().filter {
            ContextCompat.checkSelfPermission(activity, it) != PackageManager.PERMISSION_GRANTED
        }

        if (missing.isNotEmpty()) {
            ActivityCompat.requestPermissions(activity, missing.toTypedArray(), REQUEST_CAMERA_PERMISSIONS)
        }
    }

    @UsedByGodot
    fun hasCameraPermission(): Boolean {
        val activity = mainActivity ?: return false
        return requiredPermissions().all {
            ContextCompat.checkSelfPermission(activity, it) == PackageManager.PERMISSION_GRANTED
        }
    }

    @UsedByGodot
    fun startCameras(): Boolean {
        val activity = mainActivity ?: return false
        val root = sessionDir ?: run {
            emitSignal("camera_error", "configureSession must be called before startCameras")
            return false
        }

        Log.i(TAG, "startCameras root=${root.absolutePath} cameraPermission=${hasCameraPermission()}")
        if (!hasCameraPermission()) {
            requestCameraPermission()
            emitSignal("camera_error", "Camera permission is not granted yet")
            return false
        }

        ensureBackgroundThread()
        cameraManager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager

        val cameras = findPassthroughCameras(cameraManager!!)
        Log.i(TAG, "passthrough cameras found=${cameras.keys.sorted()}")
        if (!cameras.containsKey("left") || (stereoRgb && !cameras.containsKey("right"))) {
            val requiredEyes = if (stereoRgb) "left/right" else "left"
            emitSignal("camera_error", "Quest passthrough $requiredEyes cameras were not found")
            return false
        }

        val leftConfig = cameras["left"] ?: return false
        val rightConfig = if (stereoRgb) cameras["right"] else null
        leftMetadata = leftConfig.metadata.toString()
        rightMetadata = rightConfig?.metadata?.toString() ?: "{}"
        writeText(File(root, "left_camera_characteristics.json"), leftMetadata)
        if (rightConfig != null) {
            writeText(File(root, "right_camera_characteristics.json"), rightMetadata)
        } else {
            File(root, "right_camera_characteristics.json").delete()
        }
        try {
            writeAndroidTimebase(
                root,
                leftTimestampSource = leftConfig.timestampSource,
                rightTimestampSource = rightConfig?.timestampSource
            )
        } catch (error: Exception) {
            Log.w(TAG, "Failed to refresh android_timebase.json with camera sources: ${error.message}")
        }

        if (!startNativeWriter(root, leftConfig, rightConfig)) {
            return false
        }

        openFrameIndexWriter(root, "left")
        if (rightConfig != null) {
            openFrameIndexWriter(root, "right")
        } else {
            File(root, "right_camera_frames.jsonl").delete()
        }

        acceptingFrames = true
        openEyeCamera("left", leftConfig)
        if (rightConfig != null) {
            openEyeCamera("right", rightConfig)
        }

        return true
    }

    @UsedByGodot
    fun stopCameras() {
        acceptingFrames = false
        val handler = backgroundHandler
        if (handler != null && Looper.myLooper() != handler.looper) {
            val stopped = CountDownLatch(1)
            handler.post {
                try {
                    closeCamerasAndEncoder()
                } finally {
                    stopped.countDown()
                }
            }
            if (!stopped.await(STOP_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                emitSignal("camera_error", "Timed out while stopping camera capture")
            }
        } else {
            closeCamerasAndEncoder()
        }

        backgroundThread?.quitSafely()
        backgroundThread = null
        backgroundHandler = null
    }

    private fun closeCamerasAndEncoder() {
        sessions.values.forEach { it.close() }
        sessions.clear()
        hevcEncoder?.stopAndDrain()
        hevcEncoder = null
        closeFrameIndexWriters()
    }

    /**
     * Stage 2a wiring: host GDScript hands us the SpatialMp4MuxerPlugin
     * instance so we can store it as a SpatialDataSink. Returns false if the
     * object does not implement the contract (e.g. an older muxer AAR is
     * paired with a newer provider). Stage 2a stores the reference but does
     * not yet route anything through it; Stage 2c flips RGB packets over.
     */
    @UsedByGodot
    fun bindMuxer(muxer: Any?): Boolean {
        if (muxer == null) {
            muxerSink = null
            return true
        }
        val sink = muxer as? com.spatialmp4.contract.SpatialDataSink
        if (sink == null) {
            Log.w(TAG, "bindMuxer received an object that does not implement SpatialDataSink")
            return false
        }
        if (sink.contractVersion != com.spatialmp4.contract.CONTRACT_VERSION) {
            Log.w(
                TAG,
                "muxer contract v${sink.contractVersion} differs from provider v${com.spatialmp4.contract.CONTRACT_VERSION}; binding anyway, expect feature gaps"
            )
        }
        muxerSink = sink
        return true
    }

    @UsedByGodot
    fun getXrTimeToGodotTicksOffsetNs(): Long {
        // Difference between Godot's `Time.get_ticks_usec()` clock (epoch =
        // Godot process start, ticks in CLOCK_MONOTONIC ns) and Android's
        // CLOCK_MONOTONIC ns since boot, captured at configure time. Add this
        // to any CLOCK_MONOTONIC-since-boot timestamp (e.g. OpenXR XrTime) to
        // bring it into the Godot-ticks-ns domain the live mux PTS uses.
        if (configureGodotTicksUs <= 0L || configureClockMonotonicNs <= 0L) {
            return 0L
        }
        return configureGodotTicksUs * 1000L - configureClockMonotonicNs
    }

    // finishSpatialMp4 / writeDepthFrame / writeHeadPose / writeControllerPose /
    // writeHandJointsPayload / writeControllerInput were all relocated to
    // SpatialMp4MuxerPlugin as part of Stage 2b. GDScript callers now resolve
    // the muxer singleton via Engine.get_singleton("SpatialMp4MuxerPlugin").

    @UsedByGodot
    fun getLeftCameraMetadataJson(): String = leftMetadata

    @UsedByGodot
    fun getRightCameraMetadataJson(): String = rightMetadata

    /**
     * GDScript-facing accessor for the headset identity captured from
     * android.os.Build. Mirrors what is written into the mp4 moov metadata, so
     * the session manifest.json sidecar can carry the same device_type /
     * device_model / device_manufacturer values without re-deriving them.
     */
    @UsedByGodot
    fun getDeviceIdentityJson(): String {
        val identity = DeviceIdentity.detect()
        return JSONObject()
            .put("device_type", identity.type)
            .put("device_model", identity.model)
            .put("device_manufacturer", identity.manufacturer)
            .put("device_build_device", identity.device)
            .toString()
    }

    @UsedByGodot
    fun convertOpenxrDepthRhToU16Mm(
        raw: ByteArray,
        width: Int,
        height: Int,
        invProjViewRow3: DoubleArray
    ): ByteArray {
        // Drop-in replacement for the GDScript inner loop in
        // depth_sampler._convert_openxr_depth_to_u16_mm. That loop was
        // running 320 × 320 × 5 Hz ≈ 500k iters/s of pure GDScript inside the
        // OpenXR depth deferred callback — 750-950 ms/s of main-thread CPU,
        // which directly throttled Godot's XR render rate to ~17 fps and
        // made the panels feel laggy. Same arithmetic, executed in JVM
        // primitives, drops the cost to < 1 ms per frame.
        //
        // Only the inverse projection-view matrix's row 3 is needed: it
        // encodes the perspective-divide w that gives 1/Z in eye space.
        if (width <= 0 || height <= 0) return ByteArray(0)
        val expected = width * height * 2
        if (raw.size < expected) return ByteArray(0)
        if (invProjViewRow3.size < 4) return ByteArray(0)
        val out = ByteArray(expected)
        val r0 = invProjViewRow3[0]
        val r1 = invProjViewRow3[1]
        val r2 = invProjViewRow3[2]
        val r3 = invProjViewRow3[3]
        val invW = 1.0 / width.toDouble()
        val invH = 1.0 / height.toDouble()
        val invMax = 1.0 / 65535.0
        var index = 0
        for (y in 0 until height) {
            val clipY = 2.0 * (y.toDouble() + 0.5) * invH - 1.0
            val r1y = r1 * clipY
            for (x in 0 until width) {
                val srcOffset = index shl 1
                val raw0 = raw[srcOffset].toInt() and 0xff
                val raw1 = raw[srcOffset + 1].toInt() and 0xff
                val u16 = raw0 or (raw1 shl 8)
                val normalized = u16 * invMax
                var mm = 0
                if (normalized in 0.0..1.0) {
                    val clipX = 2.0 * (x.toDouble() + 0.5) * invW - 1.0
                    val clipZ = 2.0 * normalized - 1.0
                    val homogW = r0 * clipX + r1y + r2 * clipZ + r3
                    if (homogW > 0.0) {
                        val meters = 1.0 / homogW
                        if (meters.isFinite() && meters > 0.0) {
                            val mmRaw = (meters * 1000.0 + 0.5).toInt()
                            mm = if (mmRaw < 0) 0 else if (mmRaw > 65535) 65535 else mmRaw
                        }
                    }
                }
                out[srcOffset] = (mm and 0xff).toByte()
                out[srcOffset + 1] = ((mm shr 8) and 0xff).toByte()
                index += 1
            }
        }
        return out
    }

    @UsedByGodot
    fun popMetricsJson(): String {
        // Snapshot every provider-side counter atomically and serialise as
        // JSON. The native_*_writes counters moved to SpatialMp4MuxerPlugin
        // along with the writer handle; GDScript hosts that want both should
        // call popMuxerMetricsJson() on the muxer singleton too.
        val payload = JSONObject()
            .put("cam_frames_left", metricCameraFramesLeft.getAndSet(0L))
            .put("cam_frames_right", metricCameraFramesRight.getAndSet(0L))
            .put("frame_index_writes", metricFrameIndexWrites.getAndSet(0L))
            .put("enc_pairs_in", metricEncoderPairsOffered.getAndSet(0L))
            .put("enc_mono_in", metricEncoderMonoOffered.getAndSet(0L))
            .put("enc_packets_out", metricEncoderPacketsOut.getAndSet(0L))
        return payload.toString()
    }


    private fun ensureBackgroundThread() {
        if (backgroundThread != null && backgroundHandler != null) {
            return
        }

        val thread = HandlerThread("QuestCaptureCamera")
        thread.start()
        backgroundThread = thread
        backgroundHandler = Handler(thread.looper)
    }

    private fun findPassthroughCameras(manager: CameraManager): Map<String, CameraConfig> {
        val result = mutableMapOf<String, CameraConfig>()
        for (cameraId in manager.cameraIdList) {
            val characteristics = manager.getCameraCharacteristics(cameraId)
            val cameraSource = readVendorInt(
                characteristics,
                "com.meta.extra_metadata.camera_source"
            )
            val position = readVendorInt(
                characteristics,
                "com.meta.extra_metadata.position"
            )
            Log.i(TAG, "cameraId=$cameraId source=$cameraSource position=$position")

            if (cameraSource != META_CAMERA_SOURCE_PASSTHROUGH || position == null) {
                continue
            }

            val eye = when (position) {
                META_CAMERA_POSITION_LEFT -> "left"
                META_CAMERA_POSITION_RIGHT -> "right"
                else -> continue
            }

            result[eye] = CameraConfig(
                cameraId = cameraId,
                size = chooseYuvSize(characteristics),
                timestampSource = characteristics.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE),
                metadata = cameraMetadataJson(cameraId, eye, characteristics)
            )
        }
        return result
    }

    private fun startNativeWriter(root: File, leftConfig: CameraConfig, rightConfig: CameraConfig?): Boolean {
        // Prefer the explicitly-bound sink (bindMuxer) so a test can inject a
        // mock; otherwise fall back to the muxer plugin's static registry,
        // which the SpatialMp4MuxerPlugin populates from its init { } block.
        // This is necessary because @UsedByGodot does not marshal arbitrary
        // Godot Object arguments, so GDScript cannot hand us the sink ref.
        val sink = muxerSink ?: SpatialMp4MuxerPlugin.activeSink
        if (sink == null) {
            emitSignal("camera_error", "SpatialMp4MuxerPlugin singleton not installed; add the spatialmp4_muxer addon AAR")
            return false
        }
        if (stereoRgb && rightConfig == null) {
            emitSignal("camera_error", "Stereo RGB requested without a right camera")
            return false
        }
        if (rightConfig != null &&
            (leftConfig.size.width != rightConfig.size.width || leftConfig.size.height != rightConfig.size.height)
        ) {
            emitSignal("camera_error", "Left/right camera sizes do not match")
            return false
        }

        val finalPath = finalMp4Path ?: File(root.parentFile ?: root, "${root.name}.mp4")
        val partialPath = partialMp4Path ?: File(finalPath.parentFile ?: root, "${finalPath.nameWithoutExtension}.partial.mp4")
        finalMp4Path = finalPath
        partialMp4Path = partialPath

        val rgbSideData = SpatialMp4SideDataPacker.packRgb(leftConfig.metadata, rightConfig?.metadata)
        val rgbWidth = leftConfig.size.width + (rightConfig?.size?.width ?: 0)
        val rgbCameraCount = if (rightConfig == null) 1 else 2
        val deviceIdentity = DeviceIdentity.detect()
        Log.i(
            TAG,
            "device identity: type=${deviceIdentity.type} model=${deviceIdentity.model} manufacturer=${deviceIdentity.manufacturer}"
        )
        val sessionConfig = com.spatialmp4.contract.SessionConfig(
            partialPath = partialPath.absolutePath,
            finalPath = finalPath.absolutePath,
            sessionStartUnixUs = sessionStartUnixUs,
            sessionStartGodotTicksUs = sessionStartGodotTicksUs,
            rgbWidth = rgbWidth,
            rgbHeight = leftConfig.size.height,
            rgbFps = rgbFps,
            rgbCameraCount = rgbCameraCount,
            depthExpected = recordDepth,
            headPoseExpected = recordHeadPose,
            controllerPoseExpected = recordControllerPose,
            handJointsExpected = recordHandData,
            controllerInputExpected = recordControllerInput,
            rgbIcam = rgbSideData.icam,
            rgbEcam = rgbSideData.ecam,
            rgbDstr = rgbSideData.dstr,
            deviceType = deviceIdentity.type,
            deviceModel = deviceIdentity.model,
            deviceManufacturer = deviceIdentity.manufacturer
        )
        if (!sink.startSession(sessionConfig)) {
            // sink already logged + emitted; nothing more to do.
            return false
        }

        // RGB encoder writes packets via the sink contract. Stage 2c removed
        // the StereoHevcEncoder's nativeHandle reference -- the encoder now
        // calls sink.onRgbCsd / onRgbPacket and is unaware of the underlying
        // libspatialmp4_writer JNI surface.
        val cameraIntrinsics = mutableListOf<com.spatialmp4.contract.Intrinsics>()
        cameraIntrinsics += SpatialMp4SideDataPacker.extractIntrinsics(
            leftConfig.metadata, leftConfig.size.width, leftConfig.size.height
        )
        if (rightConfig != null) {
            cameraIntrinsics += SpatialMp4SideDataPacker.extractIntrinsics(
                rightConfig.metadata, rightConfig.size.width, rightConfig.size.height
            )
        }
        val encoder = StereoHevcEncoder(
            dataSink = sink,
            eyeWidth = leftConfig.size.width,
            eyeHeight = leftConfig.size.height,
            fps = rgbFps,
            bitrate = rgbBitrate,
            stereo = rightConfig != null,
            cameraIntrinsics = cameraIntrinsics,
            onError = { message -> emitSignal("camera_error", message) },
            onPairEncoded = { metricEncoderPairsOffered.incrementAndGet() },
            onMonoEncoded = { metricEncoderMonoOffered.incrementAndGet() },
            onPacketEmitted = { metricEncoderPacketsOut.incrementAndGet() }
        )
        if (!encoder.start()) {
            sink.finishSession()
            return false
        }
        hevcEncoder = encoder
        Log.i(TAG, "SpatialMP4 live writer started stereo=${rightConfig != null} partial=${partialPath.absolutePath} final=${finalPath.absolutePath}")
        return true
    }

    private fun openEyeCamera(eye: String, config: CameraConfig) {
        val manager = cameraManager ?: return
        val handler = backgroundHandler ?: return
        if (!acceptingFrames) {
            return
        }

        Log.i(TAG, "opening $eye camera id=${config.cameraId} size=${config.size}")
        val imageReader = ImageReader.newInstance(
            config.size.width,
            config.size.height,
            ImageFormat.YUV_420_888,
            IMAGE_READER_MAX_IMAGES
        )
        imageReader.setOnImageAvailableListener(
            { reader -> encodeLatestImage(eye, config, reader) },
            handler
        )

        val stateCallback = object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) {
                if (!acceptingFrames) {
                    imageReader.close()
                    camera.close()
                    return
                }
                val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
                request.addTarget(imageReader.surface)
                // Lock Camera2 to the configured rgbFps. Without this the
                // Quest passthrough cameras default to ~90 fps, which
                // saturates the bg-thread encoder + bg-thread frame-index
                // writer + bg-thread mp4 muxer with 3× the work the encoder
                // config actually targets, and the Android scheduler then
                // starves the Godot main render thread → UI feels laggy
                // even when nothing on the main thread is busy. Pinning the
                // FPS range to [rgbFps, rgbFps] aligns producer rate with
                // declared encoder rate.
                request.set(
                    CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                    android.util.Range(rgbFps, rgbFps)
                )

                camera.createCaptureSession(
                    listOf(imageReader.surface),
                    object : CameraCaptureSession.StateCallback() {
                        override fun onConfigured(session: CameraCaptureSession) {
                            if (!acceptingFrames) {
                                session.close()
                                camera.close()
                                imageReader.close()
                                return
                            }
                            sessions[eye] = EyeCameraSession(camera, session, imageReader)
                            session.setRepeatingRequest(
                                request.build(),
                                null,
                                handler
                            )
                            Log.i(TAG, "$eye camera configured id=${config.cameraId}")
                            emitSignal("camera_ready", eye, config.cameraId)
                        }

                        override fun onConfigureFailed(session: CameraCaptureSession) {
                            Log.e(TAG, "failed to configure $eye camera")
                            emitSignal("camera_error", "Failed to configure $eye camera")
                        }
                    },
                    handler
                )
            }

            override fun onDisconnected(camera: CameraDevice) {
                Log.w(TAG, "$eye camera disconnected")
                emitSignal("camera_error", "$eye camera disconnected")
                camera.close()
            }

            override fun onError(camera: CameraDevice, error: Int) {
                Log.e(TAG, "$eye camera error: $error")
                emitSignal("camera_error", "$eye camera error: $error")
                camera.close()
            }
        }

        try {
            if (ActivityCompat.checkSelfPermission(requireContext(), Manifest.permission.CAMERA)
                == PackageManager.PERMISSION_GRANTED
            ) {
                manager.openCamera(config.cameraId, stateCallback, handler)
            }
        } catch (security: SecurityException) {
            Log.e(TAG, "Camera permission denied", security)
            emitSignal("camera_error", "Camera permission denied: ${security.message}")
        }
    }

    private fun encodeLatestImage(eye: String, config: CameraConfig, reader: ImageReader) {
        if (!acceptingFrames) {
            reader.acquireLatestImage()?.close()
            return
        }
        val image = reader.acquireLatestImage() ?: return
        image.use {
            if (!acceptingFrames) {
                return@use
            }
            // Use the Camera2 sensor timestamp directly — both REALTIME
            // (CLOCK_BOOTTIME) and the Quest default UNKNOWN (CLOCK_MONOTONIC)
            // are translated to the Godot ticks domain via the corresponding
            // bridge captured at configure time, so we do not fall back to a
            // callback-time approximation any more.
            val cameraSensorTimestampNs = image.timestamp
            val timestampNs = cameraSensorToGodotTicksNs(cameraSensorTimestampNs, config.timestampSource)
            if (eye == "left") metricCameraFramesLeft.incrementAndGet()
            else if (eye == "right") metricCameraFramesRight.incrementAndGet()
            // Sniff NV12 vs NV21 layout BEFORE copying planes into ByteArrays.
            // If we cannot prove the shared-buffer ordering, the encoder falls
            // back to the public YUV_420_888 per-plane contract for correctness.
            val chromaLayout = detectSemiPlanarLayout(image.planes)
            val planeCaptures = image.planes.mapIndexed { index, plane ->
                YuvPlaneCapture(
                    index = index,
                    rowStride = plane.rowStride,
                    pixelStride = plane.pixelStride,
                    bytes = readPlane(plane.buffer)
                )
            }
            hevcEncoder?.offer(
                CapturedYuvFrame(
                    eye = eye,
                    timestampNs = timestampNs,
                    width = image.width,
                    height = image.height,
                    planes = planeCaptures,
                    chromaLayout = chromaLayout
                )
            )
            writeFrameIndex(
                eye = eye,
                config = config,
                godotTicksNs = timestampNs,
                cameraSensorTimestampNs = cameraSensorTimestampNs,
                width = image.width,
                height = image.height
            )
            emitSignal("camera_frame_saved", eye, finalMp4Path?.absolutePath ?: "", timestampNs)
        }
    }

    private fun chooseYuvSize(characteristics: CameraCharacteristics): Size {
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            as StreamConfigurationMap?
        val sizes = map?.getOutputSizes(ImageFormat.YUV_420_888)
        return sizes?.maxByOrNull { it.width * it.height }
            ?: characteristics.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE)
            ?: Size(1280, 960)
    }

    private fun cameraMetadataJson(
        cameraId: String,
        eye: String,
        characteristics: CameraCharacteristics
    ): JSONObject {
        return JSONObject()
            .put("camera_id", cameraId)
            .put("eye", eye)
            .putArray("lens_intrinsic_calibration",
                characteristics.get(CameraCharacteristics.LENS_INTRINSIC_CALIBRATION))
            .putArray("lens_distortion",
                characteristics.get(CameraCharacteristics.LENS_DISTORTION))
            .putArray("lens_pose_translation",
                characteristics.get(CameraCharacteristics.LENS_POSE_TRANSLATION))
            .putArray("lens_pose_rotation",
                characteristics.get(CameraCharacteristics.LENS_POSE_ROTATION))
            .putSize("sensor_pixel_array_size",
                characteristics.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE))
            .putRect("sensor_active_array_size",
                characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE))
            .put("sensor_timestamp_source",
                characteristics.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE))
    }

    private fun readVendorInt(characteristics: CameraCharacteristics, name: String): Int? {
        @Suppress("UNCHECKED_CAST")
        val key = characteristics.keys.firstOrNull { it.name == name }
            as? CameraCharacteristics.Key<Any> ?: return null
        return try {
            when (val value = characteristics.get(key)) {
                is ByteArray -> value.firstOrNull()?.toInt()
                is Number -> value.toInt()
                else -> null
            }
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    private fun readPlane(buffer: ByteBuffer): ByteArray {
        val copy = buffer.slice()
        val bytes = ByteArray(copy.remaining())
        copy.get(bytes)
        return bytes
    }

    private fun detectSemiPlanarLayout(planes: Array<android.media.Image.Plane>): ChromaLayout {
        if (planes.size < 3) return ChromaLayout.UNKNOWN
        val u = planes[1]
        val v = planes[2]
        if (u.pixelStride != 2 || v.pixelStride != 2) return ChromaLayout.UNKNOWN
        val uAddr = directBufferAddress(u.buffer)
        val vAddr = directBufferAddress(v.buffer)
        if (uAddr == 0L || vAddr == 0L) return ChromaLayout.UNKNOWN
        return when (vAddr) {
            uAddr + 1L -> ChromaLayout.NV12
            uAddr - 1L -> ChromaLayout.NV21
            else -> ChromaLayout.UNKNOWN
        }
    }

    private fun directBufferAddress(buf: ByteBuffer): Long {
        if (!buf.isDirect) return 0L
        return try {
            val field = java.nio.Buffer::class.java.getDeclaredField("address")
            field.isAccessible = true
            field.getLong(buf) + buf.position()
        } catch (_: Throwable) {
            0L
        }
    }

    private fun openFrameIndexWriter(root: File, eye: String) {
        try {
            val target = File(root, "${eye}_camera_frames.jsonl")
            target.parentFile?.mkdirs()
            frameIndexWriters[eye] = BufferedWriter(FileWriter(target, false))
            frameIndexCounters[eye] = AtomicLong(0L)
        } catch (error: Exception) {
            Log.w(TAG, "Failed to open ${eye}_camera_frames.jsonl: ${error.message}")
        }
    }

    private fun closeFrameIndexWriters() {
        frameIndexWriters.values.forEach { writer ->
            try {
                writer.flush()
                writer.close()
            } catch (_: Exception) {
            }
        }
        frameIndexWriters.clear()
        frameIndexCounters.clear()
    }

    private fun writeFrameIndex(
        eye: String,
        config: CameraConfig,
        godotTicksNs: Long,
        cameraSensorTimestampNs: Long,
        width: Int,
        height: Int
    ) {
        val writer = frameIndexWriters[eye] ?: return
        val counter = frameIndexCounters[eye] ?: return
        val index = counter.getAndIncrement()
        val record = JSONObject()
            .put("frame_index", index)
            .put("eye", eye)
            .put("timestamp_ns", godotTicksNs)
            .put("camera_sensor_timestamp_ns", cameraSensorTimestampNs)
            .put("sensor_timestamp_source", timestampSourceName(config.timestampSource))
            .put("camera_id", config.cameraId)
            .put("width", width)
            .put("height", height)
            .put("raw_path", "")
            .put("planes", JSONArray())
        try {
            synchronized(writer) {
                writer.write(record.toString())
                writer.write("\n")
            }
            metricFrameIndexWrites.incrementAndGet()
        } catch (error: Exception) {
            Log.w(TAG, "Failed to append ${eye}_camera_frames.jsonl: ${error.message}")
        }
    }

    private fun cameraSensorToGodotTicksNs(sensorTimestampNs: Long, sensorSource: Int?): Long {
        if (configureGodotTicksUs <= 0L) {
            return sensorTimestampNs
        }
        val configureGodotTicksNs = configureGodotTicksUs * 1000L
        return when (sensorSource) {
            CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME -> {
                if (configureElapsedRealtimeNs <= 0L) sensorTimestampNs
                else configureGodotTicksNs + (sensorTimestampNs - configureElapsedRealtimeNs)
            }
            else -> {
                // SENSOR_INFO_TIMESTAMP_SOURCE_UNKNOWN on Quest is CLOCK_MONOTONIC,
                // the same clock Godot's Time.get_ticks_usec() reads. The two
                // anchors were captured back-to-back, so the offset is at most a
                // few microseconds of call gap (and zero in steady state).
                if (configureClockMonotonicNs <= 0L) sensorTimestampNs
                else configureGodotTicksNs + (sensorTimestampNs - configureClockMonotonicNs)
            }
        }
    }

    private fun timestampSourceName(source: Int?): String {
        return when (source) {
            CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME -> "realtime"
            CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_UNKNOWN -> "unknown_monotonic"
            null -> "unspecified"
            else -> "code_$source"
        }
    }

    private fun writeAndroidTimebase(
        dir: File,
        leftTimestampSource: Int?,
        rightTimestampSource: Int?
    ) {
        val configureGodotTicksNs = configureGodotTicksUs * 1000L
        val monoToGodotOffsetNs = if (configureClockMonotonicNs > 0L) {
            configureGodotTicksNs - configureClockMonotonicNs
        } else {
            0L
        }
        val boottimeToGodotOffsetNs = if (configureElapsedRealtimeNs > 0L) {
            configureGodotTicksNs - configureElapsedRealtimeNs
        } else {
            0L
        }
        val rgbSources = JSONObject()
        if (leftTimestampSource != null) {
            rgbSources.put("left", timestampSourceName(leftTimestampSource))
            rgbSources.put("left_code", leftTimestampSource)
        }
        if (rightTimestampSource != null) {
            rgbSources.put("right", timestampSourceName(rightTimestampSource))
            rgbSources.put("right_code", rightTimestampSource)
        }
        val record = JSONObject()
            .put("session_start_unix_us", sessionStartUnixUs)
            .put("session_start_godot_ticks_us", sessionStartGodotTicksUs)
            .put("configure_godot_ticks_us", configureGodotTicksUs)
            .put("configure_clock_monotonic_ns", configureClockMonotonicNs)
            .put("configure_elapsed_realtime_ns", configureElapsedRealtimeNs)
            .put("configure_unix_time_ms", configureUnixTimeMs)
            .put("rgb_timestamp_domain", "godot_ticks_ns")
            .put("godot_ticks_clock", "clock_monotonic_ns")
            .put("clock_monotonic_to_godot_ticks_ns_offset", monoToGodotOffsetNs)
            .put("clock_boottime_to_godot_ticks_ns_offset", boottimeToGodotOffsetNs)
            .put("openxr_xr_time_domain", "clock_monotonic_ns")
            .put("openxr_xr_time_to_godot_ticks_ns_offset", monoToGodotOffsetNs)
            .put("rgb_sensor_timestamp_sources", rgbSources)
        writeText(File(dir, "android_timebase.json"), record.toString(2))
    }

    private fun requireContext(): Context {
        return mainActivity ?: throw IllegalStateException("Godot activity is not available")
    }

    private fun requiredPermissions(): List<String> = listOf(
        Manifest.permission.CAMERA,
        "horizonos.permission.HEADSET_CAMERA"
    )

    private fun ensureDirectory(path: File): Boolean {
        return path.isDirectory || path.mkdirs()
    }

    private fun writeText(path: File, text: String) {
        path.parentFile?.mkdirs()
        path.writeText(text)
    }

    private data class CameraConfig(
        val cameraId: String,
        val size: Size,
        val timestampSource: Int?,
        val metadata: JSONObject
    )

    private class EyeCameraSession(
        val camera: CameraDevice,
        val session: CameraCaptureSession,
        val imageReader: ImageReader
    ) {
        fun close() {
            session.close()
            camera.close()
            imageReader.close()
        }
    }

    companion object {
        private const val REQUEST_CAMERA_PERMISSIONS = 4001
        private const val REQUEST_STORAGE_PERMISSION = 4002
        private const val IMAGE_READER_MAX_IMAGES = 3
        private const val TAG = "QuestCapturePlugin"
        private const val DEFAULT_RGB_BITRATE = 24_000_000
        private const val DEFAULT_RGB_FPS = 30
        private const val DEFAULT_DEPTH_DURATION_US = 200_000L
        private const val DEFAULT_POSE_DURATION_US = 11_111L
        private const val DEFAULT_HAND_DURATION_US = 33_333L
        private const val DEFAULT_INPUT_DURATION_US = 1_000L
        private const val STOP_TIMEOUT_SECONDS = 5L
        private const val META_CAMERA_SOURCE_PASSTHROUGH = 0
        private const val META_CAMERA_POSITION_LEFT = 0
        private const val META_CAMERA_POSITION_RIGHT = 1
        private const val TRACK_HEAD_POSE = 0
        private const val TRACK_LEFT_CONTROLLER_POSE = 1
        private const val TRACK_RIGHT_CONTROLLER_POSE = 2
        private const val TRACK_LEFT_HAND_JOINTS = 3
        private const val TRACK_RIGHT_HAND_JOINTS = 4
        private const val TRACK_LEFT_CONTROLLER_INPUT = 5
        private const val TRACK_RIGHT_CONTROLLER_INPUT = 6
        private const val CONTROLLER_INPUT_PAYLOAD_BYTES = 68
        private const val CONTROLLER_INPUT_MAGIC = 0x504E4943
    }
}

private fun JSONObject.putArray(name: String, values: FloatArray?): JSONObject {
    val array = JSONArray()
    values?.forEach { array.put(it.toDouble()) }
    return put(name, array)
}

private fun JSONObject.putSize(name: String, size: Size?): JSONObject {
    if (size == null) {
        return put(name, JSONObject.NULL)
    }
    return put(name, JSONObject().put("width", size.width).put("height", size.height))
}

private fun JSONObject.putRect(name: String, rect: Rect?): JSONObject {
    if (rect == null) {
        return put(name, JSONObject.NULL)
    }
    return put(
        name,
        JSONObject()
            .put("left", rect.left)
            .put("top", rect.top)
            .put("right", rect.right)
            .put("bottom", rect.bottom)
            .put("width", rect.width())
            .put("height", rect.height())
    )
}
