package com.godot.game.video

import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import org.godotengine.godot.Dictionary
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max

private const val TAG = "KotlinVideoDecoder"
// MIME defaults to H.264 (`video/avc`); HEVC feeds switch to `video/hevc` via
// the codec-aware `start_decoder_with_codec` overload. The active value is
// captured per-instance in `configuredMime` so a reconfigure between codecs
// (e.g. the descriptor flips a feed to HEVC) picks the right MediaCodec.
private const val MIME_AVC = "video/avc"
private const val MIME_HEVC = "video/hevc"
private const val QUEUE_CAPACITY = 2
private const val INPUT_TIMEOUT_US = 10_000L
private const val TIMING_MAP_MAX_AGE_NS = 10_000_000_000L

private data class FrameData(
	val width: Int,
	val height: Int,
	val decodedNs: Long,
	val rgba: ByteArray,
	val yPlane: ByteArray = ByteArray(0),
	val uPlane: ByteArray = ByteArray(0),
	val vPlane: ByteArray = ByteArray(0),
)

private data class AccessUnit(
	val bytes: ByteArray,
	val receiveNs: Long,
	val sendNs: Long,
	val clockOffsetNs: Long,
	val clockSamples: Int,
)

private data class AccessUnitTiming(
	val receiveNs: Long,
	val sendNsXr: Long,
	val queuedNs: Long,
)

@Suppress("DEPRECATION")
class KotlinVideoDecoderPlugin(private val host: Godot) : GodotPlugin(host) {
	companion object {
		// [plan B] Optional libahb_decoder.so — the Vulkan AHardwareBuffer
		// import GDExtension. When present, drainOutput pushes the
		// MediaCodec output Image's HardwareBuffer through nativeImportAhb
		// instead of (or in addition to) the YUV plane copy path. When
		// absent, we silently stay on plan B's 3-plane upload.
		//
		// [issue 005 follow-up] Sampling AHB-imported VK_FORMAT_UNDEFINED
		// images requires a VkSamplerYcbcrConversion-aware immutable
		// sampler in the descriptor set layout — Godot's standard
		// `sampler2D` shader binding does NOT have one. So the AHB path
		// imports the buffer correctly but the fragment shader samples
		// black. Until we either (a) wire YCbCr conversion through the
		// RenderingDevice API or (b) add a Vulkan compute pass that
		// blits AHB → RGBA, we let the operator force-disable AHB via:
		//   adb shell setprop debug.xrobo.force_yuv_plane 1
		// which falls back to Plan B's CPU plane copy + 3 L8 textures
		// + GPU YUV->RGB shader (proven to display real frames).
		private val ahbNativeAvailable: Boolean = run {
			val forceYuv = readSystemProp("debug.xrobo.force_yuv_plane") == "1"
			if (forceYuv) {
				Log.i(TAG, "debug.xrobo.force_yuv_plane=1 — disabling AHB path, " +
					"using YUV plane upload (visible video, no zero-copy)")
				return@run false
			}
			try {
				System.loadLibrary("ahb_decoder")
				Log.i(TAG, "libahb_decoder.so loaded; AHB import path available " +
					"(set debug.xrobo.force_yuv_plane=1 to fall back to YUV plane upload)")
				true
			} catch (e: UnsatisfiedLinkError) {
				Log.i(TAG, "libahb_decoder.so not present, staying on plan B plane copy")
				false
			}
		}

		// Read an Android system property without depending on the
		// (hidden) android.os.SystemProperties API directly — reflection
		// keeps us out of the @hide allow-list bookkeeping.
		private fun readSystemProp(key: String): String {
			return try {
				val cls = Class.forName("android.os.SystemProperties")
				val m = cls.getMethod("get", String::class.java)
				(m.invoke(null, key) as? String) ?: ""
			} catch (t: Throwable) {
				""
			}
		}

		// JNI entry point implemented in xr/native/ahb_decoder/src/jni_bridge.cpp.
		// Marked @JvmStatic external so the symbol matches the
		// Java_com_godot_game_video_KotlinVideoDecoderPlugin_nativeImportAhb signature.
		@JvmStatic
		external fun nativeImportAhb(buffer: android.hardware.HardwareBuffer, decodedNs: Long)
	}

		private val running = AtomicBoolean(false)
		private val accessUnitQueue = LinkedBlockingQueue<AccessUnit>(QUEUE_CAPACITY)
		private val timingByPtsUs = ConcurrentHashMap<Long, AccessUnitTiming>()
		private val ahbLatencyLock = Object()
		private var ahbLatencyCount = 0
		private var ahbLatencySumMs = 0.0
		private var ahbLatencyMinMs = Double.POSITIVE_INFINITY
		private var ahbLatencyMaxMs = 0.0
		private var ahbBridgeLatencyCount = 0
		private var ahbBridgeLatencySumMs = 0.0
		private var ahbBridgeLatencyMinMs = Double.POSITIVE_INFINITY
		private var ahbBridgeLatencyMaxMs = 0.0
		private var ahbLastStatsSeq = 0L
		private var ahbLastStatsNs = 0L
		private var ahbLastImportFrames = 0L
		private var ahbLastImportWindowMs = 0.0
		private var ahbLastImportFps = 0.0
		private var ahbLastRxCount = 0
		private var ahbLastRxAvgMs = Double.NaN
		private var ahbLastRxMinMs = Double.NaN
		private var ahbLastRxMaxMs = Double.NaN
		private var ahbLastBridgeCount = 0
		private var ahbLastBridgeAvgMs = Double.NaN
		private var ahbLastBridgeMinMs = Double.NaN
		private var ahbLastBridgeMaxMs = Double.NaN
		private val epochOffsetNs =
			System.currentTimeMillis() * 1_000_000L - SystemClock.elapsedRealtimeNanos()

	@Volatile
	private var decoderThread: Thread? = null

	@Volatile
	private var codec: MediaCodec? = null

	// [issue 005 / D-6] Surface-mode plumbing — the chosen "decoded
	// frame to GPU without a CPU copy" route. When ahbNativeAvailable
	// is true we configure MediaCodec to render decoded frames into an
	// ImageReader's Surface. The ImageReader's onImageAvailable
	// callback picks up the resulting AHardwareBuffer and hands it
	// straight to native via nativeImportAhb — no CPU copy, no JNI
	// byte transfer, no GDScript hop. ByteBuffer mode (the legacy YUV
	// plane copy path) is the documented fallback when the AHB
	// GDExtension didn't load.
	//
	// We deliberately do NOT use OES/SurfaceTexture: that path can't
	// surface the underlying AHardwareBuffer to Vulkan, and Godot's
	// renderer is Vulkan on Pico. See `xr/native/ahb_decoder/README.md`.
	@Volatile
	private var imageReader: ImageReader? = null

	@Volatile
	private var imageReaderThread: HandlerThread? = null

	@Volatile
	private var surfaceMode: Boolean = false

	// Per-frame timing breadcrumbs so we can quantify the AHB win vs the
	// Plan-B baseline. Sampled once per second by a tiny rate-limited
	// Log.i to avoid drowning logcat at 30 fps.
	private val ahbFrameCounter = AtomicLong(0)
	private val ahbLastReportNs = AtomicLong(0)

	@Volatile
	private var latestFrame: FrameData? = null

	@Volatile
	private var configuredWidth: Int = 0

	@Volatile
	private var configuredHeight: Int = 0

