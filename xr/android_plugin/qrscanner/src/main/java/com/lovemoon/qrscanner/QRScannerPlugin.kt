package com.lovemoon.qrscanner

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.content.pm.PermissionInfo
import android.graphics.Bitmap
import android.os.Build
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Size
import android.view.Surface
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.LuminanceSource
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.Result
import com.google.zxing.ResultPoint
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.multi.qrcode.QRCodeMultiReader
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

internal data class QrBounds(
    val cx: Double,
    val cy: Double,
    val w: Double,
    val h: Double,
)

internal fun computeQrBoundsObject(
    result: Result,
    width: Int,
    height: Int,
    mirroredHorizontally: Boolean = false,
): JSONObject = computeQrBoundsObject(result.resultPoints, width, height, mirroredHorizontally)

internal fun computeQrBoundsObject(
    points: Array<out ResultPoint?>?,
    width: Int,
    height: Int,
    mirroredHorizontally: Boolean = false,
): JSONObject {
    val bounds = computeQrBounds(points, width, height, mirroredHorizontally)
    return JSONObject().apply {
        put("cx", bounds.cx)
        put("cy", bounds.cy)
        put("w", bounds.w)
        put("h", bounds.h)
    }
}

internal fun computeQrBounds(
    points: Array<out ResultPoint?>?,
    width: Int,
    height: Int,
    mirroredHorizontally: Boolean = false,
): QrBounds {
    if (width <= 0 || height <= 0) {
        return QrBounds(cx = 0.5, cy = 0.5, w = 0.0, h = 0.0)
    }
    if (points == null || points.isEmpty()) {
        return QrBounds(cx = 0.5, cy = 0.5, w = 0.0, h = 0.0)
    }
    var minX = Float.POSITIVE_INFINITY
    var maxX = Float.NEGATIVE_INFINITY
    var minY = Float.POSITIVE_INFINITY
    var maxY = Float.NEGATIVE_INFINITY
    for (p in points) {
        if (p == null) continue
        if (p.x < minX) minX = p.x
        if (p.x > maxX) maxX = p.x
        if (p.y < minY) minY = p.y
        if (p.y > maxY) maxY = p.y
    }
    if (!minX.isFinite() || !maxX.isFinite() || !minY.isFinite() || !maxY.isFinite()) {
        return QrBounds(cx = 0.5, cy = 0.5, w = 0.0, h = 0.0)
    }
    val sourceMinX = minX
    val sourceMaxX = maxX
    if (mirroredHorizontally) {
        minX = width.toFloat() - sourceMaxX
        maxX = width.toFloat() - sourceMinX
    }
    val cx = ((minX + maxX) * 0.5f) / width
    val cy = ((minY + maxY) * 0.5f) / height
    val w = (maxX - minX) / width
    val h = (maxY - minY) / height
    return QrBounds(cx = cx.toDouble(), cy = cy.toDouble(), w = w.toDouble(), h = h.toDouble())
}

/**
 * GodotPlugin singleton: `QRScannerPlugin`.
 *
 * Lifecycle:
 *   GDScript calls startScan() → we request CAMERA permission if needed,
 *   open the first reasonable Camera2 device, register an ImageReader for
 *   640x480 YUV_420_888 at ~15 fps, decode each frame with ZXing's
 *   QR_CODE reader, and emit `qr_detections(results_json)` for each
 *   successful frame. stopScan() tears the session down.
 *
 *   The plugin owns one persistent background HandlerThread for camera
 *   callbacks and ImageReader notifications; it lives for the duration of
 *   the scan session. Decoding runs on the same thread — ZXing decodes a
 *   640x480 luma plane in well under 60 ms on Snapdragon XR2, so a single
 *   thread keeps the camera queue from backing up at 15 fps.
 *
 * Threading rules:
 *   - All emitSignal calls go through the main thread via emitToGodot().
 *   - Camera2 callbacks and ImageReader.OnImageAvailableListener run on
 *     `cameraHandler` (the background HandlerThread).
 *   - `running` is the source of truth for "are we currently scanning"
 *     and is written from both the camera thread (on close) and the main
 *     thread (on startScan / stopScan).
 *
 * Permission handling:
 *   Camera2 scanning on Quest is gated by standard `android.permission.CAMERA`
 *   plus Horizon OS's dangerous `horizonos.permission.HEADSET_CAMERA` runtime
 *   permission. Pico QR scanning does not open Camera2: the GDScript overlay
 *   pumps XR_PICO_camera_image frames into decodeExternalRgbaFrame(), so the
 *   only runtime permission we can reliably request is the same standard
 *   CAMERA permission used by PicoCapturePlugin. Pico vendor camera
 *   entitlements still live in the merged manifest, but most Pico permission
 *   names are normal/signature permissions and will never be granted through
 *   requestPermissions().
 *
 *   We resolve the per-device permission set dynamically and only include
 *   vendor permissions that are actually dangerous runtime permissions.
 *   Quest keeps a manufacturer fallback because Horizon OS builds have
 *   hidden HEADSET_CAMERA from PackageManager on some releases.
 *
 *   If any required permission is missing, hasCameraPermission() returns
 *   false; the GDScript overlay calls requestCameraPermission() to pop
 *   the OS dialog, then shows a "grant + retry" hint. After grant +
 *   retry, startScan() proceeds and Camera2.openCamera() actually
 *   succeeds against the passthrough camera ID.
 */
