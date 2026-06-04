#include <jni.h>

#include <android/log.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <new>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/codec_id.h>
#include <libavcodec/packet.h>
#include <libavformat/avformat.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/mem.h>
#include <libavutil/pixfmt.h>
}

namespace {

constexpr const char* kTag = "SpatialMp4Writer";
constexpr AVRational kUsTimeBase{1, 1000000};
constexpr int64_t kDefaultRgbDurationUs = 33333;
constexpr int64_t kDefaultDepthDurationUs = 200000;
constexpr int64_t kDefaultPoseDurationUs = 11111;

constexpr int kTrackHeadPose = 0;
constexpr int kTrackLeftControllerPose = 1;
constexpr int kTrackRightControllerPose = 2;
constexpr int kTrackLeftHandJoints = 3;
constexpr int kTrackRightHandJoints = 4;
constexpr int kTrackLeftControllerInput = 5;
constexpr int kTrackRightControllerInput = 6;
constexpr int kTimedTrackCount = 7;

std::string AvError(int errnum) {
  char buffer[AV_ERROR_MAX_STRING_SIZE] = {0};
  av_strerror(errnum, buffer, sizeof(buffer));
  return std::string(buffer);
}

std::string JStringToString(JNIEnv* env, jstring value) {
  if (!value) {
    return "";
  }
  const char* chars = env->GetStringUTFChars(value, nullptr);
  if (!chars) {
    return "";
  }
  std::string out(chars);
  env->ReleaseStringUTFChars(value, chars);
  return out;
}

std::vector<uint8_t> JByteArrayToVector(JNIEnv* env, jbyteArray value) {
  std::vector<uint8_t> out;
  if (!value) {
    return out;
  }
  const jsize size = env->GetArrayLength(value);
  if (size <= 0) {
    return out;
  }
  out.resize(static_cast<size_t>(size));
  env->GetByteArrayRegion(value, 0, size, reinterpret_cast<jbyte*>(out.data()));
  return out;
}

jstring StringToJString(JNIEnv* env, const std::string& value) {
  return env->NewStringUTF(value.c_str());
}

void SetSideData(AVStream* stream, AVPacketSideDataType type, const std::vector<uint8_t>& data) {
  if (!stream || data.empty()) {
    return;
  }
  AVPacketSideData* side_data = av_packet_side_data_new(
      &stream->codecpar->coded_side_data,
      &stream->codecpar->nb_coded_side_data,
      type,
      data.size(),
      0);
  if (!side_data) {
    throw std::runtime_error("failed to allocate stream side data");
  }
  std::memcpy(side_data->data, data.data(), data.size());
}

struct SideDataBundle {
  std::vector<uint8_t> icam;
  std::vector<uint8_t> ecam;
  std::vector<uint8_t> dstr;
};

enum class PacketKind {
  kRgb,
  kDepth,
  kTimedMetadata,
};

struct PendingPacket {
  PacketKind kind = PacketKind::kRgb;
  int timed_track_id = -1;
  int64_t pts_us = 0;
  int64_t duration_us = 0;
  int flags = 0;
  std::vector<uint8_t> data;
};

class LiveSpatialMp4Writer {
 public:
  LiveSpatialMp4Writer(std::string partial_path,
                       std::string final_path,
                       int64_t session_start_unix_us,
                       int64_t session_start_godot_ticks_us,
                       int rgb_width,
                       int rgb_height,
                       int rgb_fps,
                       int rgb_camera_count,
                       bool depth_expected,
                       bool head_pose_expected,
                       bool controller_pose_expected,
                       bool hand_joints_expected,
                       bool controller_input_expected,
                       SideDataBundle rgb_side_data)
      : partial_path_(std::move(partial_path)),
        final_path_(std::move(final_path)),
        session_start_unix_us_(session_start_unix_us),
        session_start_godot_ticks_us_(session_start_godot_ticks_us),
        rgb_width_(rgb_width),
        rgb_height_(rgb_height),
        rgb_fps_(rgb_fps > 0 ? rgb_fps : 30),
        rgb_camera_count_(rgb_camera_count == 2 ? 2 : 1),
        depth_expected_(depth_expected),
        head_pose_expected_(head_pose_expected),
        controller_pose_expected_(controller_pose_expected),
        hand_joints_expected_(hand_joints_expected),
        controller_input_expected_(controller_input_expected),
        rgb_side_data_(std::move(rgb_side_data)),
        timed_streams_(kTimedTrackCount, nullptr) {
    // Spawn the dedicated I/O thread. All FFmpeg writes happen here so the
    // Godot main thread and the camera HandlerThread never block on
    // av_interleaved_write_frame / file I/O when they enqueue packets.
    io_thread_ = std::thread(&LiveSpatialMp4Writer::IoLoop, this);
  }

  ~LiveSpatialMp4Writer() {
    StopIoThread();
    std::lock_guard<std::mutex> lock(format_mutex_);
    CloseUnlocked();
  }