	// Active codec MIME — set by `start_decoder_with_codec` and consulted by
	// `configureCodec` (picks `createDecoderByType`) and the csd extraction
	// (HEVC needs VPS+SPS+PPS concatenated in csd-0; H.264 splits SPS into
	// csd-0 and PPS into csd-1). Defaults to H.264 so the legacy 2-arg
	// `start_decoder(w, h)` keeps working unchanged.
	@Volatile
	private var configuredMime: String = MIME_AVC

	private val streamSessions = ConcurrentHashMap<String, StreamDecoderSession>()

	override fun getPluginName(): String = "KotlinVideoDecoderPlugin"

	override fun getPluginMethods(): MutableList<String> =
		mutableListOf(
			"start_decoder",
			"start_decoder_with_codec",
			"stop_decoder",
			"is_running",
			"submit_access_unit",
			"submit_access_unit_timed",
			"submit_access_unit_timed_with_clock",
			"start_decoder_with_codec_for_stream",
			"stop_decoder_for_stream",
			"is_running_for_stream",
			"submit_access_unit_timed_with_clock_for_stream",
			"get_latest_frame",
			"get_ahb_latency_stats",
			"probe_hardware_buffer_support",
		)

	override fun getPluginSignals(): MutableSet<SignalInfo> =
		mutableSetOf(
			// Legacy RGBA frame signal (kept so the placeholder/no-GPU
			// fallback in robot_view.gd still works on devices where the
			// 3-plane YUV path can't be set up for some reason).
			SignalInfo(
				"frame_ready",
				Int::class.javaObjectType,
				Int::class.javaObjectType,
				Long::class.javaObjectType,
				ByteArray::class.java,
			),
			// Plan B: GPU YUV->RGB. We hand the three tightly-packed
			// planes to GDScript which uploads them as L8 textures and
			// lets the fragment shader do the colour conversion.
			SignalInfo(
				"yuv_frame_ready",
				Int::class.javaObjectType,        // width
				Int::class.javaObjectType,        // height
				Long::class.javaObjectType,       // decoded_ns
				ByteArray::class.java,            // y plane (w*h bytes)
				ByteArray::class.java,            // u plane (w/2 * h/2 bytes)
				ByteArray::class.java,            // v plane (w/2 * h/2 bytes)
			),
			SignalInfo("decoder_error", String::class.java),
			SignalInfo(
				"frame_ready_for_stream",
				String::class.java,
				Int::class.javaObjectType,
				Int::class.javaObjectType,
				Long::class.javaObjectType,
				ByteArray::class.java,
			),
			SignalInfo(
				"yuv_frame_ready_for_stream",
				String::class.java,
				Int::class.javaObjectType,
				Int::class.javaObjectType,
				Long::class.javaObjectType,
				ByteArray::class.java,
				ByteArray::class.java,
				ByteArray::class.java,
			),
			SignalInfo("decoder_error_for_stream", String::class.java, String::class.java),
		)

	@Suppress("DEPRECATION")
	override fun onMainDestroy() {
		super.onMainDestroy()
		stop_decoder()
		stopAllStreamSessions()
	}

	@Suppress("FunctionName")
	@UsedByGodot
	fun start_decoder(width: Int, height: Int): Boolean {
		// Legacy 2-arg call site (pre-codec descriptor). Default to H.264 to
		// preserve historical behaviour; new callers use the 3-arg overload.
		return start_decoder_with_codec(width, height, "h264")
	}

	/// Codec-aware variant. `codec` accepts "h264" (a.k.a. avc) and "hevc"
	/// (a.k.a. h265, x265); anything else falls back to H.264 — we'd rather
	/// degrade to a noisy decode failure than silently spin up the wrong
	/// MediaCodec. Exposed with an underscore name (and @UsedByGodot) so
	/// Godot's reflection picks it up regardless of Kotlin name mangling.
	@Suppress("FunctionName")
	@UsedByGodot
	fun start_decoder_with_codec(width: Int, height: Int, codec: String): Boolean {
		val mime = when (codec.lowercase()) {
			"hevc", "h265", "x265" -> MIME_HEVC
			else -> MIME_AVC
		}

		if (running.get()) {
			if (configuredWidth == width && configuredHeight == height && configuredMime == mime) {
				return true
			}
			stop_decoder()
		}

		if (width <= 0 || height <= 0) {
			Log.w(TAG, "start_decoder rejected invalid size ${width}x$height")
			return false
		}

			configuredWidth = width
			configuredHeight = height
			configuredMime = mime
			latestFrame = null
			accessUnitQueue.clear()
			timingByPtsUs.clear()
			resetAhbLatencyStats()
			running.set(true)

		val worker =
			Thread({
				runDecoderLoop()
			}, "xrVideoDecoderThread")
		decoderThread = worker
		worker.start()

		Log.i(TAG, "Decoder started for ${width}x${height} mime=$mime")
		return true
	}

	@Suppress("FunctionName")
	@UsedByGodot
	fun stop_decoder() {
			running.set(false)
			accessUnitQueue.clear()
			timingByPtsUs.clear()
			resetAhbLatencyStats()
			decoderThread?.interrupt()
		decoderThread?.join(1000)
		decoderThread = null

		releaseCodec()
		latestFrame = null
		Log.i(TAG, "Decoder stopped")
	}

	@Suppress("FunctionName")
	@UsedByGodot
	fun is_running(): Boolean = running.get()

		@Suppress("FunctionName")
		@UsedByGodot
		fun submit_access_unit(access_unit: ByteArray): Boolean {
			return offerAccessUnit(access_unit, nowNs(), 0L, 0L, 0)
		}

		@Suppress("FunctionName")
		@UsedByGodot
		fun submit_access_unit_timed(access_unit: ByteArray, receiveNs: Long, sendNs: Long): Boolean {
			return offerAccessUnit(access_unit, receiveNs, sendNs, 0L, if (sendNs > 0L) 1 else 0)
		}

		@Suppress("FunctionName")
		@UsedByGodot
		fun submit_access_unit_timed_with_clock(
			access_unit: ByteArray,
			receiveNs: Long,
			sendNs: Long,
			clockOffsetNs: Long,
			clockSamples: Int,
		): Boolean {
			return offerAccessUnit(access_unit, receiveNs, sendNs, clockOffsetNs, clockSamples)
		}

		@Suppress("FunctionName")
		@UsedByGodot
		fun start_decoder_with_codec_for_stream(
			streamId: String,
			width: Int,
			height: Int,
			codec: String,
		): Boolean {
			if (streamId.isBlank()) {
				return start_decoder_with_codec(width, height, codec)
			}
			val session = streamSessions.computeIfAbsent(streamId) { StreamDecoderSession(it) }
			return session.start(width, height, codec)
		}

		@Suppress("FunctionName")
		@UsedByGodot
		fun stop_decoder_for_stream(streamId: String) {
			if (streamId.isBlank()) {
				stop_decoder()
				return
			}
			streamSessions.remove(streamId)?.stop()
		}

		@Suppress("FunctionName")
		@UsedByGodot
		fun is_running_for_stream(streamId: String): Boolean {
			if (streamId.isBlank()) {
				return is_running()
			}
			return streamSessions[streamId]?.isRunning() ?: false
		}

		@Suppress("FunctionName")
		@UsedByGodot
		fun submit_access_unit_timed_with_clock_for_stream(
			streamId: String,
			accessUnit: ByteArray,
			receiveNs: Long,
			sendNs: Long,
			clockOffsetNs: Long,
			clockSamples: Int,
		): Boolean {
			if (streamId.isBlank()) {
				return submit_access_unit_timed_with_clock(
					accessUnit,
					receiveNs,
					sendNs,
					clockOffsetNs,
					clockSamples,
				)
			}
			return streamSessions[streamId]?.offer(
				accessUnit,
				receiveNs,
				sendNs,
				clockOffsetNs,
				clockSamples,
			) ?: false
		}

