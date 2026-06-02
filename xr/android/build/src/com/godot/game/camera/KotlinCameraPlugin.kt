package com.godot.game.camera

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.renderscript.Allocation
import android.renderscript.Element
import android.renderscript.RenderScript
import android.renderscript.ScriptIntrinsicYuvToRGB
import android.renderscript.Type
import android.util.Size
import android.util.Log
import android.view.Surface
import androidx.core.app.ActivityCompat
import org.godotengine.godot.Dictionary
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

private const val TAG = "KotlinCameraPlugin"
private const val KEY_CAMERA_POSITION = "com.meta.extra_metadata.position"
private const val KEY_CAMERA_SOURCE = "com.meta.extra_metadata.camera_source"
private const val CAMERA_SOURCE_PASSTHROUGH = 0
private const val REQUEST_PERMISSIONS_CODE = 1337
private const val IMAGE_BUFFER_SIZE = 3
private const val HZOS_CAMERA_PERMISSION = "horizonos.permission.HEADSET_CAMERA"

private enum class Position(val raw: Int) {
	LEFT(0),
	RIGHT(1),
	UNKNOWN(-1);

	companion object {
		fun from(raw: Int?): Position =
			when (raw) {
				0 -> LEFT
				1 -> RIGHT
				else -> UNKNOWN
			}
	}
}

private data class CameraConfig(
	val id: String,
	val size: Size,
	val position: Position,
	val isPassthrough: Boolean,
)

private data class FrameData(
	val width: Int,
	val height: Int,
	val timestampNs: Long,
	val brightness: Float,
	val yPlane: ByteArray,
	val rgba: ByteArray,
)

class KotlinCameraPlugin(private val host: Godot) : GodotPlugin(host) {

	private val positionKey =
		CameraCharacteristics.Key(KEY_CAMERA_POSITION, Int::class.java)
	private val sourceKey =
		CameraCharacteristics.Key(KEY_CAMERA_SOURCE, Int::class.java)

	private val imageThread = HandlerThread("xrCameraImageThread").apply { start() }
	private val cameraThread = HandlerThread("xrCameraDeviceThread").apply { start() }
	private val imageHandler = Handler(imageThread.looper)
	private val cameraHandler = Handler(cameraThread.looper)
	private val sessionExecutor = Executors.newSingleThreadExecutor()

	private val running = AtomicBoolean(false)

	private var imageReader: ImageReader? = null
	private var cameraDevice: CameraDevice? = null
	private var cameraSession: CameraCaptureSession? = null
	private var activeConfig: CameraConfig? = null
	private var latestFrame: FrameData? = null
	private var renderScript: RenderScript? = null
	private var yuvToRgb: ScriptIntrinsicYuvToRGB? = null
	private var yuvAllocation: Allocation? = null
	private var rgbaAllocation: Allocation? = null
	private var rgbaBuffer: ByteArray = ByteArray(0)
	private var yuvType: Type? = null
	private var rgbaType: Type? = null

	override fun getPluginName(): String = "KotlinCameraPlugin"

	override fun getPluginMethods(): MutableList<String> =
		mutableListOf(
			"request_permissions",
			"has_permissions",
			"start_camera",
			"stop_camera",
			"is_running",
			"get_latest_frame",
			"get_available_cameras",
		)

	override fun getPluginSignals(): MutableSet<SignalInfo> =
		mutableSetOf(
			SignalInfo("frame_ready"),
			SignalInfo(
				"permissions_result",
				Boolean::class.javaObjectType,
				Boolean::class.javaObjectType,
			),
			SignalInfo("camera_error", String::class.java),
		)

	private val cameraManager: CameraManager?
		get() = activity?.getSystemService(Context.CAMERA_SERVICE) as? CameraManager

	override fun onMainDestroy() {
		super.onMainDestroy()
		stop_camera()
		imageThread.quitSafely()
		cameraThread.quitSafely()
	}

	override fun onMainRequestPermissionsResult(
		requestCode: Int,
		permissions: Array<out String>?,
		grantResults: IntArray?,
	) {
		if (requestCode == REQUEST_PERMISSIONS_CODE) {
			emit_permissions_result()
		}
	}

	@Suppress("FunctionName")
	fun request_permissions() {
		val activity = activity ?: return
		Log.i(TAG, "request_permissions called; vendor_supported=${isVendorPermissionSupported(activity)}")
		val permissions =
			buildList {
				add(Manifest.permission.CAMERA)
				if (isVendorPermissionSupported(activity)) {
					add(HZOS_CAMERA_PERMISSION)
				}
			}
		ActivityCompat.requestPermissions(activity, permissions.toTypedArray(), REQUEST_PERMISSIONS_CODE)
	}