  bool ConfigureHevc(const std::vector<uint8_t>& csd) {
    std::lock_guard<std::mutex> lock(format_mutex_);
    try {
      EnsureContext();
      if (rgb_stream_) {
        return true;
      }
      if (csd.empty()) {
        return Fail("HEVC codec config is empty");
      }

      rgb_stream_ = avformat_new_stream(format_context_, nullptr);
      if (!rgb_stream_) {
        return Fail("failed to create RGB stream");
      }
      rgb_stream_->time_base = kUsTimeBase;
      rgb_stream_->avg_frame_rate = AVRational{rgb_fps_, 1};
      rgb_stream_->r_frame_rate = rgb_stream_->avg_frame_rate;

      AVCodecParameters* codecpar = rgb_stream_->codecpar;
      codecpar->codec_type = AVMEDIA_TYPE_VIDEO;
      codecpar->codec_id = AV_CODEC_ID_HEVC;
      codecpar->format = AV_PIX_FMT_YUV420P;
      codecpar->width = rgb_width_;
      codecpar->height = rgb_height_;
      codecpar->color_range = AVCOL_RANGE_MPEG;
      codecpar->color_primaries = AVCOL_PRI_BT709;
      codecpar->color_trc = AVCOL_TRC_BT709;
      codecpar->color_space = AVCOL_SPC_BT709;
      codecpar->chroma_location = AVCHROMA_LOC_LEFT;
      codecpar->extradata = static_cast<uint8_t*>(av_mallocz(csd.size() + AV_INPUT_BUFFER_PADDING_SIZE));
      if (!codecpar->extradata) {
        return Fail("failed to allocate HEVC extradata");
      }
      std::memcpy(codecpar->extradata, csd.data(), csd.size());
      codecpar->extradata_size = static_cast<int>(csd.size());

      av_dict_set(&rgb_stream_->metadata, "camera_model", "pinhole", 0);
      av_dict_set(&rgb_stream_->metadata, "distortion_model", "brown", 0);
      av_dict_set_int(&rgb_stream_->metadata, "cam_count", rgb_camera_count_, 0);
      // track_base_time is finalised inside the io thread (via
      // PopulateTrackBaseTimeMetadata in WriteHeader_Locked) once the first
      // packet's absolute PTS is known. Placeholder zeros keep the dict slot
      // reserved if anyone reads the stream before header finalisation.
      av_dict_set_int(&rgb_stream_->metadata, "track_base_time", 0, 0);
      SetSideData(rgb_stream_, AV_PKT_DATA_ICAM, rgb_side_data_.icam);
      SetSideData(rgb_stream_, AV_PKT_DATA_ECAM, rgb_side_data_.ecam);
      SetSideData(rgb_stream_, AV_PKT_DATA_DISTORTION_COEFFICIENTS, rgb_side_data_.dstr);

      hevc_configured_ = true;
      WakeIoThread();
      return true;
    } catch (const std::exception& error) {
      return Fail(error.what());
    }
  }

  bool ConfigureDepth(int width, int height, SideDataBundle side_data) {
    std::lock_guard<std::mutex> lock(format_mutex_);
    try {
      if (header_written_) {
        return true;
      }
      EnsureContext();
      if (depth_stream_) {
        return true;
      }
      if (width <= 0 || height <= 0) {
        return Fail("invalid depth stream dimensions");
      }

      depth_stream_ = avformat_new_stream(format_context_, nullptr);
      if (!depth_stream_) {
        return Fail("failed to create depth stream");
      }
      depth_stream_->time_base = kUsTimeBase;
      depth_stream_->avg_frame_rate = AVRational{5, 1};
      depth_stream_->r_frame_rate = depth_stream_->avg_frame_rate;

      // Depth is encoded losslessly with FFV1 (intra-only). FFV1 over the
      // metric-mm GRAY16LE grid is bit-exact yet ~5.5x smaller than the old
      // uncompressed `raw1` payload, and every frame is a keyframe so random
      // access is preserved. The SpatialMP4 ICAM/ECAM/DSTR/FOV/TBTM boxes are
      // still emitted (the patched mov muxer now writes them for FFV1 streams),
      // so depth intrinsics survive the round-trip exactly as they did for
      // raw1. Readers that predate FFV1 depth keep working on old captures via
      // the codec_id==NONE/raw1 branch.
      const AVCodec* depth_encoder = avcodec_find_encoder(AV_CODEC_ID_FFV1);
      if (!depth_encoder) {
        return Fail("FFV1 encoder is not available in this FFmpeg build");
      }
      depth_enc_ctx_ = avcodec_alloc_context3(depth_encoder);
      if (!depth_enc_ctx_) {
        return Fail("failed to allocate FFV1 encoder context");
      }
      depth_enc_ctx_->width = width;
      depth_enc_ctx_->height = height;
      depth_enc_ctx_->pix_fmt = AV_PIX_FMT_GRAY16LE;
      depth_enc_ctx_->time_base = kUsTimeBase;
      depth_enc_ctx_->framerate = AVRational{5, 1};
      depth_enc_ctx_->level = 3;     // FFV1 v3 bitstream
      depth_enc_ctx_->gop_size = 1;  // intra-only; keeps every frame seekable
      if (format_context_->oformat &&
          (format_context_->oformat->flags & AVFMT_GLOBALHEADER)) {
        depth_enc_ctx_->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
      }
      const int open_ret = avcodec_open2(depth_enc_ctx_, depth_encoder, nullptr);
      if (open_ret < 0) {
        return Fail("failed to open FFV1 encoder: " + AvError(open_ret));
      }

      AVCodecParameters* codecpar = depth_stream_->codecpar;
      const int params_ret = avcodec_parameters_from_context(codecpar, depth_enc_ctx_);
      if (params_ret < 0) {
        return Fail("failed to copy FFV1 encoder parameters: " + AvError(params_ret));
      }
      // Leave codec_tag at 0 so the mov muxer assigns the standard 'FFV1'
      // fourcc; the demuxer maps it back to AV_CODEC_ID_FFV1 for the reader.
      codecpar->codec_tag = 0;

      depth_frame_ = av_frame_alloc();
      if (!depth_frame_) {
        return Fail("failed to allocate depth encode frame");
      }
      depth_frame_->format = AV_PIX_FMT_GRAY16LE;
      depth_frame_->width = width;
      depth_frame_->height = height;
      const int buf_ret = av_frame_get_buffer(depth_frame_, 0);
      if (buf_ret < 0) {
        return Fail("failed to allocate depth frame buffer: " + AvError(buf_ret));
      }
      depth_width_ = width;
      depth_height_ = height;

      av_dict_set_int(&depth_stream_->metadata, "data_accuracy", 2, 0);
      av_dict_set_int(&depth_stream_->metadata, "depth_legal_range", 1000, 0);
      av_dict_set(&depth_stream_->metadata, "depth_data_precision", "dtmm", 0);
      av_dict_set(&depth_stream_->metadata, "camera_model", "pinhole", 0);
      av_dict_set(&depth_stream_->metadata, "distortion_model", "brown", 0);
      av_dict_set(&depth_stream_->metadata, "cam_count", "1", 0);
      av_dict_set_int(&depth_stream_->metadata, "track_base_time", 0, 0);
      SetSideData(depth_stream_, AV_PKT_DATA_ICAM, side_data.icam);
      SetSideData(depth_stream_, AV_PKT_DATA_ECAM, side_data.ecam);
      SetSideData(depth_stream_, AV_PKT_DATA_DISTORTION_COEFFICIENTS, side_data.dstr);

      depth_configured_ = true;
      WakeIoThread();
      return true;
    } catch (const std::exception& error) {
      return Fail(error.what());
    }
  }