class QRScannerPlugin(godot: Godot) : GodotPlugin(godot) {

    companion object {
        private const val TAG = "QRScannerPlugin"
        private const val PERMISSION_REQUEST_CODE = 0x510D
        // 640x480 is generous for ZXing — bigger inputs waste CPU and
        // smaller ones miss codes at typical headset-to-monitor distance.
        private const val PREFERRED_WIDTH = 640
        private const val PREFERRED_HEIGHT = 480
        private const val MAX_IMAGES = 2
        // Throttle our decode work: even if the camera fires faster, we
        // skip frames that arrive within this window of the last decode.
        // 15 fps target ⇒ 66 ms.
        private const val DECODE_INTERVAL_MS = 60L
        private const val PREVIEW_INTERVAL_MS = 250L
        private const val META_CAMERA_SOURCE_PASSTHROUGH = 0
        private const val META_CAMERA_POSITION_LEFT = 0
        private const val META_CAMERA_POSITION_RIGHT = 1

        // Vendor passthrough/headset camera permissions. At runtime we only
        // request dangerous permissions; normal/signature vendor entitlements
        // are manifest-only and cannot be granted by requestPermissions().
        private const val PERM_HEADSET_CAMERA = "horizonos.permission.HEADSET_CAMERA"
        private const val PERM_PICOVR_CAMERA = "com.picovr.permission.CAMERA"
        private val VENDOR_CAMERA_PERMISSIONS = listOf(
            PERM_HEADSET_CAMERA,
            PERM_PICOVR_CAMERA,
        )
    }

    private data class DecodedQr(
        val result: Result,
        val mirroredHorizontally: Boolean,
    )

    override fun getPluginName(): String = "QRScannerPlugin"

    override fun getPluginSignals(): MutableSet<SignalInfo> {
        return mutableSetOf(
            // payload: the decoded text (we only emit on the QR_CODE format).
            // bounds_json: JSON with normalized 0..1 cx/cy/w/h relative to the
            //              captured frame. The GDScript overlay maps these
            //              into the SubViewport's coordinate system.
            SignalInfo("qr_detected", String::class.java, String::class.java),
            // results_json: JSON array of { payload: String, bounds: Object }.
            // Prefer this signal; one camera frame can contain multiple QR codes.
            SignalInfo("qr_detections", String::class.java),
            // frame_path: cache file containing the current luma frame that was
            // sent into ZXing. Emitted at low rate so the GDScript panel can
            // show a live preview of what the scanner actually sees.
            SignalInfo("qr_preview_frame", String::class.java),
            // message: short opaque tag. Known values:
            //   "permission_denied"  user has not granted CAMERA
            //   "no_camera"          no usable camera on this device
            //   "open_failed:<n>"    Camera2 errored out with code <n>
            //   "session_failed"     CameraCaptureSession.onConfigureFailed
            SignalInfo("qr_error", String::class.java),
            // Fires when the OS permission dialog we opened from
            // requestCameraPermission() returns with all required
            // permissions now GRANTED. Lets the GDScript overlay
            // auto-retry startScan() without making the user close
            // and re-open the scanner panel after tapping Allow.
            SignalInfo("qr_permission_granted"),
        )
    }

    private val activityRef: Activity?
        // Use the explicit Java-style getter to match the convention in
        // QuestCapturePlugin.kt — Kotlin's auto-property mapping over the
        // GodotPlugin Java API has bitten people on framework upgrades.
        get() = getActivity()

