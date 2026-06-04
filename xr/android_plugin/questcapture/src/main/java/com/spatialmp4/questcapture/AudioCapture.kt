package com.spatialmp4.questcapture

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import android.util.Log
import com.spatialmp4.contract.AudioChannelLayout
import com.spatialmp4.contract.AudioStreamConfig
import com.spatialmp4.contract.SpatialDataSink
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max

/**
 * Single-mic / stereo-mic capture driver: routes one AudioRecord stream into
 * an AAC-LC MediaCodec encoder and hands the encoded packets to a
 * SpatialDataSink. Owns its own background thread; start() / stopAndDrain()
 * mirror the lifecycle shape of StereoHevcEncoder so QuestCapturePlugin can
 * manage both with the same pattern.
 *
 * v1 of the audio path captures stereo PCM (channelLayout = STEREO). The
 * AudioChannelLayout enum already carries FOA / RAW_4CH for the day we add
 * a proper beamforming or Meta Spatial Audio SDK ingest; until then the
 * stereo path is what ships and the channel layout label is recorded into
 * the muxer's `spatial_format` stream metadata so a player will not try to
 * rotate it as ambisonic.
 *
 * Clock domain: MediaCodec only sees the timestamps we set on
 * queueInputBuffer.presentationTimeUs. We anchor AAC frame 0 to the first
 * successful microphone read in Godot ticks (the same domain used by
 * RGB/depth/pose), then derive every later PTS from sample count. That avoids
 * both the session-start skew from camera/encoder warm-up and MediaCodec clock
 * drift over long captures.
 */