  bool WriteRgb(const std::vector<uint8_t>& data, int64_t pts_us, int64_t duration_us, int flags) {
    return Enqueue(PacketKind::kRgb, data, pts_us,
                   duration_us > 0 ? duration_us : kDefaultRgbDurationUs, flags);
  }

  bool WriteDepth(const std::vector<uint8_t>& data, int64_t pts_us, int64_t duration_us) {
    return Enqueue(PacketKind::kDepth, data, pts_us,
                   duration_us > 0 ? duration_us : kDefaultDepthDurationUs, AV_PKT_FLAG_KEY);
  }

  bool WriteTimedMetadata(int track_id, const std::vector<uint8_t>& data, int64_t pts_us, int64_t duration_us) {
    if (track_id < 0 || track_id >= kTimedTrackCount) {
      return Fail("invalid timed metadata track id");
    }
    return Enqueue(PacketKind::kTimedMetadata, track_id, data, pts_us,
                   duration_us > 0 ? duration_us : kDefaultPoseDurationUs, AV_PKT_FLAG_KEY);
  }

  bool Finish() {
    // Request orderly drain: io thread will finish processing every queued
    // packet (and the deferred batch), set drained_, and we then take
    // format_mutex_ to write the trailer + rename. This keeps writes
    // exclusively on the io thread, so no FFmpeg state is touched
    // concurrently from two threads.
    {
      std::lock_guard<std::mutex> lock(format_mutex_);
      if (depth_expected_ && !depth_configured_) {
        __android_log_print(ANDROID_LOG_WARN, kTag, "finishing without depth stream; no depth frames arrived");
        depth_expected_ = false;
      }
    }
    {
      std::lock_guard<std::mutex> qlock(queue_mutex_);
      finish_requested_ = true;
      // The I/O thread may already have moved packets out of io_queue_ into
      // its local deferred buffer while waiting for optional streams such as
      // depth. Always let the thread run one final pass before declaring the
      // writer drained.
      drained_ = false;
    }
    queue_cv_.notify_all();
    {
      std::unique_lock<std::mutex> qlock(queue_mutex_);
      drain_cv_.wait(qlock, [this] { return drained_; });
    }
    // Once draining has completed, stop the io thread cleanly so the trailer
    // write below cannot race with any in-flight WritePacket_Locked using the
    // streams we are about to free.
    StopIoThread();

    std::lock_guard<std::mutex> lock(format_mutex_);
    try {
      if (finished_) {
        return last_error_.empty();
      }
      if (!format_context_) {
        return Fail("writer was not started");
      }
      if (!hevc_configured_) {
        return Fail("HEVC stream was never configured");
      }
      if (!header_written_) {
        // Header was never written (no packets arrived). Bail with a clear
        // message rather than letting av_write_trailer crash on an
        // uninitialized context.
        return Fail("no packets were written before finish");
      }
      FlushDepthEncoder_Locked();
      const int ret = av_write_trailer(format_context_);
      if (ret < 0) {
        return Fail("failed to write mp4 trailer: " + AvError(ret));
      }
      if (format_context_->pb) {
        avio_closep(&format_context_->pb);
      }
      avformat_free_context(format_context_);
      format_context_ = nullptr;

      std::remove(final_path_.c_str());
      if (std::rename(partial_path_.c_str(), final_path_.c_str()) != 0) {
        return Fail("failed to rename partial mp4 to final path");
      }
      finished_ = true;
      return true;
    } catch (const std::exception& error) {
      return Fail(error.what());
    }
  }