	@Suppress("FunctionName")
	fun has_permissions(): Boolean {
		val activity = activity ?: return false
		val androidGranted =
			ActivityCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) ==
				PackageManager.PERMISSION_GRANTED
		val vendorGranted = hasVendorPermission(activity)
		Log.i(TAG, "has_permissions android=$androidGranted vendor=$vendorGranted")
		return androidGranted && vendorGranted
	}

	@Suppress("FunctionName")
	fun get_available_cameras(): MutableList<Dictionary> {
		val cameras = mutableListOf<Dictionary>()
		enumerateCameras().forEach { config ->
			val dict = Dictionary()
			dict["id"] = config.id
			dict["width"] = config.size.width
			dict["height"] = config.size.height
			dict["position"] = config.position.name
			dict["is_passthrough"] = config.isPassthrough
			cameras.add(dict)
		}
		return cameras
	}

	@Suppress("FunctionName")
	fun start_camera(position: String = "RIGHT"): Boolean {
		if (running.get()) {
			return true
		}
		Log.i(TAG, "start_camera requested (position=$position)")
		if (!has_permissions()) {
			emit_permissions_result()
			Log.w(TAG, "start_camera denied; missing permissions")
			return false
		}
		val allConfigs = enumerateCameras()
		val passthroughConfigs = allConfigs.filter { it.isPassthrough }
		val configs = if (passthroughConfigs.isNotEmpty()) passthroughConfigs else allConfigs
		if (configs.isEmpty()) {
			Log.e(TAG, "start_camera abort; no cameras found")
			emitSignal("camera_error", "No cameras found")
			return false
		}
		val targetPosition =
			if (position.equals("left", ignoreCase = true)) Position.LEFT else Position.RIGHT
		val targetConfig =
			configs.firstOrNull { it.position == targetPosition } ?: configs.first()
		Log.i(
			TAG,
			"start_camera selecting id=${targetConfig.id} pos=${targetConfig.position} passthrough=${targetConfig.isPassthrough} size=${targetConfig.size}"
		)
		activeConfig = targetConfig
		setupImageReader(targetConfig.size)

		val readerSurface = imageReader?.surface ?: return false
		val stateCallback =
			object : CameraDevice.StateCallback() {
				override fun onOpened(device: CameraDevice) {
					cameraDevice = device
					createSession(device, readerSurface)
				}

				override fun onDisconnected(device: CameraDevice) {
					emitSignal("camera_error", "Camera ${device.id} disconnected")
					stop_camera()
				}

				override fun onError(device: CameraDevice, error: Int) {
					emitSignal("camera_error", "Camera ${device.id} error $error")
					stop_camera()
				}
			}

		try {
			cameraManager?.openCamera(targetConfig.id, stateCallback, cameraHandler)
		} catch (e: SecurityException) {
			emitSignal("camera_error", "Missing camera permissions")
			return false
		} catch (e: Exception) {
			emitSignal("camera_error", "Failed to open camera: ${e.message}")
			return false
		}

		running.set(true)
		return true
	}

	@Suppress("FunctionName")
	fun stop_camera() {
		running.set(false)
		try {
			cameraSession?.stopRepeating()
		} catch (_: Exception) {}

		cameraSession?.close()
		cameraSession = null

		cameraDevice?.close()
		cameraDevice = null

		imageReader?.close()
		imageReader = null
	}

	@Suppress("FunctionName")
	fun is_running(): Boolean = running.get()

	@Suppress("FunctionName")
	fun get_latest_frame(): Dictionary {
		val dict = Dictionary()
		val frame = latestFrame ?: return dict
		dict["width"] = frame.width
		dict["height"] = frame.height
		dict["timestamp_ns"] = frame.timestampNs
		dict["brightness"] = frame.brightness
		dict["y_plane"] = frame.yPlane
		dict["rgba"] = frame.rgba
		return dict
	}

	private fun emit_permissions_result() {
		val activity = activity ?: return
		val androidGranted =
			ActivityCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) ==
				PackageManager.PERMISSION_GRANTED
		val vendorGranted = hasVendorPermission(activity)
		Log.i(TAG, "emit_permissions_result android=$androidGranted vendor=$vendorGranted")
		emitSignal("permissions_result", androidGranted, vendorGranted)
	}

	private fun hasVendorPermission(activity: Activity): Boolean {
		if (!isVendorPermissionSupported(activity)) {
			return true
		}
		return ActivityCompat.checkSelfPermission(activity, HZOS_CAMERA_PERMISSION) ==
			PackageManager.PERMISSION_GRANTED
	}

	private fun isVendorPermissionSupported(activity: Activity): Boolean =
		try {
			activity.packageManager?.getPermissionInfo(HZOS_CAMERA_PERMISSION, 0) != null
		} catch (_: Exception) {
			false
		}

	private fun enumerateCameras(): List<CameraConfig> {
		val manager = cameraManager ?: return emptyList()
		val list =
			manager.cameraIdList.mapNotNull { id ->
				val characteristics =
					try {
						manager.getCameraCharacteristics(id)
					} catch (_: Exception) {
						null
					} ?: return@mapNotNull null
				val size =
					characteristics.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE)
						?: return@mapNotNull null
				val position = Position.from(characteristics.get(positionKey))
				val source = characteristics.get(sourceKey)
				// Some builds may not expose META passthrough metadata; treat missing as valid so we still open a camera.
				val isPassthrough = source == null || source == CAMERA_SOURCE_PASSTHROUGH
				CameraConfig(
					id = id,
					size = size,
					position = position,
					isPassthrough = isPassthrough,
				)
			}
		val ids =
			list.joinToString { config ->
				"${config.id}:${config.position}:pt=${config.isPassthrough}"
			}
		Log.i(
			TAG,
			"enumerateCameras count=${list.size} passthrough=${list.count { it.isPassthrough }} ids=$ids"
		)
		return list
	}

	private fun setupImageReader(size: Size) {
		imageReader?.close()
		imageReader =
			ImageReader.newInstance(
				size.width,
				size.height,
				ImageFormat.YUV_420_888,
				IMAGE_BUFFER_SIZE,
			).apply {
				setOnImageAvailableListener(
					{ reader ->
						val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
						try {
							handleImage(image)
						} finally {
							image.close()
						}
					},
					imageHandler,
				)
			}
	}

	private fun createSession(device: CameraDevice, readerSurface: Surface) {
		val output =
			mutableListOf(OutputConfiguration(readerSurface))
		val sessionConfig =
			SessionConfiguration(
				SessionConfiguration.SESSION_REGULAR,
				output,
				sessionExecutor,
				object : CameraCaptureSession.StateCallback() {
					override fun onConfigured(session: CameraCaptureSession) {
						cameraSession = session
						startRepeating(session, readerSurface, device)
					}

					override fun onConfigureFailed(session: CameraCaptureSession) {
						emitSignal("camera_error", "Capture session failed")
					}
				},
			)
		device.createCaptureSession(sessionConfig)
	}

	private fun startRepeating(
		session: CameraCaptureSession,
		readerSurface: Surface,
		device: CameraDevice,
	) {
		val request =
			device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
				addTarget(readerSurface)
				set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
			}
		session.setRepeatingRequest(request.build(), null, cameraHandler)
	}

	private fun handleImage(image: Image) {
		if (!running.get()) {
			return
		}
		val width = image.width
		val height = image.height
		val yPlane = image.planes.firstOrNull() ?: return
		val yData = copyTightLuma(yPlane.buffer, yPlane.rowStride, width, height)
		val rgbaData = convertToRgba(image)
		val brightness = computeBrightness(yData)
		latestFrame =
			FrameData(
				width = width,
				height = height,
				timestampNs = image.timestamp,
				brightness = brightness,
				yPlane = yData,
				rgba = if (rgbaData.isEmpty()) convertToRgbaCpu(image) else rgbaData,
			)
		emitSignal("frame_ready")
	}

	private fun copyTightLuma(buffer: ByteBuffer, rowStride: Int, width: Int, height: Int): ByteArray {
		val out = ByteArray(width * height)
		val safeStride = max(rowStride, width)
		var dst = 0
		for (y in 0 until height) {
			val srcPosition = y * safeStride
			buffer.position(srcPosition)
			buffer.get(out, dst, width)
			dst += width
		}
		buffer.rewind()
		return out
	}

	private fun computeBrightness(yPlane: ByteArray): Float {
		if (yPlane.isEmpty()) {
			return -1f
		}
		var total = 0L
		for (b in yPlane) {
			total += (b.toInt() and 0xFF)
		}
		return total.toFloat() / yPlane.size.toFloat()
	}

	private fun convertToRgba(image: Image): ByteArray {
		val context = activity?.applicationContext ?: return ByteArray(0)
		val yuv = toNv21(image)
		if (yuv.isEmpty()) {
			return ByteArray(0)
		}
		ensureRenderScript(context, image.width, image.height, yuv.size)
		val rs = renderScript ?: return ByteArray(0)
		val yuvIn = yuvAllocation ?: return ByteArray(0)
		val rgbaOut = rgbaAllocation ?: return ByteArray(0)
		if (rgbaBuffer.isEmpty()) {
			return ByteArray(0)
		}
		return try {
			yuvIn.copyFrom(yuv)
			yuvToRgb?.setInput(yuvIn)
			yuvToRgb?.forEach(rgbaOut)
			rgbaOut.copyTo(rgbaBuffer)
			rgbaBuffer.clone()
		} catch (_: Exception) {
			ByteArray(0)
		}
	}

	private fun ensureRenderScript(context: Context, width: Int, height: Int, yuvSize: Int) {
		if (renderScript == null) {
			renderScript = RenderScript.create(context)
		}
		if (renderScript == null) {
			return
		}
		if (yuvType == null || yuvType?.count != yuvSize) {
			yuvType =
				Type.Builder(renderScript, Element.U8(renderScript)).setX(yuvSize).create()
			yuvAllocation = Allocation.createTyped(renderScript, yuvType, Allocation.USAGE_SCRIPT)
		}
		if (rgbaType == null || rgbaType?.x != width || rgbaType?.y != height) {
			rgbaType =
				Type.Builder(renderScript, Element.RGBA_8888(renderScript))
					.setX(width)
					.setY(height)
					.create()
			rgbaAllocation = Allocation.createTyped(renderScript, rgbaType, Allocation.USAGE_SCRIPT)
			rgbaBuffer = ByteArray(width * height * 4)
		}
		if (yuvToRgb == null) {
			yuvToRgb = ScriptIntrinsicYuvToRGB.create(renderScript, Element.U8_4(renderScript))
		}
	}

	private fun toNv21(image: Image): ByteArray {
		val yPlane = image.planes.getOrNull(0) ?: return ByteArray(0)
		val uPlane = image.planes.getOrNull(1) ?: return ByteArray(0)
		val vPlane = image.planes.getOrNull(2) ?: return ByteArray(0)

		val ySize = image.width * image.height
		val uvSize = ySize / 2
		val nv21 = ByteArray(ySize + uvSize)

		yPlane.buffer.get(nv21, 0, ySize)

		val chromaWidth = image.width / 2
		val chromaHeight = image.height / 2
		var offset = ySize
		val uBuffer = uPlane.buffer
		val vBuffer = vPlane.buffer
		val uRowStride = uPlane.rowStride
		val vRowStride = vPlane.rowStride
		val uPixelStride = uPlane.pixelStride
		val vPixelStride = vPlane.pixelStride

		for (row in 0 until chromaHeight) {
			var uIndex = row * uRowStride
			var vIndex = row * vRowStride
			for (col in 0 until chromaWidth) {
				val v = vBuffer.get(vIndex).toInt()
				val u = uBuffer.get(uIndex).toInt()
				nv21[offset++] = v.toByte()
				nv21[offset++] = u.toByte()
				uIndex += uPixelStride
				vIndex += vPixelStride
			}
		}

		return nv21
	}

	private fun convertToRgbaCpu(image: Image): ByteArray {
		if (image.format != ImageFormat.YUV_420_888) {
			return ByteArray(0)
		}
		val planes = image.planes
		if (planes.size < 3) {
			return ByteArray(0)
		}
		val yPlane = planes[0]
		val uPlane = planes[1]
		val vPlane = planes[2]

		val yBuffer = yPlane.buffer
		val uBuffer = uPlane.buffer
		val vBuffer = vPlane.buffer

		val rgba = ByteArray(image.width * image.height * 4)
		var dst = 0

		val yRowStride = yPlane.rowStride
		val uRowStride = uPlane.rowStride
		val vRowStride = vPlane.rowStride
		val uPixelStride = uPlane.pixelStride
		val vPixelStride = vPlane.pixelStride

		for (y in 0 until image.height) {
			val yRow = y * yRowStride
			val uvRow = (y / 2) * uRowStride
			val vvRow = (y / 2) * vRowStride
			for (x in 0 until image.width) {
				val yVal = yBuffer.get(yRow + x).toInt() and 0xFF
				val uCol = (x / 2) * uPixelStride
				val vCol = (x / 2) * vPixelStride
				val uVal = (uBuffer.get(uvRow + uCol).toInt() and 0xFF) - 128
				val vVal = (vBuffer.get(vvRow + vCol).toInt() and 0xFF) - 128

				val r = yVal + 1.402f * vVal
				val g = yVal - 0.344136f * uVal - 0.714136f * vVal
				val b = yVal + 1.772f * uVal

				rgba[dst++] = clampToByte(r)
				rgba[dst++] = clampToByte(g)
				rgba[dst++] = clampToByte(b)
				rgba[dst++] = 0xFF.toByte()
			}
		}

		return rgba
	}

	private fun clampToByte(value: Float): Byte =
		value.coerceIn(0f, 255f).toInt().toByte()
}