class AudioCapture(
    private val dataSink: SpatialDataSink,
    private val sampleRateHz: Int,
    private val channelLayout: AudioChannelLayout,
    // Difference between Android CLOCK_MONOTONIC/System.nanoTime() ns and
    // Godot ticks ns, captured at session configure time by QuestCapturePlugin.
    private val clockMonotonicToGodotTicksOffsetNs: Long,
    // Last-resort fallback if the clock offset has not been configured.
    private val fallbackSessionStartGodotTicksUs: Long,
    private val bitrateBps: Int = DEFAULT_AAC_BITRATE_BPS,
    private val onError: (String) -> Unit,
    private val onPacketEmitted: () -> Unit = {}
) {
    private val androidChannelMask: Int = when (channelLayout.channelCount) {
        1 -> AudioFormat.CHANNEL_IN_MONO
        2 -> AudioFormat.CHANNEL_IN_STEREO
        else -> {
            // 4-channel FOA / RAW_4CH would need a vendor-specific channel
            // mask (Quest 3 mic array) or the Meta Spatial Audio Capture SDK
            // -- neither is wired up in this revision. Fall back to stereo so
            // a misconfigured session still produces something audible.
            Log.w(TAG, "channelLayout=$channelLayout requested but AudioRecord supports up to stereo here; falling back")
            AudioFormat.CHANNEL_IN_STEREO
        }
    }
    private val effectiveChannelCount: Int = when (androidChannelMask) {
        AudioFormat.CHANNEL_IN_MONO -> 1
        AudioFormat.CHANNEL_IN_STEREO -> 2
        else -> 2
    }
    // If we had to fall back from FOA to stereo above, label the muxer
    // metadata accordingly so a downstream player does not try to render
    // ambisonic from a stereo-only signal.
    private val effectiveChannelLayout: AudioChannelLayout =
        if (effectiveChannelCount == channelLayout.channelCount) channelLayout else when (effectiveChannelCount) {
            1 -> AudioChannelLayout.MONO
            else -> AudioChannelLayout.STEREO
        }

    private val pcmFormat = AudioFormat.ENCODING_PCM_16BIT
    private val bytesPerSample = 2

    private var audioRecord: AudioRecord? = null
    private var encoder: MediaCodec? = null
    private var captureThread: Thread? = null
    private var drainThread: Thread? = null

    @Volatile private var running = false
    @Volatile private var csdEmitted = false
    private var csdReady = CountDownLatch(1)

    // Counts AAC frames (1024 samples each) handed to / drained from the
    // encoder. PTS is derived directly from sample count so integer truncation
    // does not accumulate across long captures.
    private val framesPushedToEncoder = AtomicLong(0L)
    private val framesDrainedFromEncoder = AtomicLong(0L)
    @Volatile private var firstSamplePtsUs = UNSET_PTS_US

    private val bufferInfo = MediaCodec.BufferInfo()

    fun start(): Boolean {
        if (running) return true
        return try {
            val minBufBytes = AudioRecord.getMinBufferSize(sampleRateHz, androidChannelMask, pcmFormat)
            if (minBufBytes == AudioRecord.ERROR || minBufBytes == AudioRecord.ERROR_BAD_VALUE) {
                onError("AudioRecord.getMinBufferSize failed for ${sampleRateHz}Hz channels=$effectiveChannelCount")
                return false
            }
            // Triple the minimum buffer so a stuck MediaCodec input thread
            // doesn't drop samples — the steady-state cost is only ~6 KB.
            val audioBufBytes = max(minBufBytes * 3, AAC_FRAME_SAMPLES * effectiveChannelCount * bytesPerSample * 8)

            val record = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                sampleRateHz,
                androidChannelMask,
                pcmFormat,
                audioBufBytes
            )
            if (record.state != AudioRecord.STATE_INITIALIZED) {
                onError("AudioRecord did not initialize (state=${record.state})")
                record.release()
                return false
            }
            audioRecord = record

            val format = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_AAC,
                sampleRateHz,
                effectiveChannelCount
            )
            format.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            format.setInteger(MediaFormat.KEY_BIT_RATE, bitrateBps)
            // Some Android stacks need an explicit MAX_INPUT_SIZE so direct
            // buffers can hold one full AAC frame's PCM payload.
            format.setInteger(
                MediaFormat.KEY_MAX_INPUT_SIZE,
                AAC_FRAME_SAMPLES * effectiveChannelCount * bytesPerSample
            )

            val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            encoder = codec
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)

            framesPushedToEncoder.set(0L)
            framesDrainedFromEncoder.set(0L)
            firstSamplePtsUs = UNSET_PTS_US
            csdEmitted = false
            csdReady = CountDownLatch(1)

            codec.start()
            record.startRecording()
            running = true

            // Capture thread: PCM -> encoder input buffers.
            captureThread = Thread({ captureLoop() }, "SpatialAudioCapture").also { it.start() }
            // Drain thread: encoder output -> SpatialDataSink. Kept separate
            // because dequeueOutputBuffer's timeout can block longer than the
            // 21 ms AAC frame period when the encoder is starved, and we
            // don't want that to back-pressure the AudioRecord side.
            drainThread = Thread({ drainLoop() }, "SpatialAudioDrain").also { it.start() }

            Log.i(
                TAG,
                "AudioCapture started: ${sampleRateHz}Hz ch=$effectiveChannelCount layout=${effectiveChannelLayout.tag} bitrate=$bitrateBps"
            )
            if (!csdReady.await(CSD_START_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                val reason = "AAC encoder did not emit codec config within ${CSD_START_TIMEOUT_MS}ms"
                onError(reason)
                dataSink.onAudioUnavailable(reason)
                stopAndDrain()
                return false
            }
            true
        } catch (error: Exception) {
            onError("Failed to start AudioCapture: ${error.message}")
            try {
                encoder?.stop()
            } catch (_: Exception) {
            }
            try {
                audioRecord?.release()
            } catch (_: Exception) {
            }
            audioRecord = null
            try {
                encoder?.release()
            } catch (_: Exception) {
            }
            encoder = null
            running = false
            false
        }
    }

    fun stopAndDrain() {
        if (!running) return
        running = false
        // Stop the PCM source first so the capture loop drains its remaining
        // input buffers and signals END_OF_STREAM to the encoder.
        try {
            audioRecord?.stop()
        } catch (_: Exception) {
        }
        try {
            captureThread?.join(STOP_JOIN_MS)
        } catch (_: InterruptedException) {
        }
        try {
            drainThread?.join(STOP_JOIN_MS)
        } catch (_: InterruptedException) {
        }
        try {
            encoder?.stop()
        } catch (_: Exception) {
        }
        try {
            encoder?.release()
        } catch (_: Exception) {
        }
        try {
            audioRecord?.release()
        } catch (_: Exception) {
        }
        encoder = null
        audioRecord = null
        captureThread = null
        drainThread = null
        Log.i(TAG, "AudioCapture stopped")
    }

    private fun captureLoop() {
        val record = audioRecord ?: return
        val codec = encoder ?: return
        val pcmBytesPerFrame = AAC_FRAME_SAMPLES * effectiveChannelCount * bytesPerSample
        val scratch = ByteArray(pcmBytesPerFrame)
        try {
            while (running) {
                val inputIndex = try {
                    codec.dequeueInputBuffer(10_000)
                } catch (error: IllegalStateException) {
                    onError("AAC encoder input dequeue failed: ${error.message}")
                    -1
                }
                if (inputIndex < 0) continue

                val inputBuffer = codec.getInputBuffer(inputIndex) ?: continue
                inputBuffer.clear()

                // Read exactly one AAC frame's worth of PCM. Anything less
                // would let the encoder fall behind the AudioRecord ring
                // buffer; anything more wastes a copy.
                var totalRead = 0
                while (totalRead < pcmBytesPerFrame && running) {
                    val n = try {
                        record.read(scratch, totalRead, pcmBytesPerFrame - totalRead)
                    } catch (error: Exception) {
                        -1
                    }
                    if (n <= 0) break
                    if (firstSamplePtsUs == UNSET_PTS_US) {
                        firstSamplePtsUs = currentGodotTicksUs()
                        Log.i(TAG, "AudioCapture first sample PTS anchored at ${firstSamplePtsUs}us")
                    }
                    totalRead += n
                }
                if (totalRead <= 0) continue
                inputBuffer.put(scratch, 0, totalRead)

                val framesPushed = framesPushedToEncoder.getAndIncrement()
                val anchorUs = firstSamplePtsUs.takeIf { it != UNSET_PTS_US }
                    ?: fallbackSessionStartGodotTicksUs
                val ptsUs = anchorUs + frameOffsetUs(framesPushed)
                try {
                    codec.queueInputBuffer(inputIndex, 0, totalRead, ptsUs, 0)
                } catch (error: IllegalStateException) {
                    onError("AAC encoder queueInputBuffer failed: ${error.message}")
                    return
                }
            }

            // Flush: tell the encoder no more input is coming so it emits any
            // last AAC frame and the drain thread can see END_OF_STREAM.
            try {
                val tail = codec.dequeueInputBuffer(20_000)
                if (tail >= 0) {
                    codec.queueInputBuffer(tail, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                }
            } catch (_: IllegalStateException) {
            }
        } catch (error: Exception) {
            onError("AudioCapture captureLoop failed: ${error.message}")
        }
    }

    private fun drainLoop() {
        val codec = encoder ?: return
        try {
            while (true) {
                val outputIndex = try {
                    codec.dequeueOutputBuffer(bufferInfo, 50_000)
                } catch (error: IllegalStateException) {
                    onError("AAC encoder output dequeue failed: ${error.message}")
                    return
                }
                when (outputIndex) {
                    MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        continue
                    }
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        emitCsd(codec.outputFormat)
                    }
                    else -> {
                        if (outputIndex < 0) continue
                        try {
                            val outputBuffer = codec.getOutputBuffer(outputIndex)
                            if (outputBuffer != null && bufferInfo.size > 0) {
                                if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                                    // Codec-config: extract once for the muxer's
                                    // AudioStreamConfig.csd if INFO_OUTPUT_FORMAT_CHANGED
                                    // did not already supply it.
                                    if (!csdEmitted) {
                                        val csd = ByteArray(bufferInfo.size)
                                        outputBuffer.position(bufferInfo.offset)
                                        outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                                        outputBuffer.get(csd)
                                        emitCsdFromBytes(csd)
                                    }
                                } else {
                                    outputBuffer.position(bufferInfo.offset)
                                    outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                                    // AAC keyframes every frame -> isKeyframe always true.
                                    val ptsNs = bufferInfo.presentationTimeUs * 1_000L
                                    val drainedFrame = framesDrainedFromEncoder.getAndIncrement()
                                    val durationNs = frameDurationUs(drainedFrame) * 1_000L
                                    dataSink.onAudioPacket(outputBuffer, ptsNs, durationNs, true)
                                    onPacketEmitted()
                                }
                            }
                        } finally {
                            try {
                                codec.releaseOutputBuffer(outputIndex, false)
                            } catch (_: Exception) {
                            }
                        }
                        if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            return
                        }
                    }
                }
            }
        } catch (error: Exception) {
            onError("AudioCapture drainLoop failed: ${error.message}")
        }
    }

    private fun emitCsd(format: MediaFormat) {
        if (csdEmitted) return
        val csd = collectCsd(format)
        if (csd.isEmpty()) {
            Log.w(TAG, "AAC encoder output format had no csd-0; deferring to first BUFFER_FLAG_CODEC_CONFIG packet")
            return
        }
        emitCsdFromBytes(csd)
    }

    private fun emitCsdFromBytes(csd: ByteArray) {
        if (csdEmitted) return
        csdEmitted = true
        dataSink.onAudioCsd(
            AudioStreamConfig(
                sampleRateHz = sampleRateHz,
                channelCount = effectiveChannelCount,
                channelLayout = effectiveChannelLayout,
                csd = csd
            )
        )
        csdReady.countDown()
    }

    private fun collectCsd(format: MediaFormat): ByteArray {
        val buffer = try {
            format.getByteBuffer("csd-0")
        } catch (_: Exception) {
            null
        } ?: return ByteArray(0)
        return buffer.toByteArrayCopy()
    }

    private fun ByteBuffer.toByteArrayCopy(): ByteArray {
        val copy = slice()
        val out = ByteArray(copy.remaining())
        copy.get(out)
        return out
    }

    private fun currentGodotTicksUs(): Long {
        if (clockMonotonicToGodotTicksOffsetNs == 0L) {
            return fallbackSessionStartGodotTicksUs
        }
        return (System.nanoTime() + clockMonotonicToGodotTicksOffsetNs) / 1_000L
    }

    private fun frameOffsetUs(frameIndex: Long): Long =
        frameIndex * AAC_FRAME_SAMPLES * 1_000_000L / sampleRateHz

    private fun frameDurationUs(frameIndex: Long): Long =
        frameOffsetUs(frameIndex + 1L) - frameOffsetUs(frameIndex)

    companion object {
        private const val TAG = "AudioCapture"
        // 48 kHz is what AAC-LC prefers and what every Quest/Pico variant we
        // tested exposes on the MIC source; 16 kHz is only available on
        // UNPROCESSED which we are not using yet.
        const val DEFAULT_SAMPLE_RATE_HZ = 48_000
        // 128 kbps stereo / 192 kbps for a 4-ch FOA upgrade. AAC at this
        // bitrate is transparent enough for capture analysis.
        const val DEFAULT_AAC_BITRATE_BPS = 128_000
        // AAC-LC frame size in samples per channel.
        private const val AAC_FRAME_SAMPLES = 1024
        private const val STOP_JOIN_MS = 1_000L
        private const val CSD_START_TIMEOUT_MS = 2_000L
        private const val UNSET_PTS_US = Long.MIN_VALUE
    }
}