  void Close() {
    StopIoThread();
    std::lock_guard<std::mutex> lock(format_mutex_);
    CloseUnlocked();
  }

  std::string LastError() const {
    std::lock_guard<std::mutex> lock(format_mutex_);
    return last_error_;
  }

 private:
  // ---- main-thread / camera-thread entry: enqueue only, no FFmpeg I/O ----

  bool Enqueue(PacketKind kind, const std::vector<uint8_t>& data,
               int64_t pts_us, int64_t duration_us, int flags) {
    return Enqueue(kind, -1, data, pts_us, duration_us, flags);
  }

  bool Enqueue(PacketKind kind, int timed_track_id, const std::vector<uint8_t>& data,
               int64_t pts_us, int64_t duration_us, int flags) {
    if (data.empty()) {
      return true;
    }
    PendingPacket packet;
    packet.kind = kind;
    packet.timed_track_id = timed_track_id;
    packet.pts_us = pts_us;
    packet.duration_us = duration_us;
    packet.flags = flags;
    packet.data = data;
    {
      std::lock_guard<std::mutex> qlock(queue_mutex_);
      if (shutdown_requested_ || finish_requested_) {
        // Refuse late writes once we are draining toward Finish() so the
        // io thread can converge on a quiet queue and signal drained_.
        return false;
      }
      // Track the earliest pts across all streams; the io thread snapshots
      // this when it writes the header so track_base_time stays accurate
      // even if a depth packet arrives first.
      if (first_pts_us_ == INT64_MIN || pts_us < first_pts_us_) {
        first_pts_us_ = pts_us;
      }
      io_queue_.push_back(std::move(packet));
    }
    queue_cv_.notify_one();
    return true;
  }

  void WakeIoThread() {
    queue_cv_.notify_one();
  }

  void StopIoThread() {
    {
      std::lock_guard<std::mutex> qlock(queue_mutex_);
      shutdown_requested_ = true;
      // Treat shutdown as "drained" so any Finish() in progress wakes up.
      drained_ = true;
    }
    queue_cv_.notify_all();
    drain_cv_.notify_all();
    if (io_thread_.joinable()) {
      io_thread_.join();
    }
  }

  // ---- io thread: owns format_mutex_ during real writes ----

  void IoLoop() {
    std::vector<PendingPacket> deferred;
    while (true) {
      std::vector<PendingPacket> batch;
      bool shutdown_now = false;
      bool finish_now = false;
      int64_t first_pts_snapshot = INT64_MIN;
      {
        std::unique_lock<std::mutex> qlock(queue_mutex_);
        queue_cv_.wait_for(qlock, std::chrono::milliseconds(100), [this] {
          return shutdown_requested_ || finish_requested_ || !io_queue_.empty();
        });
        shutdown_now = shutdown_requested_;
        finish_now = finish_requested_;
        first_pts_snapshot = first_pts_us_;
        batch.assign(std::make_move_iterator(io_queue_.begin()),
                     std::make_move_iterator(io_queue_.end()));
        io_queue_.clear();
      }

      if (shutdown_now) {
        // Drop any unwritten packets; main thread is going away.
        return;
      }

      {
        std::lock_guard<std::mutex> flock(format_mutex_);
        first_pts_us_writer_ = first_pts_snapshot;
        if (!header_written_) {
          if (CanWriteHeader_Locked(first_pts_snapshot)) {
            WriteHeader_Locked();
          }
        }
        if (header_written_) {
          for (auto& pkt : deferred) {
            WritePacket_Locked(pkt);
            if (!last_error_.empty()) break;
          }
          deferred.clear();
          for (auto& pkt : batch) {
            WritePacket_Locked(pkt);
            if (!last_error_.empty()) break;
          }
          batch.clear();
        } else {
          // Header still not writable (e.g. depth not yet configured).
          // Hold packets in the io thread's local deferred buffer so we
          // do not silently drop them when finish_requested_ is set later.
          for (auto& pkt : batch) {
            deferred.push_back(std::move(pkt));
          }
          batch.clear();
        }
      }

      if (finish_now) {
        bool queue_empty;
        {
          std::lock_guard<std::mutex> qlock(queue_mutex_);
          queue_empty = io_queue_.empty();
          if (queue_empty) {
            drained_ = true;
          }
        }
        if (queue_empty) {
          drain_cv_.notify_all();
          // Stay in the loop so a follow-up Close() can still join cleanly;
          // any further Enqueue is refused after finish_requested_ is set.
        }
      }
    }
  }

  bool CanWriteHeader_Locked(int64_t first_pts_snapshot) const {
    if (!format_context_ || !hevc_configured_) {
      return false;
    }
    if (depth_expected_ && !depth_configured_) {
      return false;
    }
    if (first_pts_snapshot == INT64_MIN) {
      return false;
    }
    return true;
  }

  bool WriteHeader_Locked() {
    PopulateTrackBaseTimeMetadata();
    const int open_ret = avio_open(&format_context_->pb, partial_path_.c_str(), AVIO_FLAG_WRITE);
    if (open_ret < 0) {
      return Fail("failed to open output mp4: " + AvError(open_ret));
    }
    const int header_ret = avformat_write_header(format_context_, nullptr);
    if (header_ret < 0) {
      return Fail("failed to write mp4 header: " + AvError(header_ret));
    }
    header_written_ = true;
    return true;
  }