		private fun offerAccessUnit(
			access_unit: ByteArray,
			receiveNs: Long,
			sendNs: Long,
			clockOffsetNs: Long,
			clockSamples: Int,
		): Boolean {
			if (!running.get()) {
				return false
			}
			if (access_unit.isEmpty()) {
				return false
			}
			val accepted = accessUnitQueue.offer(
				AccessUnit(
					bytes = access_unit.clone(),
					receiveNs = receiveNs,
					sendNs = sendNs,
					clockOffsetNs = clockOffsetNs,
					clockSamples = clockSamples,
				)
			)
			if (!accepted) {
				Log.w(TAG, "Decoder queue full, dropping access unit")
				return false
			}
			return true
	}

	private fun stopAllStreamSessions() {
		val sessions = streamSessions.values.toList()
		streamSessions.clear()
		for (session in sessions) {
			session.stop()
		}
	}

	@Suppress("FunctionName")
	@UsedByGodot
	fun get_latest_frame(): Dictionary {
		val dict = Dictionary()
		val frame = latestFrame ?: return dict
		dict["width"] = frame.width
		dict["height"] = frame.height
		dict["timestamp_ns"] = frame.decodedNs
		dict["decoded_ns"] = frame.decodedNs
		dict["rgba"] = frame.rgba
		// Plan B: also expose YUV planes when present so the GDScript
		// fallback path (used when the deferred signal hasn't fired yet)
		// can prefer the GPU YUV path too.
		if (frame.yPlane.isNotEmpty()) {
			dict["y_plane"] = frame.yPlane
			dict["u_plane"] = frame.uPlane
			dict["v_plane"] = frame.vPlane
		}
		return dict
	}

	@Suppress("FunctionName")
	@UsedByGodot
	fun get_ahb_latency_stats(): Dictionary {
		val dict = Dictionary()
		synchronized(ahbLatencyLock) {
			if (ahbLastStatsSeq <= 0L) {
				return dict
			}
			dict["seq"] = ahbLastStatsSeq
			dict["reported_ns"] = ahbLastStatsNs
			dict["import_frames"] = ahbLastImportFrames
			dict["import_window_ms"] = ahbLastImportWindowMs
			dict["import_fps"] = ahbLastImportFps
			dict["rx_to_ahb_count"] = ahbLastRxCount
			dict["rx_to_ahb_avg_ms"] = ahbLastRxAvgMs
			dict["rx_to_ahb_min_ms"] = ahbLastRxMinMs
			dict["rx_to_ahb_max_ms"] = ahbLastRxMaxMs
			dict["bridge_to_ahb_count"] = ahbLastBridgeCount
			dict["bridge_to_ahb_avg_ms"] = ahbLastBridgeAvgMs
			dict["bridge_to_ahb_min_ms"] = ahbLastBridgeMinMs
			dict["bridge_to_ahb_max_ms"] = ahbLastBridgeMaxMs
			dict["timing_map"] = timingByPtsUs.size
		}
		return dict
	}

	/// [issue 005 / D-6] Probe whether `Image.getHardwareBuffer()`
	/// returns a usable buffer on the next decoded frame. The full
	/// Vulkan AHB import path is wired up via libahb_decoder.so when
	/// it's present in the APK; this probe is for GDScript to gate
	/// "should I use the AHB texture or stay on plane upload" without
	/// needing to call into native first.
	@Suppress("FunctionName")
	@UsedByGodot
	fun probe_hardware_buffer_support(): String {
		// API 28+ for Image.getHardwareBuffer(); swan is well above.
		// We return a human-readable status string instead of a bool
		// so logs are self-explanatory.
		val codecLocal = codec
			?: return "no-codec"
		return try {
			// Try to dequeue an output buffer (non-blocking) and get
			// its AHB. Don't disturb the regular decode loop — just
			// peek at internal state via reflection-free APIs.
			val info = android.media.MediaCodec.BufferInfo()
			val idx = codecLocal.dequeueOutputBuffer(info, 0)
			if (idx < 0) return "no-output-frame-available"
			val image = codecLocal.getOutputImage(idx)
				?: return "no-image"
			try {
				val ahb = image.hardwareBuffer
					?: return "image-has-no-hardware-buffer"
				val msg = "ahb-ok format=${ahb.format} usage=${ahb.usage} " +
					"size=${ahb.width}x${ahb.height}"
				ahb.close()
				msg
			} finally {
				try { image.close() } catch (_: Exception) {}
				try { codecLocal.releaseOutputBuffer(idx, false) } catch (_: Exception) {}
			}
		} catch (e: Throwable) {
			"probe-failed: ${e.message}"
		}
	}

	private fun runDecoderLoop() {
		// [issue 005 / D-6] Synchronous polling is the final design.
		// History: [opt 8] tried async MediaCodec.Callback (HandlerThread
		// + setCallback) but onOutputBufferAvailable never fired on
		// swan — input slots were consumed but output stayed silent —
		// freezing the pipeline. Sync polling adds ~20 ms scheduling
		// latency at worst, comfortably inside our motion-to-photons
		// budget. The OES SurfaceTexture path was the previous
		// "Surface output" idea; it is fully superseded by the
		// ImageReader → AHardwareBuffer route below (configureCodec)
		// because OES textures don't expose the underlying
		// AHardwareBuffer that the Vulkan zero-copy path needs.
		//
		// Trip-wire: revisit async on a new device family (Quest 4,
		// non-Snapdragon) where the codec/driver may behave; the
		// scaffolding (codecHandlerThread field) was kept clean so a
		// re-attempt only needs to wire setCallback() back in.
			var pendingAccessUnit: AccessUnit? = null

		try {
			while (running.get() && !Thread.currentThread().isInterrupted) {
				if (pendingAccessUnit == null) {
					pendingAccessUnit = accessUnitQueue.poll(20, TimeUnit.MILLISECONDS)
				}

					val codecLocal = codec
					if (pendingAccessUnit != null && codecLocal == null) {
						if (!configureCodec(pendingAccessUnit!!.bytes)) {
							running.set(false)
							break
						}
				}

				val activeCodec = codec ?: continue

				if (pendingAccessUnit != null) {
					val inputIndex = activeCodec.dequeueInputBuffer(INPUT_TIMEOUT_US)
					if (inputIndex >= 0) {
						val inputBuffer = activeCodec.getInputBuffer(inputIndex)
						if (inputBuffer == null) {
							emitSignal("decoder_error", "Decoder input buffer unavailable")
							running.set(false)
							break
							}
							inputBuffer.clear()
							inputBuffer.put(pendingAccessUnit!!.bytes)
							val queuedNs = nowNs()
							val receiveNs = pendingAccessUnit!!.receiveNs
							val ptsUs = if (receiveNs > 0L) receiveNs / 1_000L else queuedNs / 1_000L
							activeCodec.queueInputBuffer(
								inputIndex,
								0,
								pendingAccessUnit!!.bytes.size,
								ptsUs,
								0,
							)
							if (receiveNs > 0L) {
								val sendNsXr =
									if (pendingAccessUnit!!.clockSamples > 0 && pendingAccessUnit!!.sendNs > 0L) {
										pendingAccessUnit!!.sendNs - pendingAccessUnit!!.clockOffsetNs
									} else {
										0L
									}
								timingByPtsUs[ptsUs] = AccessUnitTiming(
									receiveNs = receiveNs,
									sendNsXr = sendNsXr,
									queuedNs = queuedNs,
								)
								pruneTimingMap(queuedNs)
							}
							pendingAccessUnit = null
						}
					}

				drainOutput(activeCodec)
			}
		} catch (e: InterruptedException) {
			Thread.currentThread().interrupt()
		} catch (e: Exception) {
			Log.e(TAG, "Decoder loop failed", e)
			emitSignal("decoder_error", "Decoder loop failed: ${e.message}")
		} finally {
			releaseCodec()
		}
	}

