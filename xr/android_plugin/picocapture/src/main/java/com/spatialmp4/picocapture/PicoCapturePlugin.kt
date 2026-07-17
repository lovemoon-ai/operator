package com.spatialmp4.picocapture

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
import androidx.core.content.FileProvider
import com.spatialmp4.capturecommon.CapturedRgbaFrame
import com.spatialmp4.capturecommon.CapturedYuvFrame
import com.spatialmp4.capturecommon.ChromaLayout
import com.spatialmp4.capturecommon.DeviceIdentity
import com.spatialmp4.capturecommon.GpuSurfaceStereoEncoder
import com.spatialmp4.capturecommon.StereoHevcEncoder
import com.spatialmp4.capturecommon.YuvPlaneCapture
import com.spatialmp4.contract.SessionConfig
import com.spatialmp4.contract.SpatialDataSink
import com.spatialmp4.contract.SpatialDataSinkRegistry
import com.spatialmp4.contract.RgbVideoCodec
import com.spatialmp4.muxer.SpatialMp4MuxerPlugin
import com.spatialmp4.muxer.SpatialMp4SideDataPacker
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

class PicoCapturePlugin(godot: Godot) : GodotPlugin(godot) {
    private val mainActivity: Activity?
        get() = getActivity()

    private var sessionDir: File? = null
    private var backgroundThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null
    private var cameraManager: CameraManager? = null

    private val sessions = ConcurrentHashMap<String, EyeCameraSession>()
    private val frameIndexCounters = ConcurrentHashMap<String, AtomicLong>()
    private var finalMp4Path: File? = null
    private var partialMp4Path: File? = null
    private var hevcEncoder: StereoHevcEncoder? = null
    private var gpuSurfaceEncoder: GpuSurfaceStereoEncoder? = null
    private var leftMetadata = "{}"
    private var rightMetadata = "{}"
    @Volatile private var openXrExternalCameraInfoJson = "{}"
    @Volatile private var openXrCameraImageInfoJson = "{}"
    private val openXrCameraConfigs = ConcurrentHashMap<String, CameraConfig>()

    private var sessionStartUnixUs = 0L
    private var sessionStartGodotTicksUs = 0L
    private var configureGodotTicksUs = 0L
    private var configureElapsedRealtimeNs = 0L
    private var configureClockMonotonicNs = 0L
    private var configureUnixTimeMs = 0L
    private var recordHeadPose = true
    private var recordControllerPose = true
    private var recordHandData = true
    private var recordControllerInput = true
    private var recordBodyTracking = false
    private var recordMotionTrackers = false
    private var maxMotionTrackerCount = 2
    private var stereoRgb = true
    private var rgbBitrate = DEFAULT_RGB_BITRATE
    private var rgbFps = DEFAULT_RGB_FPS
    private var rgbCodec = RgbVideoCodec.HEVC.tag
    @Volatile private var exportCoordinateSpace = "openxr_stage"

    @Volatile private var acceptingFrames = false
    @Volatile private var muxerSink: SpatialDataSink? = null

    private val metricCameraFramesLeft = AtomicLong(0L)
    private val metricCameraFramesRight = AtomicLong(0L)
    private val metricEncoderPairsOffered = AtomicLong(0L)
    private val metricEncoderMonoOffered = AtomicLong(0L)
    private val metricEncoderPacketsOut = AtomicLong(0L)
    // Per-reason reject counters for submitOpenXrRgbaFrame so silent frame
    // drops on the XR_PICO_camera_image path show up in popMetricsJson().
    private val metricOxrRejectNotAccepting = AtomicLong(0L)
    private val metricOxrRejectNoConfig = AtomicLong(0L)
    private val metricOxrRejectBadSize = AtomicLong(0L)
    private val metricOxrRejectBadBuffer = AtomicLong(0L)
    private val metricOxrRejectNoEncoder = AtomicLong(0L)
    private val metricOxrRejectBackpressure = AtomicLong(0L)
    private val pendingOpenXrRgbaTasks = AtomicInteger(0)

    override fun getPluginName(): String = "PicoCapturePlugin"

    @UsedByGodot
    fun getCaptureProviderName(): String = "pico"

    @UsedByGodot
    fun getCaptureProviderDeviceScore(): Int {
        val device = listOf(Build.MANUFACTURER, Build.BRAND, Build.MODEL, Build.DEVICE, Build.PRODUCT)
            .joinToString(" ")
            .lowercase()
        return when {
            "pico" in device || "picovr" in device -> 100
            "quest" in device || "oculus" in device || "meta" in device -> -100
            else -> 10
        }
    }

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

    override fun getPluginSignals(): Set<SignalInfo> {
        return setOf(
            SignalInfo("camera_ready", String::class.java, String::class.java),
            SignalInfo("camera_frame_saved", String::class.java, String::class.java, java.lang.Long::class.java),
            SignalInfo("camera_error", String::class.java)
        )
    }

    @UsedByGodot
    fun configureSpatialMp4SessionWithTime(
        finalPath: String,
        partialPath: String,
        sessionPath: String,
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
        if (recordDepth) {
            Log.i(TAG, "Pico 4 Ultra depth capture requested; ignoring because the platform has no depth camera stream")
        }
        return configureSessionInternal(
            sessionPath,
            sessionStartUnixUs,
            sessionStartGodotTicksUs,
            configureGodotTicksUs,
            finalPath,
            partialPath,
            recordHeadPose,
            recordControllerPose,
            recordHandData,
            recordControllerInput,
            stereoRgb,
            rgbBitrate,
            rgbFps
        )
    }