    private var cameraThread: HandlerThread? = null
    private var cameraHandler: Handler? = null
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    private val running = AtomicBoolean(false)
    private val decodeHints = mapOf(
        DecodeHintType.POSSIBLE_FORMATS to listOf(com.google.zxing.BarcodeFormat.QR_CODE),
        DecodeHintType.TRY_HARDER to true,
    )
    private val reader = MultiFormatReader().apply {
        setHints(decodeHints)
    }
    private val multiReader = QRCodeMultiReader()
    private var lastDecodeAtMs = 0L
    private var lastPreviewAtMs = 0L
    private var frameCount = 0L
    @Volatile
    private var lastDetectedFramePath = ""

    // --- Public, GDScript-callable API ----------------------------------- //

    @UsedByGodot
    fun startScan(): Boolean {
        val ctx = activityRef
        if (ctx == null) {
            Log.w(TAG, "startScan: no activity")
            emitError("no_activity")
            return false
        }
        if (!hasCameraPermission()) {
            // Defensive auto-request: if a GDScript caller forgot the
            // permission gate (or the gate short-circuited because the
            // Godot Object bridge's has_method() can't see @UsedByGodot
            // entries), fire the OS prompt now so the user has a
            // recovery path. This is safe — requestPermissions is a
            // no-op when nothing's missing, and a duplicate request
            // when the user already declined just re-shows the dialog.
            Log.w(TAG, "startScan: permission missing; firing requestPermissions and aborting this call")
            requestCameraPermission()
            emitError("permission_denied")
            return false
        }
        if (running.get()) {
            Log.i(TAG, "startScan: already running")
            return true
        }
        return synchronized(this) {
            if (running.get()) return@synchronized true
            try {
                Log.i(TAG, "startScan: opening camera")
                lastDetectedFramePath = ""
                lastPreviewAtMs = 0L
                // openCameraBlocking returns false (and has already
                // emitted a specific qr_error tag) on its own
                // recoverable error paths — no_camera, permission lost
                // mid-flight. Without this gate, the outer try would
                // mark running=true on a failed start and the user
                // would be stuck (next startScan() short-circuits on
                // running.get()).
                if (!openCameraBlocking(ctx)) {
                    return@synchronized false
                }
                running.set(true)
                Log.i(TAG, "startScan: camera open requested")
                true
            } catch (t: Throwable) {
                Log.e(TAG, "startScan failed", t)
                emitError("open_failed:${t.message ?: "unknown"}")
                shutdownInternal()
                false
            }
        }
    }

    @UsedByGodot
    fun stopScan() {
        synchronized(this) {
            if (!running.get()) return
            shutdownInternal()
            running.set(false)
        }
    }

    @UsedByGodot
    fun isScanning(): Boolean = running.get()

    @UsedByGodot
    fun hasCameraPermission(): Boolean {
        val ctx = activityRef ?: return false
        return requiredRuntimePermissions(ctx).all {
            ContextCompat.checkSelfPermission(ctx, it) == PackageManager.PERMISSION_GRANTED
        }
    }