	@Volatile
	private var codecHandlerThread: HandlerThread? = null

	private fun configureCodec(firstAccessUnit: ByteArray): Boolean {
		return try {
			val mime = configuredMime
			val format = MediaFormat.createVideoFormat(mime, configuredWidth, configuredHeight)
			format.setInteger(
				MediaFormat.KEY_MAX_INPUT_SIZE,
				max(1_048_576, configuredWidth * configuredHeight * 2),
			)
			// [opt 8 fix] On Adreno c2.qti.avc.decoder, the SPS's VUI
			// `bitstream_restriction` block is the only signal that tells
			// the decoder how many frames it can buffer for reordering. When
			// the encoder doesn't write that block (libx264 with bframes=0
			// notably doesn't), the codec falls back to the level's max DPB
			// (14 for level 4.x at 720p) and stalls output until 14 frames
			// have been decoded. That looks like "no video, decoder queue
			// full" with zero output buffers. KEY_LOW_LATENCY tells the
			// codec to drop all reorder buffering and emit each decoded
			// frame immediately — safe for our pipeline because we never
			// send B-frames either way. Added in API 30 (Android 11) so
			// gated by Build.VERSION check.
			if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
				format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
			}
			// Codec-specific data layout differs by family:
			//   H.264: csd-0 = SPS, csd-1 = PPS (separate buffers).
			//   H.265: csd-0 = VPS || SPS || PPS concatenated as Annex-B NALs in
			//          one buffer; no csd-1.
			var csdDesc = "none"
			if (mime == MIME_HEVC) {
				val concatenated = extractHevcCodecSpecificData(firstAccessUnit)
				if (concatenated != null) {
					format.setByteBuffer("csd-0", ByteBuffer.wrap(concatenated))
					csdDesc = "vps+sps+pps(${concatenated.size}B)"
				}
			} else {
				val (sps, pps) = extractCodecSpecificData(firstAccessUnit)
				if (sps != null) {
					format.setByteBuffer("csd-0", ByteBuffer.wrap(sps))
				}
				if (pps != null) {
					format.setByteBuffer("csd-1", ByteBuffer.wrap(pps))
				}
				csdDesc = "sps=${sps != null}/pps=${pps != null}"
			}
			val createdCodec = MediaCodec.createDecoderByType(mime)

			// Surface-output path: only enable when libahb_decoder.so is
			// loaded, otherwise we'd lose the YUV plane copy that the
			// shader fallback needs. We use ImageFormat.PRIVATE +
			// USAGE_GPU_SAMPLED_IMAGE so the underlying gralloc allocates
			// an opaque GPU-sampled AHardwareBuffer that Vulkan can
				// import via VK_ANDROID_external_memory_android_hardware_buffer
				// (handled in C++ AhbVideoTexture::_import_buffer). Keep
				// maxImages at 2 so acquireLatestImage() can discard stale frames
				// while limiting the Surface/BufferQueue latency budget.
			val outSurface: Surface? = if (ahbNativeAvailable) {
				val ht = HandlerThread("xrImageReaderThread").also { it.start() }
				val handler = Handler(ht.looper)
				val ir = ImageReader.newInstance(
					configuredWidth,
					configuredHeight,
					ImageFormat.PRIVATE,
					QUEUE_CAPACITY,
					HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
				)
				ir.setOnImageAvailableListener(
					object : ImageReader.OnImageAvailableListener {
						override fun onImageAvailable(reader: ImageReader) {
							onAhbImageAvailable(reader)
						}
					},
					handler,
				)
				imageReader = ir
				imageReaderThread = ht
				surfaceMode = true
				ir.surface
			} else {
				surfaceMode = false
				null
			}

			createdCodec.configure(format, outSurface, null, 0)
			createdCodec.start()
			codec = createdCodec
			Log.i(
				TAG,
				"Decoder configured ${configuredWidth}x${configuredHeight} " +
					"mime=$mime csd=$csdDesc surfaceMode=$surfaceMode"
			)
			true
		} catch (e: Exception) {
			Log.e(TAG, "Failed to configure MediaCodec", e)
			emitSignal("decoder_error", "Failed to configure decoder: ${e.message}")
			false
		}
	}

	/**
	 * ImageReader callback (runs on the xrImageReaderThread). Acquires
	 * the latest AHardwareBuffer from the queue and hands it to native
	 * via nativeImportAhb. We use acquireLatestImage() not acquireNext()
	 * so if the renderer is briefly stalled we discard intermediate
	 * frames — matches the existing "drop stale, deliver newest" policy
	 * in the rest of the pipeline.
	 */
	private fun onAhbImageAvailable(reader: ImageReader) {
		val image: Image = try {
			reader.acquireLatestImage() ?: return
		} catch (t: Throwable) {
			Log.w(TAG, "acquireLatestImage threw: ${t.message}")
			return
		}
		try {
			val ahb = try {
				image.hardwareBuffer
			} catch (t: Throwable) {
				Log.w(TAG, "Image.getHardwareBuffer threw: ${t.message}")
				null
			}
			if (ahb == null) {
				return
			}
				val nowNsCached = nowNs()
				val imageTimestampNs = try {
					image.timestamp
				} catch (_: Throwable) {
					0L
				}
				if (imageTimestampNs > 0L) {
					val timing = timingByPtsUs.remove(imageTimestampNs / 1_000L)
					if (timing != null && timing.receiveNs > 0L && nowNsCached >= timing.receiveNs) {
						val bridgeToAhbMs =
							if (timing.sendNsXr > 0L && timing.receiveNs >= timing.sendNsXr && nowNsCached >= timing.sendNsXr) {
								(nowNsCached - timing.sendNsXr) / 1_000_000.0
							} else {
								Double.NaN
							}
						recordAhbLatency(
							(nowNsCached - timing.receiveNs) / 1_000_000.0,
							bridgeToAhbMs,
						)
					}
				}
				try {
					nativeImportAhb(ahb, nowNsCached)
					latestFrame = FrameData(
					width = image.width,
					height = image.height,
					decodedNs = nowNsCached,
					rgba = ByteArray(0),
				)
				val n = ahbFrameCounter.incrementAndGet()
				val last = ahbLastReportNs.get()
				if (last == 0L) {
					ahbLastReportNs.compareAndSet(0L, nowNsCached)
				} else if (nowNsCached - last >= 1_000_000_000L) {
					if (ahbLastReportNs.compareAndSet(last, nowNsCached)) {
							val dtMs = (nowNsCached - last) / 1_000_000.0
							val fps = n.toDouble() * 1000.0 / dtMs
							Log.i(TAG, "AHB import: $n frames in %.0f ms (~%.1f fps)".format(dtMs, fps))
							reportAhbLatencyStats(nowNsCached, n, dtMs, fps)
							ahbFrameCounter.set(0)
						}
					}
			} catch (t: Throwable) {
				Log.w(TAG, "nativeImportAhb threw: ${t.message}")
			} finally {
				try { ahb.close() } catch (_: Throwable) {}
			}
		} finally {
			try { image.close() } catch (_: Throwable) {}
		}
	}

	@Suppress("DEPRECATION")
	private fun drainOutput(codec: MediaCodec) {
		val info = MediaCodec.BufferInfo()
		val isSurface = surfaceMode
		while (running.get()) {
			val outputIndex = codec.dequeueOutputBuffer(info, 0)
			when {
				outputIndex >= 0 -> {
					if (isSurface) {
						// Render-to-surface fast path. releaseOutputBuffer(idx, true)
						// hands the decoded frame to the ImageReader's surface; the
						// real work (AHB acquire + nativeImportAhb) happens off-thread
						// in onAhbImageAvailable() above. This loop only has to drain
						// the codec's output queue fast enough to keep up with input.
						try {
							codec.releaseOutputBuffer(outputIndex, true)
						} catch (e: Exception) {
							Log.w(TAG, "releaseOutputBuffer(render) threw: ${e.message}")
						}
					} else {
						drainOutputByteBufferMode(codec, outputIndex)
					}
				}
				outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
					Log.i(TAG, "Decoder output format changed: ${codec.outputFormat}")
				}
				outputIndex == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> {
					// Ignored on modern codecs.
				}
				outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> return
				else -> return
			}
		}
	}

	/**
	 * Legacy ByteBuffer-mode output path for devices/builds where
	 * libahb_decoder.so didn't load. Reads the YUV planes via Image
	 * and either uploads them as 3 L8 textures (Plan B fast path) or,
	 * if even that fails, does a CPU YUV->RGB conversion (slow). With
	 * the AHB GDExtension shipped this path is a safety net only.
	 */
	@Suppress("DEPRECATION")
	private fun drainOutputByteBufferMode(codec: MediaCodec, outputIndex: Int) {
		val image = try {
			codec.getOutputImage(outputIndex)
		} catch (_: Exception) {
			null
		}
		try {
			if (image != null) {
				val nowNsCached = nowNs()
				val planes = extractYuvPlanesTight(image)
				if (planes != null) {
					latestFrame = FrameData(
						width = image.width,
						height = image.height,
						decodedNs = nowNsCached,
						rgba = ByteArray(0),
						yPlane = planes.first,
						uPlane = planes.second,
						vPlane = planes.third,
					)
					emitSignal(
						"yuv_frame_ready",
						image.width,
						image.height,
						nowNsCached,
						planes.first,
						planes.second,
						planes.third,
					)
				} else {
					val rgba = convertToRgbaCpu(image)
					if (rgba.isNotEmpty()) {
						latestFrame = FrameData(
							width = image.width,
							height = image.height,
							decodedNs = nowNsCached,
							rgba = rgba,
						)
						emitSignal("frame_ready", image.width, image.height, nowNsCached, rgba)
					}
				}
			}
		} finally {
			try { image?.close() } catch (_: Exception) {}
			try { codec.releaseOutputBuffer(outputIndex, false) } catch (_: Exception) {}
		}
	}

	private fun releaseCodec() {
		val localCodec = codec
		codec = null
		if (localCodec != null) {
			try {
				localCodec.stop()
			} catch (_: Exception) {}
			try {
				localCodec.release()
			} catch (_: Exception) {}
		}

		// Tear down the surface-mode chain in the same order it was built:
		// the ImageReader holds the Surface that the codec was rendering
		// into, so it must outlive the codec.stop() call above.
		val ir = imageReader
		imageReader = null
		if (ir != null) {
			try { ir.close() } catch (_: Exception) {}
		}
		val irThread = imageReaderThread
		imageReaderThread = null
		if (irThread != null) {
			try { irThread.quitSafely() } catch (_: Exception) {}
		}
			surfaceMode = false
			ahbFrameCounter.set(0)
			ahbLastReportNs.set(0)
			timingByPtsUs.clear()
			resetAhbLatencyStats()

		// Reserved: cleanup hook for a future async-mode HandlerThread.
		// Currently unused — sync polling stays. See [issue 005 / D-6].
		val ht = codecHandlerThread
		codecHandlerThread = null
		if (ht != null) {
			try { ht.quitSafely() } catch (_: Exception) {}
		}
	}

		private fun nowNs(): Long = SystemClock.elapsedRealtimeNanos() + epochOffsetNs

		private fun pruneTimingMap(nowNsValue: Long) {
			if (timingByPtsUs.size < 256) {
				return
			}
			val cutoff = nowNsValue - TIMING_MAP_MAX_AGE_NS
			for ((ptsUs, timing) in timingByPtsUs.entries) {
				if (timing.queuedNs < cutoff) {
					timingByPtsUs.remove(ptsUs)
				}
			}
		}

		private fun resetAhbLatencyStats() {
			synchronized(ahbLatencyLock) {
				ahbLatencyCount = 0
				ahbLatencySumMs = 0.0
				ahbLatencyMinMs = Double.POSITIVE_INFINITY
				ahbLatencyMaxMs = 0.0
				ahbBridgeLatencyCount = 0
				ahbBridgeLatencySumMs = 0.0
				ahbBridgeLatencyMinMs = Double.POSITIVE_INFINITY
				ahbBridgeLatencyMaxMs = 0.0
				ahbLastStatsSeq = 0L
				ahbLastStatsNs = 0L
				ahbLastImportFrames = 0L
				ahbLastImportWindowMs = 0.0
				ahbLastImportFps = 0.0
				ahbLastRxCount = 0
				ahbLastRxAvgMs = Double.NaN
				ahbLastRxMinMs = Double.NaN
				ahbLastRxMaxMs = Double.NaN
				ahbLastBridgeCount = 0
				ahbLastBridgeAvgMs = Double.NaN
				ahbLastBridgeMinMs = Double.NaN
				ahbLastBridgeMaxMs = Double.NaN
			}
		}

		private fun recordAhbLatency(rxToAhbMs: Double, bridgeToAhbMs: Double) {
			synchronized(ahbLatencyLock) {
				ahbLatencyCount += 1
				ahbLatencySumMs += rxToAhbMs
				if (rxToAhbMs < ahbLatencyMinMs) {
					ahbLatencyMinMs = rxToAhbMs
				}
				if (rxToAhbMs > ahbLatencyMaxMs) {
					ahbLatencyMaxMs = rxToAhbMs
				}
				if (!bridgeToAhbMs.isNaN()) {
					ahbBridgeLatencyCount += 1
					ahbBridgeLatencySumMs += bridgeToAhbMs
					if (bridgeToAhbMs < ahbBridgeLatencyMinMs) {
						ahbBridgeLatencyMinMs = bridgeToAhbMs
					}
					if (bridgeToAhbMs > ahbBridgeLatencyMaxMs) {
						ahbBridgeLatencyMaxMs = bridgeToAhbMs
					}
				}
			}
		}

		private fun reportAhbLatencyStats(reportNs: Long, importFrames: Long, importWindowMs: Double, importFps: Double) {
			synchronized(ahbLatencyLock) {
				ahbLastStatsSeq += 1
				ahbLastStatsNs = reportNs
				ahbLastImportFrames = importFrames
				ahbLastImportWindowMs = importWindowMs
				ahbLastImportFps = importFps
				if (ahbLatencyCount <= 0) {
					ahbLastRxCount = 0
					ahbLastRxAvgMs = Double.NaN
					ahbLastRxMinMs = Double.NaN
					ahbLastRxMaxMs = Double.NaN
					ahbLastBridgeCount = 0
					ahbLastBridgeAvgMs = Double.NaN
					ahbLastBridgeMinMs = Double.NaN
					ahbLastBridgeMaxMs = Double.NaN
					return
				}
				val avgMs = ahbLatencySumMs / ahbLatencyCount.toDouble()
				ahbLastRxCount = ahbLatencyCount
				ahbLastRxAvgMs = avgMs
				ahbLastRxMinMs = ahbLatencyMinMs
				ahbLastRxMaxMs = ahbLatencyMaxMs
				ahbLastBridgeCount = ahbBridgeLatencyCount
				if (ahbBridgeLatencyCount > 0) {
					ahbLastBridgeAvgMs = ahbBridgeLatencySumMs / ahbBridgeLatencyCount.toDouble()
					ahbLastBridgeMinMs = ahbBridgeLatencyMinMs
					ahbLastBridgeMaxMs = ahbBridgeLatencyMaxMs
				} else {
					ahbLastBridgeAvgMs = Double.NaN
					ahbLastBridgeMinMs = Double.NaN
					ahbLastBridgeMaxMs = Double.NaN
				}
				val bridgeStats =
					if (ahbBridgeLatencyCount > 0) {
						" bridge_to_ahb avg=%.1f ms min=%.1f ms max=%.1f ms count=%d".format(
							ahbLastBridgeAvgMs,
							ahbBridgeLatencyMinMs,
							ahbBridgeLatencyMaxMs,
							ahbBridgeLatencyCount,
						)
					} else {
						" bridge_to_ahb=--"
					}
				Log.i(
					TAG,
					"AHB latency rx_to_ahb avg=%.1f ms min=%.1f ms max=%.1f ms count=%d%s timing_map=%d".format(
						avgMs,
						ahbLatencyMinMs,
						ahbLatencyMaxMs,
						ahbLatencyCount,
						bridgeStats,
						timingByPtsUs.size,
					)
				)
				ahbLatencyCount = 0
				ahbLatencySumMs = 0.0
				ahbLatencyMinMs = Double.POSITIVE_INFINITY
				ahbLatencyMaxMs = 0.0
				ahbBridgeLatencyCount = 0
				ahbBridgeLatencySumMs = 0.0
				ahbBridgeLatencyMinMs = Double.POSITIVE_INFINITY
				ahbBridgeLatencyMaxMs = 0.0
			}
		}

	private inner class StreamDecoderSession(private val streamId: String) {
		private val sessionRunning = AtomicBoolean(false)
		private val sessionQueue = LinkedBlockingQueue<AccessUnit>(QUEUE_CAPACITY)

		@Volatile
		private var sessionThread: Thread? = null

		@Volatile
		private var sessionCodec: MediaCodec? = null

		@Volatile
		private var sessionWidth: Int = 0

		@Volatile
		private var sessionHeight: Int = 0

		@Volatile
		private var sessionMime: String = MIME_AVC

		fun start(width: Int, height: Int, codecName: String): Boolean {
			val mime = when (codecName.lowercase()) {
				"hevc", "h265", "x265" -> MIME_HEVC
				else -> MIME_AVC
			}

			if (sessionRunning.get()) {
				if (sessionWidth == width && sessionHeight == height && sessionMime == mime) {
					return true
				}
				stop()
			}

			if (width <= 0 || height <= 0) {
				Log.w(TAG, "stream=$streamId rejected invalid size ${width}x$height")
				return false
			}

			sessionWidth = width
			sessionHeight = height
			sessionMime = mime
			sessionQueue.clear()
			sessionRunning.set(true)

			val worker = Thread({ runLoop() }, "xrVideoDecoder-$streamId")
			sessionThread = worker
			worker.start()

			Log.i(TAG, "Stream decoder started stream=$streamId ${width}x${height} mime=$mime")
			return true
		}

		fun stop() {
			sessionRunning.set(false)
			sessionQueue.clear()
			sessionThread?.interrupt()
			sessionThread?.join(1000)
			sessionThread = null
			releaseCodec()
			Log.i(TAG, "Stream decoder stopped stream=$streamId")
		}

		fun isRunning(): Boolean = sessionRunning.get()

		fun offer(
			accessUnit: ByteArray,
			receiveNs: Long,
			sendNs: Long,
			clockOffsetNs: Long,
			clockSamples: Int,
		): Boolean {
			if (!sessionRunning.get() || accessUnit.isEmpty()) {
				return false
			}
			val accepted = sessionQueue.offer(
				AccessUnit(
					bytes = accessUnit.clone(),
					receiveNs = receiveNs,
					sendNs = sendNs,
					clockOffsetNs = clockOffsetNs,
					clockSamples = clockSamples,
				)
			)
			if (!accepted) {
				Log.w(TAG, "Stream decoder queue full, dropping access unit stream=$streamId")
				return false
			}
			return true
		}

		private fun runLoop() {
			var pendingAccessUnit: AccessUnit? = null
			try {
				while (sessionRunning.get() && !Thread.currentThread().isInterrupted) {
					if (pendingAccessUnit == null) {
						pendingAccessUnit = sessionQueue.poll(20, TimeUnit.MILLISECONDS)
					}

					if (pendingAccessUnit != null && sessionCodec == null) {
						if (!configureCodec(pendingAccessUnit.bytes)) {
							sessionRunning.set(false)
							break
						}
					}

					val activeCodec = sessionCodec ?: continue
					if (pendingAccessUnit != null) {
						val inputIndex = activeCodec.dequeueInputBuffer(INPUT_TIMEOUT_US)
						if (inputIndex >= 0) {
							val inputBuffer = activeCodec.getInputBuffer(inputIndex)
							if (inputBuffer == null) {
								emitError("Decoder input buffer unavailable")
								sessionRunning.set(false)
								break
							}
							inputBuffer.clear()
							inputBuffer.put(pendingAccessUnit.bytes)
							val receiveNs = pendingAccessUnit.receiveNs
							val ptsUs =
								if (receiveNs > 0L) receiveNs / 1_000L else nowNs() / 1_000L
							activeCodec.queueInputBuffer(
								inputIndex,
								0,
								pendingAccessUnit.bytes.size,
								ptsUs,
								0,
							)
							pendingAccessUnit = null
						}
					}

					drainOutput(activeCodec)
				}
			} catch (e: InterruptedException) {
				Thread.currentThread().interrupt()
			} catch (e: Exception) {
				Log.e(TAG, "Stream decoder loop failed stream=$streamId", e)
				emitError("Decoder loop failed: ${e.message}")
			} finally {
				releaseCodec()
			}
		}

		private fun configureCodec(firstAccessUnit: ByteArray): Boolean {
			return try {
				val format = MediaFormat.createVideoFormat(sessionMime, sessionWidth, sessionHeight)
				format.setInteger(
					MediaFormat.KEY_MAX_INPUT_SIZE,
					max(1_048_576, sessionWidth * sessionHeight * 2),
				)
				if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
					format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
				}

				var csdDesc = "none"
				if (sessionMime == MIME_HEVC) {
					val concatenated = extractHevcCodecSpecificData(firstAccessUnit)
					if (concatenated != null) {
						format.setByteBuffer("csd-0", ByteBuffer.wrap(concatenated))
						csdDesc = "vps+sps+pps(${concatenated.size}B)"
					}
				} else {
					val (sps, pps) = extractCodecSpecificData(firstAccessUnit)
					if (sps != null) {
						format.setByteBuffer("csd-0", ByteBuffer.wrap(sps))
					}
					if (pps != null) {
						format.setByteBuffer("csd-1", ByteBuffer.wrap(pps))
					}
					csdDesc = "sps=${sps != null}/pps=${pps != null}"
				}

				val createdCodec = MediaCodec.createDecoderByType(sessionMime)
				createdCodec.configure(format, null, null, 0)
				createdCodec.start()
				sessionCodec = createdCodec
				Log.i(
					TAG,
					"Stream decoder configured stream=$streamId ${sessionWidth}x${sessionHeight} " +
						"mime=$sessionMime csd=$csdDesc"
				)
				true
			} catch (e: Exception) {
				Log.e(TAG, "Failed to configure stream decoder stream=$streamId", e)
				emitError("Failed to configure decoder: ${e.message}")
				false
			}
		}

		private fun drainOutput(activeCodec: MediaCodec) {
			val info = MediaCodec.BufferInfo()
			while (sessionRunning.get()) {
				val outputIndex = activeCodec.dequeueOutputBuffer(info, 0)
				when {
					outputIndex >= 0 -> drainOutputImage(activeCodec, outputIndex)
					outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED ->
						Log.i(TAG, "Stream decoder output format changed stream=$streamId: ${activeCodec.outputFormat}")
					outputIndex == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> {
						// Ignored on modern codecs.
					}
					outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> return
					else -> return
				}
			}
		}

		private fun drainOutputImage(activeCodec: MediaCodec, outputIndex: Int) {
			val image = try {
				activeCodec.getOutputImage(outputIndex)
			} catch (_: Exception) {
				null
			}
			try {
				if (image == null) {
					return
				}
				val nowNsCached = nowNs()
				val planes = extractYuvPlanesTight(image)
				if (planes == null) {
					emitError("Decoder output image is not YUV_420_888")
					return
				}
				emitSignal(
					"yuv_frame_ready_for_stream",
					streamId,
					image.width,
					image.height,
					nowNsCached,
					planes.first,
					planes.second,
					planes.third,
				)
			} finally {
				try { image?.close() } catch (_: Exception) {}
				try { activeCodec.releaseOutputBuffer(outputIndex, false) } catch (_: Exception) {}
			}
		}

		private fun releaseCodec() {
			val localCodec = sessionCodec
			sessionCodec = null
			if (localCodec != null) {
				try {
					localCodec.stop()
				} catch (_: Exception) {}
				try {
					localCodec.release()
				} catch (_: Exception) {}
			}
		}

		private fun emitError(message: String) {
			emitSignal("decoder_error_for_stream", streamId, message)
		}
	}

		private fun extractCodecSpecificData(accessUnit: ByteArray): Pair<ByteArray?, ByteArray?> {
		var sps: ByteArray? = null
		var pps: ByteArray? = null
		var offset = 0

		while (offset < accessUnit.size) {
			val start = findStartCode(accessUnit, offset)
			if (start < 0) {
				break
			}
			val prefixLength = startCodeLength(accessUnit, start)
			val payloadStart = start + prefixLength
			val next = findStartCode(accessUnit, payloadStart)
			val end = if (next >= 0) next else accessUnit.size
			if (end > payloadStart) {
				val nal = accessUnit.copyOfRange(start, end)
				when (nalType(nal)) {
					7 -> if (sps == null) sps = nal
					8 -> if (pps == null) pps = nal
				}
			}
			offset = if (next >= 0) next else accessUnit.size
		}

		return sps to pps
	}

	/**
	 * Walk an HEVC access unit (Annex-B) and return the concatenated
	 * VPS+SPS+PPS NALs (each keeping its start code) for MediaFormat csd-0.
	 * Returns null if any of the three is missing — `configure()` then proceeds
	 * without csd-0 and relies on the parameter sets the fan-out primed inline
	 * before the first IDR.
	 *
	 * HEVC NAL header is 2 bytes; the type is bits 6..1 of the first byte
	 * (`(byte >> 1) & 0x3F`). VPS=32, SPS=33, PPS=34.
	 */
	private fun extractHevcCodecSpecificData(accessUnit: ByteArray): ByteArray? {
		var vps: ByteArray? = null
		var sps: ByteArray? = null
		var pps: ByteArray? = null
		var offset = 0

		while (offset < accessUnit.size) {
			val start = findStartCode(accessUnit, offset)
			if (start < 0) {
				break
			}
			val prefixLength = startCodeLength(accessUnit, start)
			val payloadStart = start + prefixLength
			val next = findStartCode(accessUnit, payloadStart)
			val end = if (next >= 0) next else accessUnit.size
			if (end > payloadStart) {
				val nal = accessUnit.copyOfRange(start, end)
				when (hevcNalType(nal)) {
					32 -> if (vps == null) vps = nal
					33 -> if (sps == null) sps = nal
					34 -> if (pps == null) pps = nal
				}
			}
			offset = if (next >= 0) next else accessUnit.size
		}

		if (vps == null || sps == null || pps == null) {
			Log.i(
				TAG,
				"HEVC csd incomplete (vps=${vps != null} sps=${sps != null} " +
					"pps=${pps != null}); relying on inline parameter sets",
			)
			return null
		}

		val out = ByteArray(vps.size + sps.size + pps.size)
		var p = 0
		System.arraycopy(vps, 0, out, p, vps.size); p += vps.size
		System.arraycopy(sps, 0, out, p, sps.size); p += sps.size
		System.arraycopy(pps, 0, out, p, pps.size)
		return out
	}

	private fun findStartCode(data: ByteArray, fromIndex: Int): Int {
		var index = max(0, fromIndex)
		while (index + 3 <= data.size) {
			if (data[index] == 0.toByte() && data[index + 1] == 0.toByte()) {
				if (index + 2 < data.size && data[index + 2] == 1.toByte()) {
					return index
				}
				if (
					index + 3 < data.size &&
					data[index + 2] == 0.toByte() &&
					data[index + 3] == 1.toByte()
				) {
					return index
				}
			}
			index++
		}
		return -1
	}

	private fun startCodeLength(data: ByteArray, start: Int): Int {
		return if (
			start + 2 < data.size &&
			data[start] == 0.toByte() &&
			data[start + 1] == 0.toByte() &&
			data[start + 2] == 1.toByte()
		) {
			3
		} else {
			4
		}
	}

	private fun nalType(nal: ByteArray): Int {
		val prefixLength = when {
			nal.size >= 4 &&
				nal[0] == 0.toByte() &&
				nal[1] == 0.toByte() &&
				nal[2] == 0.toByte() &&
				nal[3] == 1.toByte() -> 4
			nal.size >= 3 &&
				nal[0] == 0.toByte() &&
				nal[1] == 0.toByte() &&
				nal[2] == 1.toByte() -> 3
			else -> 0
		}
		return if (nal.size > prefixLength) nal[prefixLength].toInt() and 0x1F else -1
	}

	/**
	 * HEVC NAL type — bits 6..1 of the byte after the start code
	 * (`(byte >> 1) & 0x3F`). Compare to H.264's `nalType` which uses the low 5
	 * bits of the same byte. Returns -1 if the NAL is too short to parse.
	 */
	private fun hevcNalType(nal: ByteArray): Int {
		val prefixLength = when {
			nal.size >= 4 &&
				nal[0] == 0.toByte() &&
				nal[1] == 0.toByte() &&
				nal[2] == 0.toByte() &&
				nal[3] == 1.toByte() -> 4
			nal.size >= 3 &&
				nal[0] == 0.toByte() &&
				nal[1] == 0.toByte() &&
				nal[2] == 1.toByte() -> 3
			else -> 0
		}
		return if (nal.size > prefixLength) (nal[prefixLength].toInt() shr 1) and 0x3F else -1
	}

	private var firstFrameLogged = false

	// Reusable plane scratch buffers so the inner loop reads from raw
	// ByteArrays (much faster than ByteBuffer.get(int) which has per-call
	// JNI + bounds-check overhead). The RGBA output must be freshly
	// allocated each frame because it is handed to the deferred Godot
	// callback and may outlive the next decode pass.
	private var yScratch: ByteArray = ByteArray(0)
	private var uScratch: ByteArray = ByteArray(0)
	private var vScratch: ByteArray = ByteArray(0)

	/**
	 * Plan B helper: copy each YUV_420_888 plane out of the MediaCodec
	 * Image into a tightly packed ByteArray (no row padding, no pixel
	 * stride) so the GDScript side can upload it as an FORMAT_L8 texture
	 * directly. Returns null if the image format / plane layout doesn't
	 * match expectations, in which case the caller should fall back to
	 * the legacy CPU YUV->RGB path.
	 *
	 * Output sizes:
	 *   .first  Y, w*h bytes
	 *   .second U, (w/2)*(h/2) bytes
	 *   .third  V, (w/2)*(h/2) bytes
	 */
	private fun extractYuvPlanesTight(image: Image): Triple<ByteArray, ByteArray, ByteArray>? {
		if (image.format != ImageFormat.YUV_420_888) return null
		val planes = image.planes
		if (planes.size < 3) return null

		val w = image.width
		val h = image.height
		val cw = w / 2
		val ch = h / 2

		val yOut = ByteArray(w * h)
		val uOut = ByteArray(cw * ch)
		val vOut = ByteArray(cw * ch)

		copyPlaneTight(planes[0], w, h, 1, yOut)
		copyPlaneTight(planes[1], cw, ch, planes[1].pixelStride, uOut)
		copyPlaneTight(planes[2], cw, ch, planes[2].pixelStride, vOut)

		return Triple(yOut, uOut, vOut)
	}

	private fun copyPlaneTight(
		plane: Image.Plane,
		width: Int,
		height: Int,
		pixelStride: Int,
		dst: ByteArray,
	) {
		val rowStride = plane.rowStride
		val src = plane.buffer
		src.position(0)

		if (pixelStride == 1 && rowStride == width) {
			// Tightly packed already: one bulk copy.
			src.get(dst, 0, minOf(width * height, src.remaining()))
			return
		}

		// Either padded rows (rowStride > width) or interleaved chroma
		// (pixelStride == 2 for NV12-style buffers). Walk row by row.
		val rowBuf = ByteArray(rowStride)
		var dstOff = 0
		for (row in 0 until height) {
			src.position(row * rowStride)
			val toRead = minOf(rowStride, src.remaining())
			src.get(rowBuf, 0, toRead)
			if (pixelStride == 1) {
				System.arraycopy(rowBuf, 0, dst, dstOff, width)
			} else {
				var s = 0
				var d = dstOff
				val end = width
				var i = 0
				while (i < end) {
					dst[d] = rowBuf[s]
					s += pixelStride
					d += 1
					i += 1
				}
			}
			dstOff += width
		}
	}

	private fun convertToRgbaCpu(image: Image): ByteArray {
		if (image.format != ImageFormat.YUV_420_888) {
			Log.w(TAG, "Unexpected image format ${image.format}")
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

		val yRowStride = yPlane.rowStride
		val uRowStride = uPlane.rowStride
		val vRowStride = vPlane.rowStride
		val uPixelStride = uPlane.pixelStride
		val vPixelStride = vPlane.pixelStride

		if (!firstFrameLogged) {
			firstFrameLogged = true
			Log.i(
				TAG,
				"Image planes: w=${image.width} h=${image.height} " +
					"format=${image.format} " +
					"yRowStride=$yRowStride yPxStride=${yPlane.pixelStride} yBufRem=${yBuffer.remaining()} " +
					"uRowStride=$uRowStride uPxStride=$uPixelStride uBufRem=${uBuffer.remaining()} " +
					"vRowStride=$vRowStride vPxStride=$vPixelStride vBufRem=${vBuffer.remaining()}"
			)
			val sampleCount = 6
			val yBytes = StringBuilder("Y[0..]=")
			val uBytes = StringBuilder("U[0..]=")
			val vBytes = StringBuilder("V[0..]=")
			for (i in 0 until sampleCount) {
				if (i < yBuffer.remaining()) yBytes.append("${yBuffer.get(i).toInt() and 0xFF},")
				if (i < uBuffer.remaining()) uBytes.append("${uBuffer.get(i).toInt() and 0xFF},")
				if (i < vBuffer.remaining()) vBytes.append("${vBuffer.get(i).toInt() and 0xFF},")
			}
			Log.i(TAG, "$yBytes  $uBytes  $vBytes")
		}

		val width = image.width
		val height = image.height
		val rgbaSize = width * height * 4

		// Pull each plane into a contiguous ByteArray once. ByteBuffer.get(int)
		// has per-call bounds checks and JNI overhead that dominates inside a
		// 230k-iteration inner loop; ByteArray reads are bare bytecode.
		val ySize = yRowStride * height
		val uvSize = uRowStride * (height / 2)
		if (yScratch.size < ySize) yScratch = ByteArray(ySize)
		if (uScratch.size < uvSize) uScratch = ByteArray(uvSize)
		if (vScratch.size < uvSize) vScratch = ByteArray(uvSize)

		yBuffer.position(0)
		yBuffer.get(yScratch, 0, minOf(ySize, yBuffer.remaining()))
		uBuffer.position(0)
		uBuffer.get(uScratch, 0, minOf(uvSize, uBuffer.remaining()))
		vBuffer.position(0)
		vBuffer.get(vScratch, 0, minOf(uvSize, vBuffer.remaining()))

		val y = yScratch
		val u = uScratch
		val v = vScratch
		val rgba = ByteArray(rgbaSize)

		// BT.601 (limited range) integer coefficients, scaled by 256:
		//   R = ( 298*(Y-16) + 409*(V-128) + 128 ) >> 8
		//   G = ( 298*(Y-16) - 100*(U-128) - 208*(V-128) + 128 ) >> 8
		//   B = ( 298*(Y-16) + 516*(U-128) + 128 ) >> 8
		// Pure integer math with one shift/clamp per channel — at least
		// 3-5x faster than the previous Float coercion path on swan's CPU.
		var dst = 0
		for (row in 0 until height) {
			var srcY = row * yRowStride
			val srcUv = (row shr 1) * uRowStride
			val srcVv = (row shr 1) * vRowStride
			var col = 0
			while (col < width) {
				val yVal = (y[srcY].toInt() and 0xFF) - 16
				val uvCol = (col shr 1) * uPixelStride
				val vvCol = (col shr 1) * vPixelStride
				val uVal = (u[srcUv + uvCol].toInt() and 0xFF) - 128
				val vVal = (v[srcVv + vvCol].toInt() and 0xFF) - 128

				val y298 = 298 * yVal
				val rOut = (y298 + 409 * vVal + 128) shr 8
				val gOut = (y298 - 100 * uVal - 208 * vVal + 128) shr 8
				val bOut = (y298 + 516 * uVal + 128) shr 8

				rgba[dst]     = clampU8(rOut)
				rgba[dst + 1] = clampU8(gOut)
				rgba[dst + 2] = clampU8(bOut)
				rgba[dst + 3] = 0xFF.toByte()

				dst += 4
				srcY += 1
				col += 1
			}
		}

		return rgba
	}

	private fun clampU8(v: Int): Byte =
		(if (v < 0) 0 else if (v > 255) 255 else v).toByte()
}