    @UsedByGodot
    fun setBodyMotionCaptureOptions(
        recordBodyTracking: Boolean,
        recordMotionTrackers: Boolean,
        maxMotionTrackerCount: Int
    ): Boolean {
        this.recordBodyTracking = recordBodyTracking
        this.recordMotionTrackers = recordMotionTrackers
        this.maxMotionTrackerCount = maxMotionTrackerCount.coerceIn(0, MAX_MOTION_TRACKERS)
        return true
    }

    @UsedByGodot
    fun setExportCoordinateSpace(space: String): Boolean {
        val normalized = space.trim().lowercase().replace('-', '_')
        return when (normalized) {
            "openxr_stage", "openxr_local", "openxr_local_floor" -> {
                exportCoordinateSpace = normalized
                true
            }
            else -> false
        }
    }

    @UsedByGodot
    fun setRgbVideoCodec(codec: String): Boolean {
        rgbCodec = RgbVideoCodec.normalize(codec)
        return true
    }

    @UsedByGodot
    fun setOpenXrExternalCameraInfoJson(rawJson: String): Boolean {
        return try {
            if (rawJson.isBlank()) {
                openXrExternalCameraInfoJson = "{}"
            } else {
                openXrExternalCameraInfoJson = JSONObject(rawJson).toString()
            }
            true
        } catch (error: Exception) {
            Log.w(TAG, "Ignoring invalid OpenXR external camera info JSON: ${error.message}")
            openXrExternalCameraInfoJson = "{}"
            false
        }
    }

    @UsedByGodot
    fun setOpenXrCameraImageInfoJson(rawJson: String): Boolean {
        return try {
            openXrCameraImageInfoJson = if (rawJson.isBlank()) "{}" else JSONObject(rawJson).toString()
            true
        } catch (error: Exception) {
            Log.w(TAG, "Ignoring invalid OpenXR camera image JSON: ${error.message}")
            openXrCameraImageInfoJson = "{}"
            false
        }
    }

    @UsedByGodot
    fun isDepthCaptureSupported(): Boolean = false

    @UsedByGodot
    fun isBodyMotionCaptureSupported(): Boolean = true

    private fun configureSessionInternal(
        path: String,
        sessionStartUnixUs: Long,
        sessionStartGodotTicksUs: Long,
        configureGodotTicksUs: Long,
        finalPath: String,
        partialPath: String,
        recordHeadPose: Boolean,
        recordControllerPose: Boolean,
        recordHandData: Boolean,
        recordControllerInput: Boolean,
        stereoRgb: Boolean,
        rgbBitrate: Int,
        rgbFps: Int
    ): Boolean {
        val dir = File(path)
        try {
            if (!ensureDirectory(dir)) {
                emitSignal("camera_error", "Failed to create session directory: $path")
                return false
            }
            File(finalPath).parentFile?.let(::ensureDirectory)
            File(partialPath).let {
                it.parentFile?.let(::ensureDirectory)
                it.delete()
            }
        } catch (error: Exception) {
            emitSignal("camera_error", "Failed to prepare session directory: $path (${error.message})")
            return false
        }

        sessionDir = dir
        finalMp4Path = File(finalPath)
        partialMp4Path = File(partialPath)
        this.sessionStartUnixUs = sessionStartUnixUs
        this.sessionStartGodotTicksUs = sessionStartGodotTicksUs
        this.configureGodotTicksUs = configureGodotTicksUs
        this.recordHeadPose = recordHeadPose
        this.recordControllerPose = recordControllerPose
        this.recordHandData = recordHandData
        this.recordControllerInput = recordControllerInput
        this.stereoRgb = stereoRgb
        this.rgbBitrate = if (rgbBitrate > 0) rgbBitrate else DEFAULT_RGB_BITRATE
        this.rgbFps = if (rgbFps > 0) rgbFps else DEFAULT_RGB_FPS
        leftMetadata = "{}"
        rightMetadata = "{}"
        configureClockMonotonicNs = System.nanoTime()
        configureElapsedRealtimeNs = SystemClock.elapsedRealtimeNanos()
        configureUnixTimeMs = System.currentTimeMillis()
        return true
    }

