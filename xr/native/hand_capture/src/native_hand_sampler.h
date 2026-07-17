// native_hand_sampler.h — full-rate hand-joint capture for the Operator XR
// client.
//
// Why this exists: the legacy GDScript hand path built ~80 nested
// Dictionaries per sample (26 joints x 2 hands x {joint, position, rotation})
// and JSON.stringify'd them on the main thread, which forced a 30 Hz throttle
// to protect 72 Hz rendering. This class owns the entire hand pipeline in
// C++: it reads XRHandTracker joints once per rendered XR frame (72/90 Hz)
// and fans out to every hand consumer directly:
//
//   - mp4 mett track (ego capture): HJNT v1 payload — byte-identical to the
//     old session_spool_writer.gd _pack_hand_joints_payload — via
//     muxer.writeHandJointsPayload (JNI singleton call).
//   - live push/feed: the same joints serialized to JSON via
//     live.writeHandJointsJson — the exact wire shape the old
//     LivePushWriter.write_hand_joints produced with JSON.stringify(joints).
//     Rate-limited (default 30 Hz) to preserve the wire bandwidth contract.
// There is no GDScript fallback: hand capture requires this extension
// (Android arm64). The desktop editor has no hand-tracking runtime anyway.

#ifndef HAND_CAPTURE_NATIVE_HAND_SAMPLER_H
#define HAND_CAPTURE_NATIVE_HAND_SAMPLER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>
#include <string>

namespace godot {

class Node3D;
class Object;

class NativeHandSampler : public RefCounted {
    GDCLASS(NativeHandSampler, RefCounted)

public:
    NativeHandSampler() = default;

    // Main-thread API (called from pose_sampler.gd). Either plugin may be
    // null: ego capture passes the muxer, live modes pass the live server.
    void configure(Object *p_muxer_plugin, Object *p_live_plugin, Node3D *p_xr_origin);
    // Minimum spacing between writeHandJointsJson pushes (per hand pair).
    // Default 33333 us (30 Hz) preserves the legacy wire rate; 0 = full rate.
    void set_live_interval_us(int64_t p_interval_us);
    // The shared Quest/PICO OpenXR worker owns the MP4 hand tracks at 60 Hz.
    // Disable only this sampler's muxer fanout while retaining live JSON.
    void set_muxer_writes_enabled(bool p_enabled);
    // Samples both hand trackers once per Godot process frame (repeat calls
    // within the same frame are deduped, so the 90 Hz pose loop cannot write
    // duplicate joint data when two loop iterations land in one frame).
    // Returns the number of hand frames captured this call.
    int64_t sample(int64_t p_timestamp_ns);
    Dictionary pop_metrics();

protected:
    static void _bind_methods();

private:
    // r_live_written is set true when this hand pushed to the live plugin;
    // the caller advances the live throttle clock only in that case.
    int sample_hand(Object *p_muxer, Object *p_live, bool p_live_due,
                    const char *p_hand, const StringName &p_tracker_name,
                    int64_t p_timestamp_ns, bool &r_live_written);

    uint64_t muxer_instance_id_ = 0;
    uint64_t live_instance_id_ = 0;
    uint64_t last_process_frame_ = UINT64_MAX;
    int64_t live_interval_us_ = 33333; // 30 Hz wire default.
    uint64_t last_live_push_us_ = 0;
    bool muxer_writes_enabled_ = true;

    // 1 Hz metrics surface, mirrored into pose_sampler.pop_metrics().
    uint64_t metric_hand_writes_ = 0;
    uint64_t metric_hand_joints_ = 0;
    uint64_t metric_live_writes_ = 0;

    // Reused scratch buffers (main thread only).
    PackedByteArray payload_scratch_;
    std::string joints_json_scratch_;
};

} // namespace godot

#endif // HAND_CAPTURE_NATIVE_HAND_SAMPLER_H