    /**
     * Godot lifecycle hook: fires on the main thread after
     * ActivityCompat.requestPermissions() (called from
     * requestCameraPermission()) returns with the user's choice.
     *
     * If our request code matches and the user granted everything we
     * need, emit qr_permission_granted so the GDScript overlay can
     * auto-retry startScan() — saving the user the "tap Cancel, tap
     * 📷 again" detour. We re-check via hasCameraPermission() rather
     * than scanning grantResults directly so the vendor-aware policy
     * stays in one place.
     */
    override fun onMainRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String?>?,
        grantResults: IntArray?,
    ) {
        super.onMainRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != PERMISSION_REQUEST_CODE) return
        val names = permissions?.joinToString(",") { it ?: "<null>" } ?: "<null>"
        val granted = hasCameraPermission()
        Log.i(TAG, "onMainRequestPermissionsResult: code=$requestCode allGranted=$granted permissions=[$names]")
        if (granted) {
            emitOnGodotThread { emitSignal("qr_permission_granted") }
        }
    }

    @UsedByGodot
    fun requestCameraPermission() {
        val ctx = activityRef ?: return
        val missing = requiredRuntimePermissions(ctx).filter {
            ContextCompat.checkSelfPermission(ctx, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) return
        Log.i(TAG, "requesting runtime permissions: ${missing.joinToString(",")}")
        ActivityCompat.requestPermissions(
            ctx,
            missing.toTypedArray(),
            PERMISSION_REQUEST_CODE,
        )
    }

    /**
     * Per-device required runtime permission set.
     *
     * - Standard `android.permission.CAMERA` is always required.
     * - `horizonos.permission.HEADSET_CAMERA` is required on Quest because
     *   Horizon OS treats it as a dangerous runtime permission. Some Quest
     *   builds hide it from getPermissionInfo(), so we keep a manufacturer
     *   fallback there.
     * - `com.picovr.permission.CAMERA` is *not* required just because the
     *   device is Pico. On current Pico builds it can appear in the merged
     *   manifest via the OpenXR loader, but requestPermissions() cannot grant
     *   it as a normal/signature permission; requiring it wedged QR scanning
     *   at "camera permission needed" even after PicoCapturePlugin had already
     *   obtained android.permission.CAMERA for recording. Only require it if
     *   the runtime explicitly reports it as dangerous.
     *
     * All three perms are declared in our merged manifest already; this
     * function only decides which ones we treat as required at runtime.
     */
    private fun requiredRuntimePermissions(ctx: Activity): List<String> {
        val out = mutableListOf(Manifest.permission.CAMERA)
        val mfr = (Build.MANUFACTURER ?: "").lowercase()
        val brand = (Build.BRAND ?: "").lowercase()
        val isQuest = mfr.contains("oculus") || mfr.contains("meta") ||
            brand.contains("oculus") || brand.contains("meta")
        val isPico = mfr.contains("pico") || mfr.contains("bytedance") ||
            brand.contains("pico")
        for (vendor in VENDOR_CAMERA_PERMISSIONS) {
            val info = permissionInfoOrNull(ctx, vendor)
            val dangerous = isDangerousPermission(info)
            val questFallback = vendor == PERM_HEADSET_CAMERA && isQuest
            if (dangerous || questFallback) {
                out.add(vendor)
                Log.i(
                    TAG,
                    "requiring vendor permission $vendor (dangerous=$dangerous questFallback=$questFallback isPico=$isPico mfr=$mfr brand=$brand)",
                )
            } else {
                Log.i(
                    TAG,
                    "skipping vendor permission $vendor (dangerous=false questFallback=false isPico=$isPico mfr=$mfr brand=$brand)",
                )
            }
        }
        return out
    }

    private fun permissionInfoOrNull(ctx: Activity, name: String): PermissionInfo? {
        return try {
            ctx.packageManager.getPermissionInfo(name, 0)
        } catch (_: PackageManager.NameNotFoundException) {
            null
        } catch (t: Throwable) {
            // Defensive — some OEM stubs throw RuntimeException on unknown
            // permission lookups instead of NameNotFoundException. Treat
            // every failure as "probe inconclusive"; the Build.MANUFACTURER
            // signal in requiredRuntimePermissions() is the real safety net.
            Log.w(TAG, "getPermissionInfo($name) threw; treating as undefined", t)
            null
        }
    }

    @Suppress("DEPRECATION")
    private fun isDangerousPermission(info: PermissionInfo?): Boolean {
        if (info == null) return false
        return (info.protectionLevel and PermissionInfo.PROTECTION_MASK_BASE) ==
            PermissionInfo.PROTECTION_DANGEROUS
    }

    @UsedByGodot
    fun getLastDetectedFramePath(): String = lastDetectedFramePath

    // --- Camera2 setup --------------------------------------------------- //

    /**
     * Allocate the camera + image reader and kick off Camera2.openCamera.
     * Returns true iff openCamera was actually invoked (final success is
     * still async, signaled via deviceCallback.onOpened). Returns false
     * after emitting a specific qr_error tag for the recoverable cases
     * (no usable camera; permission revoked mid-flight). Throws on truly
     * unexpected failures so the caller's broad catch can emit
     * open_failed:<msg>.
     */
    private fun openCameraBlocking(ctx: Activity): Boolean {
        val manager = ctx.getSystemService(android.content.Context.CAMERA_SERVICE) as CameraManager
        val cameraId = pickCameraId(manager)
        if (cameraId == null) {
            Log.w(TAG, "openCamera: no usable camera; ids=${manager.cameraIdList.joinToString(",")}")
            emitError("no_camera")
            return false
        }

        val thread = HandlerThread("qr-scanner-camera").also { it.start() }
        cameraThread = thread
        val handler = Handler(thread.looper)
        cameraHandler = handler

        val size = pickPreviewSize(manager, cameraId)
        Log.i(TAG, "openCamera: id=$cameraId size=${size.width}x${size.height}")
        val reader = ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, MAX_IMAGES)
        reader.setOnImageAvailableListener(::onImageAvailable, handler)
        imageReader = reader

        return try {
            // Re-check the full vendor-aware permission set immediately
            // before openCamera() so we don't go through the throw-and-
            // catch dance below for the simple "permission was revoked
            // since startScan()" case. Important on Quest: granting
            // CAMERA but not HEADSET_CAMERA passes the legacy single-
            // permission check yet still SecurityException's from
            // openCamera() on a passthrough camera id.
            if (!hasCameraPermission()) {
                emitError("permission_denied")
                shutdownInternal()
                return false
            }
            manager.openCamera(cameraId, deviceCallback, handler)
            true
        } catch (se: SecurityException) {
            // Race: permission revoked between checkSelfPermission and
            // openCamera. Emit ONLY permission_denied (not open_failed) so
            // the GDScript overlay shows the right hint, and bail without
            // re-throwing — re-throwing would trigger the outer catch in
            // startScan() and emit a second open_failed:... that masks the
            // real cause.
            Log.w(TAG, "openCamera lost permission", se)
            emitError("permission_denied")
            shutdownInternal()
            false
        }
    }

    private fun pickCameraId(manager: CameraManager): String? {
        var selected: String? = null
        var selectedScore = Int.MAX_VALUE
        for (id in manager.cameraIdList) {
            val chars = manager.getCameraCharacteristics(id)
            val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            val yuvSizes = map?.getOutputSizes(ImageFormat.YUV_420_888)
            if (yuvSizes == null || yuvSizes.isEmpty()) {
                continue
            }
            val facing = chars.get(CameraCharacteristics.LENS_FACING)
            val cameraSource = readVendorInt(chars, "com.meta.extra_metadata.camera_source")
            val position = readVendorInt(chars, "com.meta.extra_metadata.position")
            val score = when {
                cameraSource == META_CAMERA_SOURCE_PASSTHROUGH && position == META_CAMERA_POSITION_LEFT -> 0
                cameraSource == META_CAMERA_SOURCE_PASSTHROUGH && position == META_CAMERA_POSITION_RIGHT -> 1
                cameraSource == META_CAMERA_SOURCE_PASSTHROUGH -> 2
                facing == CameraCharacteristics.LENS_FACING_BACK -> 10
                facing == CameraCharacteristics.LENS_FACING_FRONT -> 20
                else -> 30
            }
            Log.i(
                TAG,
                "camera candidate id=$id facing=${facingName(facing)} source=$cameraSource position=$position score=$score yuv=${formatSizes(yuvSizes)}",
            )
            if (score < selectedScore) {
                selected = id
                selectedScore = score
            }
        }
        return selected
    }

    private fun pickPreviewSize(manager: CameraManager, cameraId: String): Size {
        val map = manager
            .getCameraCharacteristics(cameraId)
            .get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val supported = map?.getOutputSizes(ImageFormat.YUV_420_888) ?: return Size(PREFERRED_WIDTH, PREFERRED_HEIGHT)
        // Pick the size closest to PREFERRED_WIDTH x PREFERRED_HEIGHT.
        return supported.minByOrNull { sz ->
            kotlin.math.abs(sz.width - PREFERRED_WIDTH) + kotlin.math.abs(sz.height - PREFERRED_HEIGHT)
        } ?: Size(PREFERRED_WIDTH, PREFERRED_HEIGHT)
    }

    private val deviceCallback = object : CameraDevice.StateCallback() {
        override fun onOpened(device: CameraDevice) {
            Log.i(TAG, "camera opened")
            cameraDevice = device
            startCaptureSession(device)
        }
        override fun onDisconnected(device: CameraDevice) {
            Log.w(TAG, "camera disconnected")
            // device.close() is mandated by the contract. The rest of
            // the teardown (ImageReader, HandlerThread) MUST happen off
            // the camera thread because shutdownInternal() joins it.
            device.close()
            cameraDevice = null
            scheduleAsyncShutdown()
        }
        override fun onError(device: CameraDevice, error: Int) {
            Log.e(TAG, "camera error: $error")
            emitError("open_failed:$error")
            device.close()
            cameraDevice = null
            scheduleAsyncShutdown()
        }
    }

    /**
     * Tear down asynchronously from a Camera2 callback so we don't
     * deadlock joining the HandlerThread we're currently running on.
     * The state flip (running = false) happens first so a concurrent
     * startScan() from GDScript notices the camera is gone and goes
     * through the full open path again.
     */
    private fun scheduleAsyncShutdown() {
        running.set(false)
        emitOnGodotThread {
            // synchronized matches stopScan() so a user-initiated
            // stop racing with the camera-side teardown can't try to
            // tear down twice.
            synchronized(this@QRScannerPlugin) {
                shutdownInternal()
            }
        }
    }

    private fun startCaptureSession(device: CameraDevice) {
        val reader = imageReader ?: return
        val handler = cameraHandler ?: return
        val surface: Surface = reader.surface
        val builder = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
            addTarget(surface)
            // Auto-everything; QR doesn't need manual exposure tuning.
            set(CaptureRequest.CONTROL_MODE, CameraMetadata_CONTROL_MODE_AUTO)
        }
        device.createCaptureSession(
            listOf(surface),
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    captureSession = session
                    try {
                        session.setRepeatingRequest(builder.build(), null, handler)
                        Log.i(TAG, "capture session configured")
                    } catch (t: Throwable) {
                        Log.e(TAG, "setRepeatingRequest failed", t)
                        emitError("session_failed")
                    }
                }
                override fun onConfigureFailed(session: CameraCaptureSession) {
                    Log.e(TAG, "session configure failed")
                    emitError("session_failed")
                }
            },
            handler,
        )
    }

    // CameraMetadata#CONTROL_MODE_AUTO is `1`; spelling it out so the
    // import set stays tight (no android.hardware.camera2.CameraMetadata
    // import just for one constant).
    @Suppress("PrivatePropertyName")
    private val CameraMetadata_CONTROL_MODE_AUTO = 1

    // --- Decode loop ----------------------------------------------------- //

    private fun onImageAvailable(reader: ImageReader) {
        val image = reader.acquireLatestImage() ?: return
        try {
            frameCount += 1
            if (frameCount <= 5L || frameCount % 60L == 0L) {
                val y = image.planes[0]
                Log.i(
                    TAG,
                    "camera frames received: $frameCount (${image.width}x${image.height}) y(row=${y.rowStride},pixel=${y.pixelStride},cap=${y.buffer.capacity()})",
                )
            }
            val now = System.currentTimeMillis()
            if (now - lastDecodeAtMs < DECODE_INTERVAL_MS) return
            lastDecodeAtMs = now
            decodeImage(image)
        } catch (t: Throwable) {
            Log.w(TAG, "frame processing failed", t)
            this.reader.reset()
        } finally {
            image.close()
        }
    }

    private fun decodeImage(image: android.media.Image) {
        // Y plane only. YUV_420_888 guarantees plane 0 is luma, stride
        // may exceed width — copy row by row into a tight buffer that
        // PlanarYUVLuminanceSource expects.
        val width = image.width
        val height = image.height
        val out = copyLumaPlane(image)
        processLumaFrame(out, width, height)
    }

    /**
     * Decode one externally-captured RGBA8888 frame.
     *
     * Pico path: PicoOS does not expose the passthrough cameras through
     * Camera2, so startScan()'s pickCameraId() finds nothing usable there.
     * Instead the GDScript overlay pumps frames out of the OpenXR
     * XR_PICO_camera_image extension (PicoOpenXRExtension GDExtension)
     * and pushes them here. This entry point therefore deliberately does
     * NOT require `running` or a Camera2 session — the caller owns the
     * camera lifecycle; we only own decode + preview/frozen-frame +
     * signal emission, which is the same tail the Camera2 path uses.
     *
     * Threading: called on the Godot main thread. The Camera2 path
     * decodes on `cameraHandler`, but the two sources are mutually
     * exclusive by construction (a device either has a Camera2
     * passthrough id or it routes through this entry point), so sharing
     * `reader`/`multiReader`/`lastDecodeAtMs` without extra locking is
     * safe in practice.
     *
     * Returns true iff the frame was accepted (valid + not throttled)
     * and at least one QR code decoded. Detections are still delivered
     * via the qr_detections signal like the Camera2 path.
     */
    @UsedByGodot
    fun decodeExternalRgbaFrame(width: Int, height: Int, stride: Int, pixelStride: Int, data: ByteArray): Boolean {
        if (width <= 0 || height <= 0) return false
        val px = if (pixelStride > 0) pixelStride else 4
        // The native extension already normalizes stride >= width * px;
        // re-derive defensively so a zero/garbage stride can't make us
        // walk the buffer with the wrong row pitch.
        val rowStride = if (stride >= width * px) stride else width * px
        // Last byte we touch is the B channel of the bottom-right pixel.
        val required = (height - 1).toLong() * rowStride + (width - 1).toLong() * px + 3
        if (data.size < required) {
            Log.w(TAG, "decodeExternalRgbaFrame: short buffer ${data.size} < $required (${width}x$height stride=$rowStride px=$px)")
            return false
        }
        // Same decode throttle as the Camera2 path. The GDScript pump is
        // already paced (~10 fps), but a misbehaving caller shouldn't be
        // able to spin ZXing on every render frame.
        val now = System.currentTimeMillis()
        if (now - lastDecodeAtMs < DECODE_INTERVAL_MS) return false
        lastDecodeAtMs = now
        // RGBA → luma with integer BT.601 ((77R + 150G + 29B) >> 8).
        // True luminance instead of a G-only shortcut: QR codes rendered
        // in saturated colors (red/blue on white is common on phone
        // screens) keep their module contrast under BT.601 but can
        // flatten into the background if only green is sampled. The
        // integer form costs three multiplies per pixel — negligible at
        // 640x480 @ ~10 fps.
        val luma = ByteArray(width * height)
        var dst = 0
        for (y in 0 until height) {
            var src = y * rowStride
            for (x in 0 until width) {
                val r = data[src].toInt() and 0xff
                val g = data[src + 1].toInt() and 0xff
                val b = data[src + 2].toInt() and 0xff
                luma[dst] = ((77 * r + 150 * g + 29 * b) shr 8).toByte()
                dst += 1
                src += px
            }
        }
        return processLumaFrame(luma, width, height)
    }

    /**
     * Shared decode tail for both frame sources — Camera2 (Quest) and
     * externally-pumped RGBA frames (Pico). Takes a tight (stride ==
     * width) luma buffer; handles preview snapshots, ZXing decode, the
     * frozen detection frame, and signal emission. Returns true when at
     * least one QR code was decoded from this frame.
     */
    private fun processLumaFrame(luma: ByteArray, width: Int, height: Int): Boolean {
        val previewPath = maybeWritePreviewFrame(luma, width, height)
        if (previewPath.isNotEmpty()) {
            emitOnGodotThread {
                emitSignal("qr_preview_frame", previewPath)
            }
        }

        val decoded = decodeAllSources(luma, width, height)
        if (decoded.isEmpty()) return false
        Log.i(TAG, "qr detected count=${decoded.size}")
        lastDetectedFramePath = writeFrozenFrame(luma, width, height)
        val batch = JSONArray()
        for ((text, result) in decoded) {
            batch.put(
                JSONObject().apply {
                    put("payload", text)
                    put(
                        "bounds",
                        computeQrBoundsObject(result.result, width, height, result.mirroredHorizontally),
                    )
                },
            )
        }
        emitOnGodotThread {
            emitSignal("qr_detections", batch.toString())
            // Backwards compatibility for older overlays.
            for ((text, result) in decoded) {
                emitSignal(
                    "qr_detected",
                    text,
                    computeQrBoundsObject(result.result, width, height, result.mirroredHorizontally).toString(),
                )
            }
        }
        return true
    }

    private fun decodeAllSources(luma: ByteArray, width: Int, height: Int): LinkedHashMap<String, DecodedQr> {
        val out = LinkedHashMap<String, DecodedQr>()
        val source = PlanarYUVLuminanceSource(luma, width, height, 0, 0, width, height, false)
        addDecodedResults(out, decodeSourceMultiple(source), false)
        addDecodedResults(out, decodeSourceMultiple(source.invert()), false)
        val mirrored = PlanarYUVLuminanceSource(luma.copyOf(), width, height, 0, 0, width, height, true)
        addDecodedResults(out, decodeSourceMultiple(mirrored), true)
        addDecodedResults(out, decodeSourceMultiple(mirrored.invert()), true)
        if (out.isEmpty()) {
            val single = decodeSource(source) ?: decodeSource(source.invert())
            if (single != null) {
                val text = single.text
                if (!text.isNullOrBlank()) out[text] = DecodedQr(single, false)
            }
        }
        return out
    }

    private fun addDecodedResults(
        out: LinkedHashMap<String, DecodedQr>,
        results: List<Result>,
        mirroredHorizontally: Boolean,
    ) {
        for (result in results) {
            val text = result.text
            if (text.isNullOrBlank()) continue
            if (!out.containsKey(text)) out[text] = DecodedQr(result, mirroredHorizontally)
        }
    }

    private fun decodeSourceMultiple(source: LuminanceSource): List<Result> {
        return try {
            multiReader.decodeMultiple(BinaryBitmap(HybridBinarizer(source)), decodeHints).toList()
        } catch (_: NotFoundException) {
            emptyList()
        } finally {
            multiReader.reset()
        }
    }

    private fun decodeSource(source: LuminanceSource): Result? {
        return try {
            reader.decodeWithState(BinaryBitmap(HybridBinarizer(source)))
        } catch (_: NotFoundException) {
            null
        } finally {
            reader.reset()
        }
    }

    private fun copyLumaPlane(image: android.media.Image): ByteArray {
        val plane = image.planes[0]
        val width = image.width
        val height = image.height
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        val src = plane.buffer.duplicate()
        val out = ByteArray(width * height)
        var dstOff = 0
        for (y in 0 until height) {
            val rowStart = y * rowStride
            if (pixelStride == 1) {
                src.position(rowStart)
                src.get(out, dstOff, width)
                dstOff += width
            } else {
                for (x in 0 until width) {
                    out[dstOff] = src.get(rowStart + x * pixelStride)
                    dstOff += 1
                }
            }
        }
        return out
    }

    private fun maybeWritePreviewFrame(luma: ByteArray, width: Int, height: Int): String {
        val now = System.currentTimeMillis()
        if (now - lastPreviewAtMs < PREVIEW_INTERVAL_MS) return ""
        lastPreviewAtMs = now
        return writeLumaFrame(luma, width, height, "qr_preview_frame.jpg", 72, "preview QR frame")
    }

    private fun writeFrozenFrame(luma: ByteArray, width: Int, height: Int): String {
        return writeLumaFrame(luma, width, height, "qr_detected_frame.jpg", 88, "frozen QR frame")
    }

    private fun writeLumaFrame(luma: ByteArray, width: Int, height: Int, fileName: String, quality: Int, label: String): String {
        val ctx = activityRef ?: return ""
        return try {
            val pixels = IntArray(width * height)
            for (i in pixels.indices) {
                val y = luma[i].toInt() and 0xff
                pixels[i] = (0xff shl 24) or (y shl 16) or (y shl 8) or y
            }
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            bitmap.setPixels(pixels, 0, width, 0, 0, width, height)
            val file = File(ctx.cacheDir, fileName)
            file.outputStream().use { out ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
            }
            bitmap.recycle()
            file.absolutePath
        } catch (t: Throwable) {
            Log.w(TAG, "failed to write $label", t)
            ""
        }
    }

    // --- Shutdown -------------------------------------------------------- //

    private fun shutdownInternal() {
        try {
            captureSession?.close()
        } catch (_: Throwable) {
        }
        captureSession = null

        try {
            cameraDevice?.close()
        } catch (_: Throwable) {
        }
        cameraDevice = null

        try {
            imageReader?.close()
        } catch (_: Throwable) {
        }
        imageReader = null

        cameraThread?.let {
            it.quitSafely()
            try {
                it.join(250)
            } catch (_: InterruptedException) {
            }
        }
        cameraThread = null
        cameraHandler = null
        // Reset the throttle so the first frame of the next scan isn't
        // skipped against a stale timestamp.
        lastDecodeAtMs = 0L
        lastPreviewAtMs = 0L
        frameCount = 0L
        Log.i(TAG, "scanner stopped")
    }

    private fun emitError(tag: String) {
        emitOnGodotThread {
            emitSignal("qr_error", tag)
        }
    }

    private fun emitOnGodotThread(block: () -> Unit) {
        val act = activityRef
        if (act != null) {
            act.runOnUiThread(block)
        } else {
            block()
        }
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

    private fun facingName(facing: Int?): String {
        return when (facing) {
            CameraCharacteristics.LENS_FACING_BACK -> "back"
            CameraCharacteristics.LENS_FACING_FRONT -> "front"
            CameraCharacteristics.LENS_FACING_EXTERNAL -> "external"
            null -> "unknown"
            else -> facing.toString()
        }
    }

    private fun formatSizes(sizes: Array<Size>): String {
        return sizes
            .take(4)
            .joinToString(prefix = "[", postfix = if (sizes.size > 4) ",...]" else "]") { "${it.width}x${it.height}" }
    }
}