    @UsedByGodot
    fun requestStoragePermission() {
        val activity = mainActivity ?: return
        if (hasStoragePermission()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val packageUri = Uri.parse("package:${activity.packageName}")
            try {
                activity.startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, packageUri))
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
        val requested = if (path.isBlank()) Environment.getExternalStorageDirectory().absolutePath else path
        return try {
            var probe = File(requested)
            while (!probe.exists() && probe.parentFile != null) {
                probe = probe.parentFile!!
            }
            val statPath = if (probe.exists()) probe.absolutePath else Environment.getExternalStorageDirectory().absolutePath
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

    @UsedByGodot
    fun openVideoInSystemPlayer(path: String): Boolean {
        val activity = mainActivity ?: return false
        if (path.isBlank()) {
            emitSignal("camera_error", "Video preview path is empty")
            return false
        }
        val file = File(path)
        if (!file.isFile) {
            emitSignal("camera_error", "Video preview file does not exist: $path")
            return false
        }
        return try {
            val authority = "${activity.packageName}.fileprovider"
            val uri = FileProvider.getUriForFile(activity, authority, file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "video/mp4")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(intent)
            true
        } catch (error: Exception) {
            Log.e(TAG, "Failed to open video preview: $path", error)
            emitSignal("camera_error", "Failed to open video preview: ${error.message}")
            false
        }
    }

    @UsedByGodot
    fun requestCameraPermission() {
        val activity = mainActivity ?: return
        val missing = requiredRuntimePermissions().filter {
            ContextCompat.checkSelfPermission(activity, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) {
            ActivityCompat.requestPermissions(activity, missing.toTypedArray(), REQUEST_CAMERA_PERMISSIONS)
        }
    }

    @UsedByGodot
    fun hasCameraPermission(): Boolean {
        val activity = mainActivity ?: return false
        return requiredRuntimePermissions().all {
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
        if (!hasCameraPermission()) {
            requestCameraPermission()
            emitSignal("camera_error", "Camera permission is not granted yet")
            return false
        }

        ensureBackgroundThread()
        cameraManager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val cameras = findPicoSeeThroughCameras(cameraManager!!)
        Log.i(TAG, "Pico see-through cameras found=${cameras.keys.sorted()}")
        if (!cameras.containsKey("left") || (stereoRgb && !cameras.containsKey("right"))) {
            val requiredEyes = if (stereoRgb) "left/right" else "left"
            emitSignal("camera_error", "Pico see-through $requiredEyes cameras were not found")
            return false
        }

        val baseLeftConfig = cameras["left"] ?: return false
        val leftConfig = baseLeftConfig.withMetadata(attachOpenXrExternalCameraInfo(baseLeftConfig.metadata))
        val rightConfig = if (stereoRgb) {
            cameras["right"]?.let { it.withMetadata(attachOpenXrExternalCameraInfo(it.metadata)) }
        } else {
            null
        }
        val leftRecordingMetadata = recordingCameraMetadata(leftConfig)
        val rightRecordingMetadata = rightConfig?.let { recordingCameraMetadata(it) }
        leftMetadata = leftRecordingMetadata.toString()
        rightMetadata = rightRecordingMetadata?.toString() ?: "{}"
        val androidTimebase = buildAndroidTimebase(leftConfig.timestampSource, rightConfig?.timestampSource)

        if (!startNativeWriter(root, leftConfig, rightConfig, androidTimebase, useGpuSurfaceEncoder = false)) {
            return false
        }

        openFrameIndexWriter(root, "left")
        if (rightConfig != null) {
            openFrameIndexWriter(root, "right")
        }

        acceptingFrames = true
        openEyeCamera("left", leftConfig)
        if (rightConfig != null) {
            openEyeCamera("right", rightConfig)
        }
        return true
    }

    @UsedByGodot
    fun startOpenXrCameraImageCapture(rawJson: String): Boolean {
        val root = sessionDir ?: run {
            emitSignal("camera_error", "configureSession must be called before startOpenXrCameraImageCapture")
            return false
        }
        if (!hasCameraPermission()) {
            requestCameraPermission()
            emitSignal("camera_error", "Camera permission is not granted yet")
            return false
        }

        val info = try {
            JSONObject(if (rawJson.isBlank()) openXrCameraImageInfoJson else rawJson)
        } catch (error: Exception) {
            emitSignal("camera_error", "Invalid OpenXR camera image info JSON: ${error.message}")
            return false
        }
        openXrCameraImageInfoJson = info.toString()

        val leftConfig = openXrCameraConfig(info, "left") ?: run {
            emitSignal("camera_error", "OpenXR camera image left metadata is missing")
            return false
        }
        val rightConfig = if (stereoRgb) {
            openXrCameraConfig(info, "right") ?: run {
                emitSignal("camera_error", "OpenXR camera image right metadata is missing for stereo capture")
                return false
            }
        } else {
            null
        }

        val leftRecordingMetadata = recordingCameraMetadata(leftConfig)
        val rightRecordingMetadata = rightConfig?.let { recordingCameraMetadata(it) }
        leftMetadata = leftRecordingMetadata.toString()
        rightMetadata = rightRecordingMetadata?.toString() ?: "{}"
        val androidTimebase = buildAndroidTimebase(leftTimestampSource = null, rightTimestampSource = null)

        ensureBackgroundThread()
        if (!startNativeWriter(root, leftConfig, rightConfig, androidTimebase, useGpuSurfaceEncoder = true)) {
            return false
        }

        closeFrameIndexWriters()
        openFrameIndexWriter(root, "left")
        if (rightConfig != null) {
            openFrameIndexWriter(root, "right")
        }
        openXrCameraConfigs.clear()
        openXrCameraConfigs["left"] = leftConfig
        if (rightConfig != null) {
            openXrCameraConfigs["right"] = rightConfig
        }
        pendingOpenXrRgbaTasks.set(0)
        acceptingFrames = true
        emitSignal("camera_ready", "left", leftConfig.cameraId)
        if (rightConfig != null) {
            emitSignal("camera_ready", "right", rightConfig.cameraId)
        }
        Log.i(TAG, "OpenXR camera image capture ready stereo=${rightConfig != null} ${leftConfig.size.width}x${leftConfig.size.height}")
        return true
    }

    @UsedByGodot
    fun submitOpenXrRgbaFrame(
        eye: String,
        xrTimeNs: Long,
        width: Int,
        height: Int,
        stride: Int,
        bytesPerPixel: Int,
        rgba: ByteArray
    ): Boolean {
        if (!acceptingFrames) {
            metricOxrRejectNotAccepting.incrementAndGet()
            return false
        }
        val normalizedEye = if (eye == "right") "right" else "left"
        val config = openXrCameraConfigs[normalizedEye] ?: run {
            metricOxrRejectNoConfig.incrementAndGet()
            return false
        }
        if (width != config.size.width || height != config.size.height) {
            metricOxrRejectBadSize.incrementAndGet()
            emitSignal("camera_error", "Dropping OpenXR $normalizedEye frame with unexpected size ${width}x$height")
            return false
        }
        val timestampNs = openXrTimeToGodotTicksNs(xrTimeNs)
        val pixelStride = bytesPerPixel.coerceAtLeast(4)
        val rowStride = if (stride > 0) stride else width * pixelStride
        if (!hasEnoughOpenXrRgbaBytes(width, height, rowStride, pixelStride, rgba)) {
            metricOxrRejectBadBuffer.incrementAndGet()
            emitSignal("camera_error", "Dropping OpenXR $normalizedEye frame with invalid RGBA buffer")
            return false
        }
        val encoder = gpuSurfaceEncoder ?: run {
            metricOxrRejectNoEncoder.incrementAndGet()
            emitSignal("camera_error", "Dropping OpenXR $normalizedEye frame because GPU Surface encoder is not running")
            return false
        }
        val handler = backgroundHandler ?: run {
            metricOxrRejectNoEncoder.incrementAndGet()
            emitSignal("camera_error", "Dropping OpenXR $normalizedEye frame because Pico background thread is not running")
            return false
        }
        val frame = CapturedRgbaFrame(
            eye = normalizedEye,
            timestampNs = timestampNs,
            width = width,
            height = height,
            rowStride = rowStride,
            pixelStride = pixelStride,
            bytes = rgba
        )
        if (normalizedEye == "left") metricCameraFramesLeft.incrementAndGet()
        else metricCameraFramesRight.incrementAndGet()
        val pending = pendingOpenXrRgbaTasks.incrementAndGet()
        if (pending > MAX_PENDING_OPENXR_RGBA_TASKS) {
            decrementPendingOpenXrRgbaTasks()
            metricOxrRejectBackpressure.incrementAndGet()
            return false
        }
        if (!handler.post {
                try {
                    if (!acceptingFrames) {
                        return@post
                    }
                    val offered = encoder.offer(frame)
                    if (!offered) {
                        metricOxrRejectNoEncoder.incrementAndGet()
                        return@post
                    }
                    writeFrameIndex(normalizedEye, config, timestampNs, xrTimeNs, width, height)
                    emitSignal("camera_frame_saved", normalizedEye, finalMp4Path?.absolutePath ?: "", timestampNs)
                } finally {
                    decrementPendingOpenXrRgbaTasks()
                }
            }
        ) {
            decrementPendingOpenXrRgbaTasks()
            metricOxrRejectNoEncoder.incrementAndGet()
            return false
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
                emitSignal("camera_error", "Timed out while stopping Pico camera capture")
            }
        } else {
            closeCamerasAndEncoder()
        }
        backgroundThread?.quitSafely()
        backgroundThread = null
        backgroundHandler = null
    }

    @UsedByGodot
    fun bindMuxer(muxer: Any?): Boolean {
        if (muxer == null) {
            muxerSink = null
            return true
        }
        val sink = muxer as? SpatialDataSink
        if (sink == null) {
            Log.w(TAG, "bindMuxer received an object that does not implement SpatialDataSink")
            return false
        }
        if (sink.contractVersion != com.spatialmp4.contract.CONTRACT_VERSION) {
            Log.w(
                TAG,
                "muxer contract v${sink.contractVersion} differs from provider v${com.spatialmp4.contract.CONTRACT_VERSION}; binding anyway"
            )
        }
        muxerSink = sink
        return true
    }

    @UsedByGodot
    fun getXrTimeToGodotTicksOffsetNs(): Long {
        if (configureGodotTicksUs <= 0L || configureClockMonotonicNs <= 0L) {
            return 0L
        }
        return configureGodotTicksUs * 1000L - configureClockMonotonicNs
    }

    @UsedByGodot
    fun getLeftCameraMetadataJson(): String = leftMetadata

    @UsedByGodot
    fun getRightCameraMetadataJson(): String = rightMetadata

    @UsedByGodot
    fun startBodyTracking(mode: Int): Boolean {
        Log.i(TAG, "startBodyTracking mode=$mode; Godot XRBodyTracker sampler owns OpenXR body reads")
        return true
    }

    @UsedByGodot
    fun stopBodyTracking() {
        Log.i(TAG, "stopBodyTracking")
    }

    @UsedByGodot
    fun pollBodyJointsJson(): String = "{}"

    @UsedByGodot
    fun pollMotionTrackersJson(): String = "{}"

    @UsedByGodot
    fun popMetricsJson(): String {
        return JSONObject()
            .put("cam_frames_left", metricCameraFramesLeft.getAndSet(0L))
            .put("cam_frames_right", metricCameraFramesRight.getAndSet(0L))
            .put("enc_pairs_in", metricEncoderPairsOffered.getAndSet(0L))
            .put("enc_mono_in", metricEncoderMonoOffered.getAndSet(0L))
            .put("enc_packets_out", metricEncoderPacketsOut.getAndSet(0L))
            .put("oxr_rej_not_accepting", metricOxrRejectNotAccepting.getAndSet(0L))
            .put("oxr_rej_no_config", metricOxrRejectNoConfig.getAndSet(0L))
            .put("oxr_rej_bad_size", metricOxrRejectBadSize.getAndSet(0L))
            .put("oxr_rej_bad_buffer", metricOxrRejectBadBuffer.getAndSet(0L))
            .put("oxr_rej_no_encoder", metricOxrRejectNoEncoder.getAndSet(0L))
            .put("oxr_rej_backpressure", metricOxrRejectBackpressure.getAndSet(0L))
            .put("oxr_pending_encode_tasks", pendingOpenXrRgbaTasks.get())
            .toString()
    }

    private fun decrementPendingOpenXrRgbaTasks() {
        while (true) {
            val current = pendingOpenXrRgbaTasks.get()
            if (current <= 0) return
            if (pendingOpenXrRgbaTasks.compareAndSet(current, current - 1)) return
        }
    }

    private fun ensureBackgroundThread() {
        if (backgroundThread != null && backgroundHandler != null) return
        val thread = HandlerThread("PicoCaptureCamera")
        thread.start()
        backgroundThread = thread
        backgroundHandler = Handler(thread.looper)
    }

    private fun findPicoSeeThroughCameras(manager: CameraManager): Map<String, CameraConfig> {
        val result = mutableMapOf<String, CameraConfig>()
        val fallback = mutableListOf<CameraConfig>()
        for (cameraId in manager.cameraIdList) {
            val characteristics = manager.getCameraCharacteristics(cameraId)
            val metadata = cameraMetadataJson(cameraId, characteristics)
            val config = CameraConfig(
                cameraId = cameraId,
                size = chooseYuvSize(characteristics),
                timestampSource = characteristics.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE),
                metadata = metadata
            )
            fallback += config
            val eye = inferEye(cameraId, metadata)
            Log.i(TAG, "cameraId=$cameraId pico_eye=$eye metadata=${metadata.optJSONObject("pico_vendor")}")
            if (eye == "left" || eye == "right") {
                result[eye] = config.withEye(eye)
            }
        }
        if (result.isNotEmpty()) {
            return result
        }

        val usable = fallback.sortedWith(compareBy<CameraConfig> {
            it.metadata.optInt("lens_facing", Int.MAX_VALUE)
        }.thenBy { it.cameraId })
        if (usable.isNotEmpty()) {
            result["left"] = usable[0].withEye("left")
        }
        if (usable.size >= 2) {
            result["right"] = usable[1].withEye("right")
        }
        if (result.isNotEmpty()) {
            Log.w(TAG, "Pico camera vendor keys were not recognized; falling back to cameraId order ${usable.map { it.cameraId }}")
        }
        return result
    }

    private fun inferEye(cameraId: String, metadata: JSONObject): String? {
        val loweredId = cameraId.lowercase()
        if ("left" in loweredId) return "left"
        if ("right" in loweredId) return "right"

        val vendor = metadata.optJSONObject("pico_vendor") ?: JSONObject()
        for (key in vendor.keys()) {
            val value = vendor.opt(key)
            val text = "$key=$value".lowercase()
            if ("left" in text || text.contains("eye_l") || text.contains("position_l")) return "left"
            if ("right" in text || text.contains("eye_r") || text.contains("position_r")) return "right"
        }
        for (keyName in PICO_POSITION_VENDOR_KEYS) {
            val value = vendor.opt(keyName)
            val intValue = when (value) {
                is Number -> value.toInt()
                is String -> value.toIntOrNull()
                else -> null
            }
            when (intValue) {
                0 -> return "left"
                1 -> return "right"
            }
        }
        return null
    }

    private fun startNativeWriter(
        root: File,
        leftConfig: CameraConfig,
        rightConfig: CameraConfig?,
        androidTimebase: JSONObject?,
        useGpuSurfaceEncoder: Boolean
    ): Boolean {
        val sink = activeDataSink()
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

        val rgbSideData = SpatialMp4SideDataPacker.packRgb(
            leftConfig.metadata,
            leftConfig.size.width,
            leftConfig.size.height,
            rightConfig?.metadata,
            rightConfig?.size?.width ?: 0,
            rightConfig?.size?.height ?: 0
        )
        val rgbWidth = leftConfig.size.width + (rightConfig?.size?.width ?: 0)
        val rgbCameraCount = if (rightConfig == null) 1 else 2
        val deviceIdentity = DeviceIdentity.detect()
        Log.i(
            TAG,
            "device identity: type=${deviceIdentity.type} model=${deviceIdentity.model} manufacturer=${deviceIdentity.manufacturer}"
        )
        val sessionConfig = SessionConfig(
            partialPath = partialPath.absolutePath,
            finalPath = finalPath.absolutePath,
            sessionStartUnixUs = sessionStartUnixUs,
            sessionStartGodotTicksUs = sessionStartGodotTicksUs,
            rgbWidth = rgbWidth,
            rgbHeight = leftConfig.size.height,
            rgbFps = rgbFps,
            rgbCameraCount = rgbCameraCount,
            depthExpected = false,
            headPoseExpected = recordHeadPose,
            controllerPoseExpected = recordControllerPose,
            handJointsExpected = recordHandData,
            controllerInputExpected = recordControllerInput,
            rgbIcam = rgbSideData.icam,
            rgbEcam = rgbSideData.ecam,
            rgbDstr = rgbSideData.dstr,
            deviceType = deviceIdentity.type,
            deviceModel = deviceIdentity.model,
            deviceManufacturer = deviceIdentity.manufacturer,
            // v4: pre-allocate the mp4 body-joints mett track whenever the host
            // asked for body tracking; payloads flow from GDScript at ~30 Hz.
            bodyJointsExpected = recordBodyTracking
        )
        if (!sink.startSession(sessionConfig)) {
            return false
        }
        val operatorStatic = buildOperatorStaticMetadata(leftConfig, rightConfig, androidTimebase)
        sink.onOperatorStaticMetadata(operatorStatic.toString().toByteArray(Charsets.UTF_8))

        val cameraIntrinsics = mutableListOf<com.spatialmp4.contract.Intrinsics>()
        cameraIntrinsics += SpatialMp4SideDataPacker.extractIntrinsics(
            leftConfig.metadata, leftConfig.size.width, leftConfig.size.height
        )
        if (rightConfig != null) {
            cameraIntrinsics += SpatialMp4SideDataPacker.extractIntrinsics(
                rightConfig.metadata, rightConfig.size.width, rightConfig.size.height
            )
        }
        if (useGpuSurfaceEncoder) {
            // XR_PICO_camera_image is encoded by libpico_openxr with NDK
            // MediaCodec + an EGL input Surface.  Do not allocate a Java
            // encoder here: raw RGBA must never cross Godot/JNI as byte[].
            // The GDScript orchestrator starts the native worker immediately
            // after this method returns, once the muxer handle is active.
            gpuSurfaceEncoder = null
            hevcEncoder = null
        } else {
            val encoder = StereoHevcEncoder(
                dataSink = sink,
                eyeWidth = leftConfig.size.width,
                eyeHeight = leftConfig.size.height,
                fps = rgbFps,
                bitrate = rgbBitrate,
                stereo = rightConfig != null,
                cameraIntrinsics = cameraIntrinsics,
                rgbCodec = rgbCodec,
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
            gpuSurfaceEncoder = null
        }
        Log.i(TAG, "Pico SpatialMP4 writer started stereo=${rightConfig != null} nativeOpenXr=$useGpuSurfaceEncoder partial=${partialPath.absolutePath} final=${finalPath.absolutePath}")
        return true
    }

    private fun startGpuSurfaceEncoderOnBackground(encoder: GpuSurfaceStereoEncoder): Boolean {
        val handler = backgroundHandler ?: run {
            emitSignal("camera_error", "Pico background thread is not available for GPU Surface encoder")
            return false
        }
        if (Looper.myLooper() == handler.looper) {
            return encoder.start()
        }
        val started = java.util.concurrent.atomic.AtomicBoolean(false)
        val latch = CountDownLatch(1)
        if (!handler.post {
                try {
                    started.set(encoder.start())
                } finally {
                    latch.countDown()
                }
            }
        ) {
            emitSignal("camera_error", "Failed to schedule GPU Surface encoder start")
            return false
        }
        if (!latch.await(STOP_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
            emitSignal("camera_error", "Timed out while starting GPU Surface encoder")
            return false
        }
        return started.get()
    }

    private fun openEyeCamera(eye: String, config: CameraConfig) {
        val manager = cameraManager ?: return
        val handler = backgroundHandler ?: return
        if (!acceptingFrames) return

        val imageReader = ImageReader.newInstance(
            config.size.width,
            config.size.height,
            ImageFormat.YUV_420_888,
            IMAGE_READER_MAX_IMAGES
        )
        imageReader.setOnImageAvailableListener({ reader -> encodeLatestImage(eye, config, reader) }, handler)

        val stateCallback = object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) {
                if (!acceptingFrames) {
                    imageReader.close()
                    camera.close()
                    return
                }
                val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
                request.addTarget(imageReader.surface)
                request.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, android.util.Range(rgbFps, rgbFps))
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
                            session.setRepeatingRequest(request.build(), null, handler)
                            emitSignal("camera_ready", eye, config.cameraId)
                        }

                        override fun onConfigureFailed(session: CameraCaptureSession) {
                            emitSignal("camera_error", "Failed to configure Pico $eye camera")
                        }
                    },
                    handler
                )
            }

