// native_hand_sampler.cpp — see native_hand_sampler.h for the design notes.

#include "native_hand_sampler.h"
#include "hjnt_pack.h"
#include "variant_json.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/xr_hand_tracker.hpp>
#include <godot_cpp/classes/xr_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cinttypes>

namespace godot {

namespace {

inline uint64_t instance_id_of(Object *p_object) {
    return p_object != nullptr ? uint64_t(p_object->get_instance_id()) : 0;
}

inline Object *resolve_instance(uint64_t p_id) {
    return p_id != 0 ? ObjectDB::get_instance(ObjectID(p_id)) : nullptr;
}

} // namespace

NativeHandSampler::~NativeHandSampler() {
    end_jsonl();
}

void NativeHandSampler::_bind_methods() {
    ClassDB::bind_method(D_METHOD("configure", "muxer_plugin", "live_plugin", "xr_origin"),
                         &NativeHandSampler::configure);
    ClassDB::bind_method(D_METHOD("set_live_interval_us", "interval_us"),
                         &NativeHandSampler::set_live_interval_us);
    ClassDB::bind_method(D_METHOD("set_muxer_writes_enabled", "enabled"),
                         &NativeHandSampler::set_muxer_writes_enabled);
    ClassDB::bind_method(D_METHOD("begin_jsonl", "absolute_path"),
                         &NativeHandSampler::begin_jsonl);
    ClassDB::bind_method(D_METHOD("end_jsonl"), &NativeHandSampler::end_jsonl);
    ClassDB::bind_method(D_METHOD("is_jsonl_active"),
                         &NativeHandSampler::is_jsonl_active);
    ClassDB::bind_method(D_METHOD("sample", "timestamp_ns"),
                         &NativeHandSampler::sample);
    ClassDB::bind_method(D_METHOD("pop_metrics"),
                         &NativeHandSampler::pop_metrics);
}

void NativeHandSampler::configure(Object *p_muxer_plugin, Object *p_live_plugin,
                                  Node3D *p_xr_origin) {
    muxer_instance_id_ = instance_id_of(p_muxer_plugin);
    live_instance_id_ = instance_id_of(p_live_plugin);
    // XRHandTracker joints are already populated directly from
    // xrLocateHandJointsEXT(..., play_space, ...). Do not multiply the Godot
    // XROrigin3D transform here: that would silently rebase hand data into a
    // scene/world space while head and controllers remain in play_space.
    (void)p_xr_origin;
}

void NativeHandSampler::set_live_interval_us(int64_t p_interval_us) {
    live_interval_us_ = p_interval_us > 0 ? p_interval_us : 0;
}

void NativeHandSampler::set_muxer_writes_enabled(bool p_enabled) {
    muxer_writes_enabled_ = p_enabled;
}

bool NativeHandSampler::begin_jsonl(const String &p_absolute_path) {
    return jsonl_.begin(p_absolute_path);
}

void NativeHandSampler::end_jsonl() {
    jsonl_.end();
}

bool NativeHandSampler::is_jsonl_active() const {
    return jsonl_.active();
}

int64_t NativeHandSampler::sample(int64_t p_timestamp_ns) {
    // XRHandTracker data advances once per rendered XR frame; the pose loop
    // can run more than one iteration per frame, so dedupe on the process
    // frame counter to capture exactly the native rate without duplicates.
    Engine *engine = Engine::get_singleton();
    if (engine != nullptr) {
        const uint64_t frame = engine->get_process_frames();
        if (frame == last_process_frame_) {
            return 0;
        }
        last_process_frame_ = frame;
    }

    Object *muxer = muxer_writes_enabled_ ? resolve_instance(muxer_instance_id_) : nullptr;
    Object *live = resolve_instance(live_instance_id_);
    if (muxer == nullptr && live == nullptr && !jsonl_.active()) {
        return 0;
    }

    // The live throttle clock is only advanced after a hand actually pushed
    // to the wire (see below) — a due slot on a frame with no tracking data
    // stays due, so intermittent tracking does not silently halve the
    // effective live rate.
    bool live_due = false;
    uint64_t now_us = 0;
    if (live != nullptr) {
        now_us = Time::get_singleton()->get_ticks_usec();
        live_due = live_interval_us_ <= 0 ||
                now_us - last_live_push_us_ >= uint64_t(live_interval_us_);
    }

    // Locals (not static) so no godot StringName outlives the library:
    // interning is a cheap hash lookup at 2 calls/frame.
    const StringName left_tracker("/user/hand_tracker/left");
    const StringName right_tracker("/user/hand_tracker/right");
    int written = 0;
    bool live_written = false;
    written += sample_hand(muxer, live, live_due, "left", left_tracker,
                           p_timestamp_ns, live_written);
    written += sample_hand(muxer, live, live_due, "right", right_tracker,
                           p_timestamp_ns, live_written);
    if (live_written) {
        last_live_push_us_ = now_us;
    }
    return written;
}

int NativeHandSampler::sample_hand(Object *p_muxer, Object *p_live, bool p_live_due,
                                   const char *p_hand,
                                   const StringName &p_tracker_name,
                                   int64_t p_timestamp_ns, bool &r_live_written) {
    const bool want_payload = p_muxer != nullptr;
    const bool want_live = p_live != nullptr && p_live_due;
    // The joints JSON array is shared verbatim between the live wire format
    // (legacy JSON.stringify(joints)) and the jsonl sidecar record, so it is
    // built at most once per hand per frame.
    const bool want_json = jsonl_.active() || want_live;
    if (!want_payload && !want_json) {
        // Nothing to emit this frame (e.g. live-only mode between throttle
        // slots): skip the joint read entirely and leave metrics untouched.
        return 0;
    }

    XRServer *xr_server = XRServer::get_singleton();
    if (xr_server == nullptr) {
        return 0;
    }
    Ref<XRHandTracker> tracker = xr_server->get_tracker(p_tracker_name);
    if (tracker.is_null() || !tracker->get_has_tracking_data()) {
        return 0;
    }

    constexpr int joint_count = XRHandTracker::HAND_JOINT_MAX;

    uint8_t *w = nullptr;
    if (want_payload) {
        payload_scratch_.resize(hjnt::kHeaderBytes + joint_count * hjnt::kJointRecordBytes);
        w = payload_scratch_.ptrw();
        hjnt::pack_header(w, static_cast<uint16_t>(joint_count));
        w += hjnt::kHeaderBytes;
    }

    std::string &joints_json = joints_json_scratch_;
    if (want_json) {
        joints_json.clear();
        if (joints_json.capacity() < 8192) {
            joints_json.reserve(8192);
        }
        joints_json += '[';
    }

    for (int joint = 0; joint < joint_count; joint++) {
        const XRHandTracker::HandJoint hand_joint =
                static_cast<XRHandTracker::HandJoint>(joint);
        Transform3D transform = tracker->get_hand_joint_transform(hand_joint);
        const uint64_t flags = uint64_t(tracker->get_hand_joint_flags(hand_joint));
        const float radius = tracker->get_hand_joint_radius(hand_joint);
        const Vector3 position = transform.origin;
        const Quaternion rotation = transform.basis.get_rotation_quaternion();

        if (want_payload) {
            hjnt::pack_joint(w, static_cast<uint16_t>(joint),
                             static_cast<uint16_t>(flags), radius, position, rotation);
            w += hjnt::kJointRecordBytes;
        }

        if (want_json) {
            if (joint > 0) {
                joints_json += ',';
            }
            char prefix[64];
            std::snprintf(prefix, sizeof(prefix), "{\"joint\":%d,\"flags\":%" PRIu64
                                                  ",\"radius_m\":",
                          joint, flags);
            joints_json += prefix;
            append_json_float(joints_json, radius);
            joints_json += ",\"position\":";
            append_xyz_json(joints_json, position);
            joints_json += ",\"rotation\":";
            append_xyzw_json(joints_json, rotation);
            joints_json += '}';
        }
    }
    if (want_json) {
        joints_json += ']';
    }

    const String hand_name(p_hand);
    if (want_payload) {
        p_muxer->call("writeHandJointsPayload", hand_name, p_timestamp_ns,
                      payload_scratch_);
    }
    if (want_live) {
        p_live->call("writeHandJointsJson", hand_name, p_timestamp_ns,
                     String::utf8(joints_json.data(), int(joints_json.size())));
        metric_live_writes_ += 1;
        r_live_written = true;
    }
    metric_hand_writes_ += 1;
    metric_hand_joints_ += joint_count;

    if (jsonl_.active()) {
        std::string &line = line_scratch_;
        line.clear();
        if (line.capacity() < joints_json.size() + 128) {
            line.reserve(joints_json.size() + 128);
        }
        char head[96];
        std::snprintf(head, sizeof(head),
                      "{\"timestamp_ns\":%" PRId64 ",\"hand\":\"%s\",\"joint_count\":%d,\"joints\":",
                      p_timestamp_ns, p_hand, joint_count);
        line += head;
        line += joints_json;
        line += '}';
        // Move, not copy: `line` is dead after this and cleared next use.
        jsonl_.enqueue(std::move(line));
    }
    return 1;
}

Dictionary NativeHandSampler::pop_metrics() {
    Dictionary metrics;
    metrics["hand_writes"] = static_cast<int64_t>(metric_hand_writes_);
    metrics["hand_joints"] = static_cast<int64_t>(metric_hand_joints_);
    metrics["live_writes"] = static_cast<int64_t>(metric_live_writes_);
    metrics["jsonl_lines"] = static_cast<int64_t>(jsonl_.pop_lines());
    metrics["jsonl_dropped"] = static_cast<int64_t>(jsonl_.pop_dropped());
    metric_hand_writes_ = 0;
    metric_hand_joints_ = 0;
    metric_live_writes_ = 0;
    return metrics;
}

} // namespace godot