  void EnsureContext() {
    if (format_context_) {
      return;
    }
    AVFormatContext* context = nullptr;
    const int ret = avformat_alloc_output_context2(&context, nullptr, "mp4", partial_path_.c_str());
    if (ret < 0 || !context) {
      throw std::runtime_error("failed to allocate MP4 context: " + AvError(ret));
    }
    format_context_ = context;
    if (controller_pose_expected_) {
      AddTimedMetadataStream(kTrackLeftControllerPose, "left_controller", "rigid_pose",
                             "spatialmp4.rigid_pose.v1", "application/x-spatialmp4-rigid-pose", "lctr");
      AddTimedMetadataStream(kTrackRightControllerPose, "right_controller", "rigid_pose",
                             "spatialmp4.rigid_pose.v1", "application/x-spatialmp4-rigid-pose", "rctr");
    }
    if (hand_joints_expected_) {
      AddTimedMetadataStream(kTrackLeftHandJoints, "left_hand", "hand_joints",
                             "spatialmp4.hand_joints.v1", "application/x-spatialmp4-hand-joints", "lhnd");
      AddTimedMetadataStream(kTrackRightHandJoints, "right_hand", "hand_joints",
                             "spatialmp4.hand_joints.v1", "application/x-spatialmp4-hand-joints", "rhnd");
    }
    if (controller_input_expected_) {
      AddTimedMetadataStream(kTrackLeftControllerInput, "left_controller_input", "controller_input",
                             "spatialmp4.controller_input.v1", "application/x-spatialmp4-controller-input",
                             "lcin");
      AddTimedMetadataStream(kTrackRightControllerInput, "right_controller_input", "controller_input",
                             "spatialmp4.controller_input.v1", "application/x-spatialmp4-controller-input",
                             "rcin");
    }
    // Create head last so simple stream-order readers still have the best
    // chance of picking head when they only support one pose stream.
    if (head_pose_expected_) {
      AddTimedMetadataStream(kTrackHeadPose, "head", "rigid_pose", "spatialmp4.rigid_pose.v1", "application/pose",
                             "head");
    }
  }

  void AddTimedMetadataStream(int track_id,
                              const char* track_name,
                              const char* metadata_kind,
                              const char* payload_schema,
                              const char* mime_type,
                              const char* pose_position) {
    if (track_id < 0 || track_id >= kTimedTrackCount || timed_streams_[track_id]) {
      return;
    }
    AVStream* stream = avformat_new_stream(format_context_, nullptr);
    if (!stream) {
      throw std::runtime_error("failed to create timed metadata stream");
    }
    timed_streams_[track_id] = stream;
    stream->time_base = kUsTimeBase;

    AVCodecParameters* codecpar = stream->codecpar;
    codecpar->codec_type = AVMEDIA_TYPE_DATA;
    codecpar->codec_id = AV_CODEC_ID_NONE;
    codecpar->codec_tag = MKTAG('m', 'e', 't', 't');

    // Encode track identity in handler_name ("spatialmp4:<kind>:<track_id>").
    // The MP4 muxer drops arbitrary per-stream metadata (track_id / metadata_kind
    // below) on the mux/demux round-trip, but the hdlr box handler_name survives,
    // so the reader relies on this to classify head / controller / hand / input
    // tracks. The plain metadata keys are kept for self-documentation and any
    // tooling that does preserve them.
    const std::string handler_name = std::string("spatialmp4:") + metadata_kind + ":" + track_name;
    av_dict_set(&stream->metadata, "handler_name", handler_name.c_str(), 0);

    av_dict_set(&stream->metadata, "track_id", track_name, 0);
    av_dict_set(&stream->metadata, "metadata_kind", metadata_kind, 0);
    av_dict_set(&stream->metadata, "payload_schema", payload_schema, 0);
    av_dict_set(&stream->metadata, "pose_position", pose_position, 0);
    av_dict_set(&stream->metadata, "mime_type", mime_type, 0);
    av_dict_set_int(&stream->metadata, "data_accuracy", 2, 0);
    if (std::strcmp(metadata_kind, "rigid_pose") == 0 || std::strcmp(metadata_kind, "hand_joints") == 0) {
      av_dict_set_int(&stream->metadata, "pose_coordinate", 1, 0);
    }
    if (std::strcmp(metadata_kind, "controller_input") == 0) {
      av_dict_set(&stream->metadata, "input_mapping", "openxr_quest_touch_controller.v1", 0);
    }
    av_dict_set_int(&stream->metadata, "track_base_time", 0, 0);
  }