            override fun onDisconnected(camera: CameraDevice) {
                emitSignal("camera_error", "Pico $eye camera disconnected")
                camera.close()
            }

            override fun onError(camera: CameraDevice, error: Int) {
                emitSignal("camera_error", "Pico $eye camera error: $error")
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
            if (!acceptingFrames) return@use
            val cameraSensorTimestampNs = image.timestamp
            val timestampNs = cameraSensorToGodotTicksNs(cameraSensorTimestampNs, config.timestampSource)
            if (eye == "left") metricCameraFramesLeft.incrementAndGet()
            else if (eye == "right") metricCameraFramesRight.incrementAndGet()
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
            writeFrameIndex(eye, config, timestampNs, cameraSensorTimestampNs, image.width, image.height)
            emitSignal("camera_frame_saved", eye, finalMp4Path?.absolutePath ?: "", timestampNs)
        }
    }

    private fun chooseYuvSize(characteristics: CameraCharacteristics): Size {
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) as StreamConfigurationMap?
        val sizes = map?.getOutputSizes(ImageFormat.YUV_420_888)
        return sizes?.maxByOrNull { it.width * it.height }
            ?: characteristics.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE)
            ?: Size(1280, 960)
    }

    private fun cameraMetadataJson(cameraId: String, characteristics: CameraCharacteristics): JSONObject {
        val metadata = JSONObject()
            .put("camera_id", cameraId)
            .putArray("lens_intrinsic_calibration", characteristics.get(CameraCharacteristics.LENS_INTRINSIC_CALIBRATION))
            .putArray("lens_distortion", characteristics.get(CameraCharacteristics.LENS_DISTORTION))
            .putArray("lens_pose_translation", characteristics.get(CameraCharacteristics.LENS_POSE_TRANSLATION))
            .putArray("lens_pose_rotation", characteristics.get(CameraCharacteristics.LENS_POSE_ROTATION))
            .putSize("sensor_pixel_array_size", characteristics.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE))
            .putRect("sensor_active_array_size", characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE))
            .put("sensor_timestamp_source", characteristics.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE))
            .put("lens_facing", characteristics.get(CameraCharacteristics.LENS_FACING))
        val vendor = JSONObject()
        for (key in characteristics.keys) {
            if (!isPicoVendorKey(key.name)) continue
            @Suppress("UNCHECKED_CAST")
            val typedKey = key as CameraCharacteristics.Key<Any>
            try {
                vendor.put(key.name, jsonSafeValue(characteristics.get(typedKey)))
            } catch (_: Exception) {
            }
        }
        metadata.put("pico_vendor", vendor)
        return metadata
    }

    private fun attachOpenXrExternalCameraInfo(metadata: JSONObject): JSONObject {
        val enriched = JSONObject(metadata.toString())
        try {
            val openXrInfo = JSONObject(openXrExternalCameraInfoJson)
            if (openXrInfo.length() > 0) {
                enriched.put("openxr_external_camera", openXrInfo)
            }
        } catch (_: Exception) {
        }
        return enriched
    }

    private fun isPicoVendorKey(name: String): Boolean {
        val lowered = name.lowercase()
        return lowered.contains("pico") ||
            lowered.contains("picovr") ||
            lowered.contains("see") ||
            lowered.contains("through") ||
            lowered.contains("passthrough") ||
            lowered.contains("eye") ||
            lowered.contains("position")
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

    private fun openFrameIndexWriter(@Suppress("UNUSED_PARAMETER") root: File, eye: String) {
        frameIndexCounters[eye] = AtomicLong(0L)
    }

    private fun closeFrameIndexWriters() {
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
        val index = frameIndexCounters[eye]?.getAndIncrement() ?: return
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
        val recordText = record.toString()
        try {
            activeDataSink()?.onRgbFrameIndex(
                eye,
                recordText.toByteArray(Charsets.UTF_8),
                godotTicksNs,
                0L
            )
        } catch (error: Exception) {
            Log.w(TAG, "Failed to embed ${eye} rgb_frame_index metadata: ${error.message}")
        }
    }

    private fun closeCamerasAndEncoder() {
        sessions.values.forEach { it.close() }
        sessions.clear()
        openXrCameraConfigs.clear()
        hevcEncoder?.stopAndDrain()
        hevcEncoder = null
        gpuSurfaceEncoder?.stopAndDrain()
        gpuSurfaceEncoder = null
        closeFrameIndexWriters()
    }

    private fun openXrTimeToGodotTicksNs(xrTimeNs: Long): Long {
        if (configureGodotTicksUs <= 0L || configureClockMonotonicNs <= 0L) return xrTimeNs
        return configureGodotTicksUs * 1000L + (xrTimeNs - configureClockMonotonicNs)
    }

    private fun cameraSensorToGodotTicksNs(sensorTimestampNs: Long, sensorSource: Int?): Long {
        if (configureGodotTicksUs <= 0L) return sensorTimestampNs
        val configureGodotTicksNs = configureGodotTicksUs * 1000L
        return when (sensorSource) {
            CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME -> {
                if (configureElapsedRealtimeNs <= 0L) sensorTimestampNs
                else configureGodotTicksNs + (sensorTimestampNs - configureElapsedRealtimeNs)
            }
            else -> {
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

    private fun buildAndroidTimebase(leftTimestampSource: Int?, rightTimestampSource: Int?): JSONObject {
        val configureGodotTicksNs = configureGodotTicksUs * 1000L
        val monoToGodotOffsetNs = if (configureClockMonotonicNs > 0L) configureGodotTicksNs - configureClockMonotonicNs else 0L
        val boottimeToGodotOffsetNs = if (configureElapsedRealtimeNs > 0L) configureGodotTicksNs - configureElapsedRealtimeNs else 0L
        val rgbSources = JSONObject()
        if (leftTimestampSource != null) {
            rgbSources.put("left", timestampSourceName(leftTimestampSource))
            rgbSources.put("left_code", leftTimestampSource)
        }
        if (rightTimestampSource != null) {
            rgbSources.put("right", timestampSourceName(rightTimestampSource))
            rgbSources.put("right_code", rightTimestampSource)
        }
        return JSONObject()
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
    }

    private fun buildOperatorStaticMetadata(
        leftConfig: CameraConfig,
        rightConfig: CameraConfig?,
        androidTimebase: JSONObject?
    ): JSONObject {
        val cameras = JSONObject()
            .put("left", recordingCameraMetadata(leftConfig))
        if (rightConfig != null) {
            cameras.put("right", recordingCameraMetadata(rightConfig))
        }
        return JSONObject()
            .put("schema", "spatialmp4.operator_static.session.v1")
            .put("provider", "pico")
            .put("export_coordinate_space", exportCoordinateSpace)
            .put("head_pose_space", exportCoordinateSpace)
            .put("controller_pose_space", exportCoordinateSpace)
            .put("hand_joint_space", exportCoordinateSpace)
            .put("rgb_extrinsics_space", "head")
            .put("rgb_camera_pose_composition", "T_export_camera=T_export_head*T_head_camera")
            .put("camera2_characteristics", cameras)
            .put("android_timebase", androidTimebase ?: JSONObject())
    }

    private fun recordingCameraMetadata(config: CameraConfig): JSONObject {
        val intrinsics = SpatialMp4SideDataPacker.extractIntrinsics(
            config.metadata,
            config.size.width,
            config.size.height
        )
        return JSONObject(config.metadata.toString())
            .put("recording_width", config.size.width)
            .put("recording_height", config.size.height)
            .put("recording_lens_intrinsic_calibration", JSONArray()
                .put(intrinsics.fx)
                .put(intrinsics.fy)
                .put(intrinsics.cx)
                .put(intrinsics.cy))
            .put("recording_intrinsics", intrinsics.toJsonObject())
    }

    private fun com.spatialmp4.contract.Intrinsics.toJsonObject(): JSONObject =
        JSONObject()
            .put("fx", fx)
            .put("fy", fy)
            .put("cx", cx)
            .put("cy", cy)
            .put("width", width)
            .put("height", height)
            .put("extrinsics3x4", doubleArrayJson(extrinsics3x4))
            .put("distortion", doubleArrayJson(distortion))

    private fun doubleArrayJson(values: List<Double>): JSONArray {
        val array = JSONArray()
        values.forEach { array.put(it) }
        return array
    }

    private fun activeDataSink(): SpatialDataSink? =
        muxerSink ?: SpatialDataSinkRegistry.getActiveSink() ?: SpatialMp4MuxerPlugin.activeSink

    private fun openXrCameraConfig(info: JSONObject, eye: String): CameraConfig? {
        val metadata = info.optJSONObject(eye) ?: return null
        val width = metadata.optInt("width", info.optInt("width", 0))
        val height = metadata.optInt("height", info.optInt("height", 0))
        if (width <= 0 || height <= 0) return null
        val enriched = JSONObject(metadata.toString())
            .put("eye", eye)
            .put("camera_id", metadata.opt("camera_id") ?: "openxr_$eye")
            .put("sensor_timestamp_source", "openxr_xr_time")
        if (!enriched.has("lens_intrinsic_calibration")) {
            enriched.put(
                "lens_intrinsic_calibration",
                JSONArray()
                    .put(width.toDouble() * 0.5)
                    .put(height.toDouble() * 0.5)
                    .put(width.toDouble() * 0.5)
                    .put(height.toDouble() * 0.5)
            )
        }
        if (!enriched.has("lens_distortion")) {
            enriched.put("lens_distortion", JSONArray())
        }
        if (!enriched.has("lens_pose_translation")) {
            enriched.put("lens_pose_translation", JSONArray().put(0.0).put(0.0).put(0.0))
        }
        if (!enriched.has("lens_pose_rotation")) {
            enriched.put("lens_pose_rotation", JSONArray().put(0.0).put(0.0).put(0.0).put(1.0))
        }
        return CameraConfig(
            cameraId = "openxr:${metadata.optString("camera_id", eye)}",
            size = Size(width, height),
            timestampSource = null,
            metadata = enriched
        )
    }

    private fun hasEnoughOpenXrRgbaBytes(
        width: Int,
        height: Int,
        rowStride: Int,
        pixelStride: Int,
        rgba: ByteArray
    ): Boolean {
        if (width <= 0 || height <= 0 || rowStride <= 0 || pixelStride <= 0) return false
        val minRowBytes = (width - 1L) * pixelStride.coerceAtLeast(4) + 4L
        if (rowStride < minRowBytes) return false
        val required = rowStride.toLong() * (height - 1L) + minRowBytes
        return required <= rgba.size
    }

    private fun directorySize(target: File): Long {
        if (!target.exists()) return 0L
        if (target.isFile) return target.length()
        var sum = 0L
        val children = target.listFiles() ?: return 0L
        for (child in children) sum += directorySize(child)
        return sum
    }

    private fun requiredRuntimePermissions(): List<String> = listOf(Manifest.permission.CAMERA)

    private fun ensureDirectory(path: File): Boolean = path.isDirectory || path.mkdirs()

    private fun requireContext(): Context {
        return mainActivity ?: throw IllegalStateException("Godot activity is not available")
    }

    private data class CameraConfig(
        val cameraId: String,
        val size: Size,
        val timestampSource: Int?,
        val metadata: JSONObject
    ) {
        fun withEye(eye: String): CameraConfig {
            metadata.put("eye", eye)
            return this
        }

        fun withMetadata(metadata: JSONObject): CameraConfig {
            return copy(metadata = metadata)
        }
    }

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
        private const val REQUEST_CAMERA_PERMISSIONS = 5001
        private const val REQUEST_STORAGE_PERMISSION = 5002
        private const val IMAGE_READER_MAX_IMAGES = 3
        private const val TAG = "PicoCapturePlugin"
        private const val DEFAULT_RGB_BITRATE = 24_000_000
        private const val DEFAULT_RGB_FPS = 30
        private const val STOP_TIMEOUT_SECONDS = 5L
        private const val MAX_PENDING_OPENXR_RGBA_TASKS = 4
        private const val MAX_MOTION_TRACKERS = 3
        private val PICO_POSITION_VENDOR_KEYS = listOf(
            "com.picovr.camera.position",
            "com.pico.camera.position",
            "com.picoxr.camera.position",
            "com.picovr.extra_metadata.position",
            "com.pico.extra_metadata.position",
            "com.picovr.camera.eye",
            "com.pico.camera.eye"
        )
    }
}

private fun JSONObject.putArray(name: String, values: FloatArray?): JSONObject {
    val array = JSONArray()
    values?.forEach { array.put(it.toDouble()) }
    return put(name, array)
}

private fun JSONObject.putSize(name: String, size: Size?): JSONObject {
    if (size == null) return put(name, JSONObject.NULL)
    return put(name, JSONObject().put("width", size.width).put("height", size.height))
}

private fun JSONObject.putRect(name: String, rect: Rect?): JSONObject {
    if (rect == null) return put(name, JSONObject.NULL)
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

private fun jsonSafeValue(value: Any?): Any {
    return when (value) {
        null -> JSONObject.NULL
        is Boolean, is Number, is String -> value
        is FloatArray -> JSONArray().also { arr -> value.forEach { arr.put(it.toDouble()) } }
        is DoubleArray -> JSONArray().also { arr -> value.forEach { arr.put(it) } }
        is IntArray -> JSONArray().also { arr -> value.forEach { arr.put(it) } }
        is LongArray -> JSONArray().also { arr -> value.forEach { arr.put(it) } }
        is BooleanArray -> JSONArray().also { arr -> value.forEach { arr.put(it) } }
        is Array<*> -> JSONArray().also { arr -> value.forEach { arr.put(jsonSafeValue(it)) } }
        is Size -> JSONObject().put("width", value.width).put("height", value.height)
        is Rect -> JSONObject()
            .put("left", value.left)
            .put("top", value.top)
            .put("right", value.right)
            .put("bottom", value.bottom)
        else -> value.toString()
    }
}