  void PopulateTrackBaseTimeMetadata() {
    if (first_pts_us_writer_ == INT64_MIN) {
      return;
    }
    // track_base_time is the unix-epoch µs that container PTS=0 maps to,
    // derived from the session unix anchor and the Godot-ticks delta to the
    // first observed packet. The Godot-ticks value is also kept so consumers
    // that need the monotonic clock domain do not have to reverse-engineer it.
    int64_t track_base_unix_us = 0;
    if (session_start_unix_us_ > 0 && session_start_godot_ticks_us_ > 0) {
      track_base_unix_us = session_start_unix_us_ + (first_pts_us_writer_ - session_start_godot_ticks_us_);
    }
    const int64_t track_base_godot_ticks_us = first_pts_us_writer_;
    for (AVStream* stream : {rgb_stream_, depth_stream_}) {
      if (!stream) {
        continue;
      }
      av_dict_set_int(&stream->metadata, "track_base_time", track_base_unix_us, 0);
      av_dict_set_int(&stream->metadata, "track_base_godot_ticks_us", track_base_godot_ticks_us, 0);
      av_dict_set_int(&stream->metadata, "track_base_unix_us", track_base_unix_us, 0);
    }
    for (AVStream* stream : timed_streams_) {
      if (!stream) {
        continue;
      }
      av_dict_set_int(&stream->metadata, "track_base_time", track_base_unix_us, 0);
      av_dict_set_int(&stream->metadata, "track_base_godot_ticks_us", track_base_godot_ticks_us, 0);
      av_dict_set_int(&stream->metadata, "track_base_unix_us", track_base_unix_us, 0);
    }
  }

  bool WritePacket_Locked(const PendingPacket& pending) {
    if (pending.kind == PacketKind::kDepth && depth_enc_ctx_) {
      return EncodeAndWriteDepth_Locked(pending);
    }

    AVStream* stream = StreamForPacket(pending);
    if (!stream) {
      return true;
    }

    AVPacket* packet = av_packet_alloc();
    if (!packet) {
      return Fail("failed to allocate packet");
    }
    int ret = av_new_packet(packet, pending.data.size());
    if (ret < 0) {
      av_packet_free(&packet);
      return Fail("failed to allocate packet payload: " + AvError(ret));
    }
    std::memcpy(packet->data, pending.data.data(), pending.data.size());
    packet->stream_index = stream->index;
    int64_t adjusted_pts_us = pending.pts_us;
    if (first_pts_us_writer_ != INT64_MIN) {
      adjusted_pts_us -= first_pts_us_writer_;
      if (adjusted_pts_us < 0) {
        adjusted_pts_us = 0;
      }
    }
    packet->pts = adjusted_pts_us;
    packet->dts = adjusted_pts_us;
    packet->duration = pending.duration_us;
    packet->flags = pending.flags;

    ret = av_interleaved_write_frame(format_context_, packet);
    av_packet_free(&packet);
    if (ret < 0) {
      return Fail("failed to write packet: " + AvError(ret));
    }
    return true;
  }

  // Feed one raw GRAY16LE depth frame into the FFV1 encoder and mux whatever
  // packets come out. Runs on the io thread under format_mutex_, the only place
  // the encoder context is ever touched, so no extra synchronisation is needed.
  bool EncodeAndWriteDepth_Locked(const PendingPacket& pending) {
    if (!depth_enc_ctx_ || !depth_stream_ || !depth_frame_) {
      return true;
    }
    const size_t expected =
        static_cast<size_t>(depth_width_) * static_cast<size_t>(depth_height_) * 2u;
    if (pending.data.size() < expected) {
      return Fail("depth frame payload shorter than width*height*2");
    }
    int ret = av_frame_make_writable(depth_frame_);
    if (ret < 0) {
      return Fail("depth frame not writable: " + AvError(ret));
    }
    // Copy row by row to honour the frame's linesize (FFmpeg may pad rows wider
    // than width*2). The source is tightly packed little-endian uint16.
    const uint8_t* src = pending.data.data();
    const int src_stride = depth_width_ * 2;
    for (int y = 0; y < depth_height_; ++y) {
      std::memcpy(depth_frame_->data[0] + static_cast<ptrdiff_t>(y) * depth_frame_->linesize[0],
                  src + static_cast<ptrdiff_t>(y) * src_stride,
                  static_cast<size_t>(src_stride));
    }

    int64_t adjusted_pts_us = pending.pts_us;
    if (first_pts_us_writer_ != INT64_MIN) {
      adjusted_pts_us -= first_pts_us_writer_;
      if (adjusted_pts_us < 0) {
        adjusted_pts_us = 0;
      }
    }
    depth_frame_->pts = adjusted_pts_us;

    ret = avcodec_send_frame(depth_enc_ctx_, depth_frame_);
    if (ret < 0) {
      return Fail("failed to send depth frame to encoder: " + AvError(ret));
    }
    return DrainDepthEncoder_Locked(pending.duration_us);
  }

  // Pull every ready packet out of the FFV1 encoder and interleave it into the
  // mp4. Used both for steady-state frames and (with a flushed encoder) at
  // Finish(). duration_us is applied when the encoder leaves it unset.
  bool DrainDepthEncoder_Locked(int64_t duration_us) {
    AVPacket* packet = av_packet_alloc();
    if (!packet) {
      return Fail("failed to allocate depth packet");
    }
    bool ok = true;
    while (true) {
      int ret = avcodec_receive_packet(depth_enc_ctx_, packet);
      if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
        break;
      }
      if (ret < 0) {
        ok = Fail("failed to receive depth packet: " + AvError(ret));
        break;
      }
      packet->stream_index = depth_stream_->index;
      av_packet_rescale_ts(packet, depth_enc_ctx_->time_base, depth_stream_->time_base);
      if (packet->duration <= 0 && duration_us > 0) {
        packet->duration = duration_us;
      }
      ret = av_interleaved_write_frame(format_context_, packet);
      av_packet_unref(packet);
      if (ret < 0) {
        ok = Fail("failed to write depth packet: " + AvError(ret));
        break;
      }
    }
    av_packet_free(&packet);
    return ok;
  }

  // Drain any buffered depth frames before the trailer is written. FFV1 has no
  // reordering delay so this is normally a no-op, but flushing is the correct
  // contract and protects against future codec changes.
  void FlushDepthEncoder_Locked() {
    if (!depth_enc_ctx_ || !depth_stream_ || !header_written_) {
      return;
    }
    if (avcodec_send_frame(depth_enc_ctx_, nullptr) >= 0) {
      DrainDepthEncoder_Locked(0);
    }
  }

  AVStream* StreamForPacket(const PendingPacket& pending) const {
    switch (pending.kind) {
      case PacketKind::kRgb:
        return rgb_stream_;
      case PacketKind::kDepth:
        return depth_stream_;
      case PacketKind::kTimedMetadata:
        if (pending.timed_track_id < 0 || pending.timed_track_id >= static_cast<int>(timed_streams_.size())) {
          return nullptr;
        }
        return timed_streams_[pending.timed_track_id];
    }
    return nullptr;
  }

  bool Fail(const std::string& message) {
    last_error_ = message;
    __android_log_print(ANDROID_LOG_ERROR, kTag, "%s", message.c_str());
    return false;
  }

  void CloseUnlocked() {
    // Free the FFV1 encoder before the format context. The encoder owns its own
    // buffers (independent of the muxer streams), so order is not strictly
    // required, but releasing it first keeps the teardown easy to reason about.
    if (depth_enc_ctx_) {
      avcodec_free_context(&depth_enc_ctx_);
    }
    if (depth_frame_) {
      av_frame_free(&depth_frame_);
    }
    if (format_context_) {
      if (format_context_->pb) {
        avio_closep(&format_context_->pb);
      }
      avformat_free_context(format_context_);
      format_context_ = nullptr;
    }
    // The stream pointers were owned by format_context_; null them out so any
    // late StreamForKind lookup turns into a no-op rather than dereferencing
    // freed memory.
    rgb_stream_ = nullptr;
    depth_stream_ = nullptr;
    std::fill(timed_streams_.begin(), timed_streams_.end(), nullptr);
  }

  // --- FFmpeg / writer-thread state (guarded by format_mutex_) ---
  mutable std::mutex format_mutex_;
  std::string partial_path_;
  std::string final_path_;
  int64_t session_start_unix_us_ = 0;
  int64_t session_start_godot_ticks_us_ = 0;
  // Snapshot of first_pts_us_ taken by the io thread under queue_mutex_ and
  // mirrored here for WriteHeader/WritePacket. Format-side code uses this
  // instead of reaching across into queue_mutex_ on every packet write.
  int64_t first_pts_us_writer_ = INT64_MIN;
  int rgb_width_ = 0;
  int rgb_height_ = 0;
  int rgb_fps_ = 30;
  int rgb_camera_count_ = 1;
  bool depth_expected_ = false;
  bool head_pose_expected_ = true;
  bool controller_pose_expected_ = false;
  bool hand_joints_expected_ = false;
  bool controller_input_expected_ = false;
  bool hevc_configured_ = false;
  bool depth_configured_ = false;
  bool header_written_ = false;
  bool finished_ = false;
  SideDataBundle rgb_side_data_;
  AVFormatContext* format_context_ = nullptr;
  AVStream* rgb_stream_ = nullptr;
  AVStream* depth_stream_ = nullptr;
  // FFV1 depth encoder state (guarded by format_mutex_, used only on io thread).
  AVCodecContext* depth_enc_ctx_ = nullptr;
  AVFrame* depth_frame_ = nullptr;
  int depth_width_ = 0;
  int depth_height_ = 0;
  std::vector<AVStream*> timed_streams_;
  std::string last_error_;

  // --- Producer/consumer queue (guarded by queue_mutex_) ---
  mutable std::mutex queue_mutex_;
  std::condition_variable queue_cv_;
  std::condition_variable drain_cv_;
  std::deque<PendingPacket> io_queue_;
  int64_t first_pts_us_ = INT64_MIN;
  bool shutdown_requested_ = false;
  bool finish_requested_ = false;
  bool drained_ = false;
  std::thread io_thread_;
};

LiveSpatialMp4Writer* FromHandle(jlong handle) {
  return reinterpret_cast<LiveSpatialMp4Writer*>(handle);
}

std::vector<uint8_t> PackPose(double px, double py, double pz, double qx, double qy, double qz, double qw) {
  const double values[7] = {px, py, pz, qx, qy, qz, qw};
  std::vector<uint8_t> out(sizeof(values));
  std::memcpy(out.data(), values, sizeof(values));
  return out;
}

}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_spatialmp4_questcapture_SpatialMp4Native_nativeStart(
    JNIEnv* env,
    jclass,
    jstring partial_path,
    jstring final_path,
    jlong session_start_unix_us,
    jlong session_start_godot_ticks_us,
    jint rgb_width,
    jint rgb_height,
    jint rgb_fps,
    jint rgb_camera_count,
    jboolean depth_expected,
    jboolean head_pose_expected,
    jboolean controller_pose_expected,
    jboolean hand_joints_expected,
    jboolean controller_input_expected,
    jbyteArray rgb_icam,
    jbyteArray rgb_ecam,
    jbyteArray rgb_dstr) {
  SideDataBundle side_data{
      JByteArrayToVector(env, rgb_icam),
      JByteArrayToVector(env, rgb_ecam),
      JByteArrayToVector(env, rgb_dstr),
  };
  auto* writer = new (std::nothrow) LiveSpatialMp4Writer(
      JStringToString(env, partial_path),
      JStringToString(env, final_path),
      static_cast<int64_t>(session_start_unix_us),
      static_cast<int64_t>(session_start_godot_ticks_us),
      static_cast<int>(rgb_width),
      static_cast<int>(rgb_height),
      static_cast<int>(rgb_fps),
      static_cast<int>(rgb_camera_count),
      depth_expected == JNI_TRUE,
      head_pose_expected == JNI_TRUE,
      controller_pose_expected == JNI_TRUE,
      hand_joints_expected == JNI_TRUE,
      controller_input_expected == JNI_TRUE,
      std::move(side_data));
  return reinterpret_cast<jlong>(writer);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_spatialmp4_questcapture_SpatialMp4Native_nativeConfigureHevc(
    JNIEnv* env,
    jclass,
    jlong handle,
    jbyteArray csd) {
  auto* writer = FromHandle(handle);
  if (!writer) {
    return JNI_FALSE;
  }
  return writer->ConfigureHevc(JByteArrayToVector(env, csd)) ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_spatialmp4_questcapture_SpatialMp4Native_nativeConfigureDepth(
    JNIEnv* env,
    jclass,
    jlong handle,
    jint width,
    jint height,
    jbyteArray depth_icam,
    jbyteArray depth_ecam,
    jbyteArray depth_dstr) {
  auto* writer = FromHandle(handle);
  if (!writer) {
    return JNI_FALSE;
  }
  SideDataBundle side_data{
      JByteArrayToVector(env, depth_icam),
      JByteArrayToVector(env, depth_ecam),
      JByteArrayToVector(env, depth_dstr),
  };
  return writer->ConfigureDepth(width, height, std::move(side_data)) ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_spatialmp4_questcapture_SpatialMp4Native_nativeWriteHevcPacket(
    JNIEnv* env,
    jclass,
    jlong handle,
    jbyteArray data,
    jlong pts_us,
    jlong duration_us,
    jint flags) {
  auto* writer = FromHandle(handle);
  if (!writer) {
    return JNI_FALSE;
  }
  return writer->WriteRgb(JByteArrayToVector(env, data), pts_us, duration_us, flags) ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_spatialmp4_questcapture_SpatialMp4Native_nativeWriteDepthPacket(
    JNIEnv* env,
    jclass,
    jlong handle,
    jbyteArray data,
    jlong pts_us,
    jlong duration_us) {
  auto* writer = FromHandle(handle);
  if (!writer) {
    return JNI_FALSE;
  }
  return writer->WriteDepth(JByteArrayToVector(env, data), pts_us, duration_us) ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_spatialmp4_questcapture_SpatialMp4Native_nativeWriteHeadPose(
    JNIEnv*,
    jclass,
    jlong handle,
    jlong pts_us,
    jlong duration_us,
    jdouble px,
    jdouble py,
    jdouble pz,
    jdouble qx,
    jdouble qy,
    jdouble qz,
    jdouble qw) {
  auto* writer = FromHandle(handle);
  if (!writer) {
    return JNI_FALSE;
  }
  return writer->WriteTimedMetadata(kTrackHeadPose, PackPose(px, py, pz, qx, qy, qz, qw), pts_us, duration_us)
             ? JNI_TRUE
             : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_spatialmp4_questcapture_SpatialMp4Native_nativeWriteRigidPose(
    JNIEnv*,
    jclass,
    jlong handle,
    jint track_id,
    jlong pts_us,
    jlong duration_us,
    jdouble px,
    jdouble py,
    jdouble pz,
    jdouble qx,
    jdouble qy,
    jdouble qz,
    jdouble qw) {
  auto* writer = FromHandle(handle);
  if (!writer) {
    return JNI_FALSE;
  }
  return writer->WriteTimedMetadata(static_cast<int>(track_id), PackPose(px, py, pz, qx, qy, qz, qw), pts_us,
                                    duration_us)
             ? JNI_TRUE
             : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_spatialmp4_questcapture_SpatialMp4Native_nativeWriteTimedMetadata(
    JNIEnv* env,
    jclass,
    jlong handle,
    jint track_id,
    jbyteArray data,
    jlong pts_us,
    jlong duration_us) {
  auto* writer = FromHandle(handle);
  if (!writer) {
    return JNI_FALSE;
  }
  return writer->WriteTimedMetadata(static_cast<int>(track_id), JByteArrayToVector(env, data), pts_us, duration_us)
             ? JNI_TRUE
             : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_spatialmp4_questcapture_SpatialMp4Native_nativeFinish(JNIEnv*, jclass, jlong handle) {
  auto* writer = FromHandle(handle);
  if (!writer) {
    return JNI_FALSE;
  }
  return writer->Finish() ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_spatialmp4_questcapture_SpatialMp4Native_nativeClose(JNIEnv*, jclass, jlong handle) {
  auto* writer = FromHandle(handle);
  delete writer;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_spatialmp4_questcapture_SpatialMp4Native_nativeGetLastError(JNIEnv* env, jclass, jlong handle) {
  auto* writer = FromHandle(handle);
  if (!writer) {
    return StringToJString(env, "writer handle is null");
  }
  return StringToJString(env, writer->LastError());
}
