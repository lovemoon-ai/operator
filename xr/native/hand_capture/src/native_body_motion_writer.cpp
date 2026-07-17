// native_body_motion_writer.cpp — see header for design notes.

#include "native_body_motion_writer.h"
#include "hjnt_pack.h"
#include "variant_json.h"

#include <godot_cpp/classes/xr_body_tracker.hpp>
#include <godot_cpp/classes/xr_server.hpp>
#include <godot_cpp/classes/xr_tracker.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cinttypes>
#include <cstring>

namespace godot {

namespace {

// HJNT packing lives in the shared hjnt_pack.h (single wire-format source).
constexpr int kBodyJointCount = XRBodyTracker::JOINT_MAX; // 87

// Reads a {"x","y","z"} dict, Vector3, or [x,y,z] array (the pico bridge has
// produced all three shapes historically — mirrors _pico_joint_position).
Vector3 variant_to_vec3(const Variant &v) {
    switch (v.get_type()) {
        case Variant::VECTOR3:
            return Vector3(v);
        case Variant::DICTIONARY: {
            const Dictionary d = v;
            return Vector3(float(d.get("x", 0.0)), float(d.get("y", 0.0)),
                           float(d.get("z", 0.0)));
        }
        case Variant::ARRAY: {
            const Array a = v;
            if (a.size() >= 3) {
                return Vector3(float(a[0]), float(a[1]), float(a[2]));
            }
            return Vector3();
        }
        default:
            return Vector3();
    }
}

Quaternion variant_to_quat(const Variant &v) {
    switch (v.get_type()) {
        case Variant::QUATERNION:
            return Quaternion(v);
        case Variant::DICTIONARY: {
            const Dictionary d = v;
            return Quaternion(float(d.get("x", 0.0)), float(d.get("y", 0.0)),
                              float(d.get("z", 0.0)), float(d.get("w", 1.0)));
        }
        default:
            return Quaternion();
    }
}

// Joint dict serialized with _json_safe_joint_record semantics: every key in
// insertion order except "transform".
void append_joint_record_json(std::string &out, const Dictionary &joint) {
    const Array keys = joint.keys();
    out += '{';
    bool first = true;
    for (int64_t i = 0; i < keys.size(); i++) {
        const String key = String(keys[i]);
        if (key == String("transform")) {
            continue;
        }
        if (!first) out += ',';
        first = false;
        append_json_string(out, key);
        out += ':';
        append_json_safe_value(out, joint[keys[i]]);
    }
    out += '}';
}

void append_metadata_extras(std::string &out, const Dictionary &metadata,
                            const char *const *skip_keys, int skip_count) {
    const Array keys = metadata.keys();
    for (int64_t i = 0; i < keys.size(); i++) {
        const String key = String(keys[i]);
        bool skip = false;
        for (int s = 0; s < skip_count; s++) {
            if (key == String(skip_keys[s])) {
                skip = true;
                break;
            }
        }
        if (skip) {
            continue;
        }
        out += ',';
        append_json_string(out, key);
        out += ':';
        append_json_safe_value(out, metadata[keys[i]]);
    }
}

} // namespace

NativeBodyMotionWriter::~NativeBodyMotionWriter() {
    end_session();
}

void NativeBodyMotionWriter::_bind_methods() {
    ClassDB::bind_method(D_METHOD("configure", "muxer_plugin"),
                         &NativeBodyMotionWriter::configure);
    ClassDB::bind_method(D_METHOD("begin_session", "body_jsonl_path", "motion_jsonl_path"),
                         &NativeBodyMotionWriter::begin_session);
    ClassDB::bind_method(D_METHOD("end_session"), &NativeBodyMotionWriter::end_session);
    ClassDB::bind_method(D_METHOD("sample_body_tracker", "timestamp_ns"),
                         &NativeBodyMotionWriter::sample_body_tracker);
    ClassDB::bind_method(D_METHOD("write_body_joints", "timestamp_ns", "body_flags", "joints", "metadata"),
                         &NativeBodyMotionWriter::write_body_joints);
    ClassDB::bind_method(D_METHOD("write_motion_tracker_pose", "tracker_index", "source", "timestamp_ns", "transform", "tracking_valid", "metadata"),
                         &NativeBodyMotionWriter::write_motion_tracker_pose);
    ClassDB::bind_method(D_METHOD("write_motion_tracker_event", "timestamp_ns", "event_type", "event"),
                         &NativeBodyMotionWriter::write_motion_tracker_event);
    ClassDB::bind_method(D_METHOD("pop_metrics"), &NativeBodyMotionWriter::pop_metrics);
}

void NativeBodyMotionWriter::configure(Object *p_muxer_plugin) {
    muxer_instance_id_ =
            p_muxer_plugin != nullptr ? uint64_t(p_muxer_plugin->get_instance_id()) : 0;
    contract_version_ = -1;
}

void NativeBodyMotionWriter::begin_session(const String &p_body_jsonl_path,
                                           const String &p_motion_jsonl_path) {
    body_jsonl_.begin(p_body_jsonl_path);
    motion_jsonl_.begin(p_motion_jsonl_path);
}

void NativeBodyMotionWriter::end_session() {
    body_jsonl_.end();
    motion_jsonl_.end();
}

Object *NativeBodyMotionWriter::resolve_muxer() {
    return muxer_instance_id_ != 0
            ? ObjectDB::get_instance(ObjectID(muxer_instance_id_))
            : nullptr;
}

// Mirrors session_spool_writer.gd's contract-v5 gate for metadata-json
// tracks (older muxer AARs lack the writeBodyFrameMetadataJson surface).
bool NativeBodyMotionWriter::metadata_supported(Object *p_muxer) {
    if (p_muxer == nullptr) {
        return false;
    }
    if (contract_version_ < 0) {
        const Variant version = p_muxer->call("getMuxerContractVersion");
        contract_version_ =
                (version.get_type() == Variant::INT || version.get_type() == Variant::FLOAT)
                ? int(int64_t(version))
                : 0;
    }
    return contract_version_ >= 5;
}

// Shared tail of both body paths: payload_scratch_ + json_scratch_ are
// ready; push them to the muxer + jsonl sidecar.
void NativeBodyMotionWriter::emit_body(Object *p_muxer, int64_t p_timestamp_ns) {
    if (p_muxer != nullptr) {
        p_muxer->call("writeBodyJointsPayload", p_timestamp_ns, payload_scratch_);
        if (metadata_supported(p_muxer)) {
            p_muxer->call("writeBodyFrameMetadataJson", p_timestamp_ns,
                          String::utf8(json_scratch_.data(), int(json_scratch_.size())));
        }
    }
    if (body_jsonl_.active()) {
        // Move, not copy: json_scratch_ is dead after emit and cleared on
        // its next use.
        body_jsonl_.enqueue(std::move(json_scratch_));
    }
}

Dictionary NativeBodyMotionWriter::sample_body_tracker(int64_t p_timestamp_ns) {
    Dictionary result;
    result["status"] = String("no_tracker");
    result["wrote"] = false;
    result["joint_count"] = 0;
    result["body_flags"] = 0;

    Object *muxer = resolve_muxer();
    if (muxer == nullptr && !body_jsonl_.active()) {
        result["status"] = String("no_muxer");
        return result;
    }

    XRServer *xr_server = XRServer::get_singleton();
    if (xr_server == nullptr) {
        return result;
    }
    Ref<XRTracker> base_tracker = xr_server->get_tracker(StringName("/user/body_tracker"));
    if (base_tracker.is_null()) {
        return result;
    }
    Ref<XRBodyTracker> tracker = base_tracker;
    if (tracker.is_null()) {
        // A tracker is registered at the body path but is not an
        // XRBodyTracker — distinct diagnostic so bring-up doesn't chase
        // permissions when the runtime registered the wrong class.
        result["status"] = String("wrong_tracker_class");
        result["tracker_class"] = base_tracker->get_class();
        return result;
    }
    if (!tracker->get_has_tracking_data()) {
        result["status"] = String("no_tracking_data");
        result["body_flags"] = int64_t(uint64_t(tracker->get_body_flags()));
        return result;
    }

    const int64_t body_flags = int64_t(uint64_t(tracker->get_body_flags()));
    payload_scratch_.resize(hjnt::kHeaderBytes + kBodyJointCount * hjnt::kJointRecordBytes);
    uint8_t *base = payload_scratch_.ptrw();
    uint8_t *w = base + hjnt::kHeaderBytes;

    std::string &json = json_scratch_;
    json.clear();
    if (json.capacity() < 16384) {
        json.reserve(16384);
    }
    // Record head is finished after the joint loop (joint_count unknown yet);
    // build the joints array into the scratch first.
    std::string joints_json;
    joints_json.reserve(12288);
    joints_json += '[';

    int joint_count = 0;
    for (int joint = 0; joint < kBodyJointCount; joint++) {
        const XRBodyTracker::Joint body_joint = static_cast<XRBodyTracker::Joint>(joint);
        const uint64_t flags = uint64_t(tracker->get_joint_flags(body_joint));
        if (flags == 0) {
            continue;
        }
        const Transform3D transform = tracker->get_joint_transform(body_joint);
        const Vector3 p = transform.origin;
        const Quaternion q = transform.basis.get_rotation_quaternion();

        hjnt::pack_joint(w, static_cast<uint16_t>(joint), static_cast<uint16_t>(flags), 0.0f, p, q);
        w += hjnt::kJointRecordBytes;

        if (joint_count > 0) {
            joints_json += ',';
        }
        char prefix[64];
        std::snprintf(prefix, sizeof(prefix),
                      "{\"joint\":%d,\"flags\":%" PRIu64 ",\"radius_m\":0.0,\"position\":",
                      joint, flags);
        joints_json += prefix;
        append_xyz_json(joints_json, p);
        joints_json += ",\"rotation\":";
        append_xyzw_json(joints_json, q);
        joints_json += '}';
        joint_count += 1;
    }
    joints_json += ']';

    if (joint_count == 0) {
        result["status"] = String("no_joints");
        result["body_flags"] = body_flags;
        return result;
    }

    // Finalize payload: patch header + shrink to the active joint count.
    hjnt::pack_header(base, static_cast<uint16_t>(joint_count));
    payload_scratch_.resize(hjnt::kHeaderBytes + joint_count * hjnt::kJointRecordBytes);

    char head[96];
    std::snprintf(head, sizeof(head),
                  "{\"timestamp_ns\":%" PRId64 ",\"body_flags\":%" PRId64
                  ",\"joint_count\":%d,\"joints\":",
                  p_timestamp_ns, body_flags, joint_count);
    json += head;
    json += joints_json;
    json += '}';

    emit_body(muxer, p_timestamp_ns);
    metric_body_writes_ += 1;
    metric_body_joints_ += joint_count;

    result["status"] = String("wrote");
    result["wrote"] = true;
    result["joint_count"] = joint_count;
    result["body_flags"] = body_flags;
    return result;
}

bool NativeBodyMotionWriter::write_body_joints(int64_t p_timestamp_ns, int64_t p_body_flags,
                                               const Array &p_joints,
                                               const Dictionary &p_metadata) {
    if (p_joints.is_empty()) {
        return false;
    }
    Object *muxer = resolve_muxer();
    if (muxer == nullptr && !body_jsonl_.active()) {
        return false;
    }

    const int64_t joint_count = p_joints.size();
    payload_scratch_.resize(hjnt::kHeaderBytes + joint_count * hjnt::kJointRecordBytes);
    uint8_t *base = payload_scratch_.ptrw();
    hjnt::pack_header(base, static_cast<uint16_t>(joint_count));
    uint8_t *w = base + hjnt::kHeaderBytes;

    std::string &json = json_scratch_;
    json.clear();
    if (json.capacity() < 16384) {
        json.reserve(16384);
    }
    char head[96];
    std::snprintf(head, sizeof(head),
                  "{\"timestamp_ns\":%" PRId64 ",\"body_flags\":%" PRId64
                  ",\"joint_count\":%" PRId64 ",\"joints\":[",
                  p_timestamp_ns, p_body_flags, joint_count);
    json += head;

    for (int64_t i = 0; i < joint_count; i++) {
        const Variant joint_v = p_joints[i];
        Dictionary joint;
        if (joint_v.get_type() == Variant::DICTIONARY) {
            joint = joint_v;
        }
        const Vector3 p = variant_to_vec3(joint.get("position", Variant()));
        const Quaternion q = variant_to_quat(joint.get("rotation", Variant()));
        hjnt::pack_joint(w,
                   static_cast<uint16_t>(int64_t(joint.get("joint", 0))),
                   static_cast<uint16_t>(int64_t(joint.get("flags", 0))),
                   float(joint.get("radius_m", 0.0)), p, q);
        w += hjnt::kJointRecordBytes;

        if (i > 0) {
            json += ',';
        }
        append_joint_record_json(json, joint);
    }
    json += ']';
    static const char *kBodySkip[] = { "joints", "transform" };
    append_metadata_extras(json, p_metadata, kBodySkip, 2);
    json += '}';

    emit_body(muxer, p_timestamp_ns);
    metric_body_writes_ += 1;
    metric_body_joints_ += joint_count;
    return true;
}

void NativeBodyMotionWriter::emit_motion_json(Object *p_muxer, int64_t p_timestamp_ns,
                                              bool &r_wrote) {
    if (p_muxer != nullptr && metadata_supported(p_muxer)) {
        p_muxer->call("writeMotionTrackerMetadataJson", p_timestamp_ns,
                      String::utf8(json_scratch_.data(), int(json_scratch_.size())));
        r_wrote = true;
    }
    if (motion_jsonl_.active()) {
        // Move, not copy: json_scratch_ is dead after emit and cleared on
        // its next use.
        motion_jsonl_.enqueue(std::move(json_scratch_));
        r_wrote = true;
    }
}

bool NativeBodyMotionWriter::write_motion_tracker_pose(
        int64_t p_tracker_index, const String &p_source, int64_t p_timestamp_ns,
        const Transform3D &p_transform, bool p_tracking_valid,
        const Dictionary &p_metadata) {
    Object *muxer = resolve_muxer();
    if (muxer == nullptr && !motion_jsonl_.active()) {
        return false;
    }

    const Vector3 p = p_transform.origin;
    const Quaternion q = p_transform.basis.get_rotation_quaternion();

    std::string &json = json_scratch_;
    json.clear();
    if (json.capacity() < 2048) {
        json.reserve(2048);
    }
    char head[64];
    std::snprintf(head, sizeof(head), "{\"timestamp_ns\":%" PRId64 ",\"source\":",
                  p_timestamp_ns);
    json += head;
    append_json_string(json, p_source);
    json += ",\"tracking_valid\":";
    json += p_tracking_valid ? "true" : "false";
    json += ",\"position\":";
    append_xyz_json(json, p);
    json += ",\"rotation\":";
    append_xyzw_json(json, q);
    char idx[48];
    std::snprintf(idx, sizeof(idx), ",\"tracker_index\":%" PRId64, p_tracker_index);
    json += idx;
    static const char *kMotionSkip[] = { "transform", "position", "rotation", "tracker_index" };
    append_metadata_extras(json, p_metadata, kMotionSkip, 4);
    json += '}';

    bool wrote = false;
    emit_motion_json(muxer, p_timestamp_ns, wrote);
    if (wrote) {
        metric_motion_writes_ += 1;
    }
    return wrote;
}

bool NativeBodyMotionWriter::write_motion_tracker_event(int64_t p_timestamp_ns,
                                                        const String &p_event_type,
                                                        const Dictionary &p_event) {
    Object *muxer = resolve_muxer();
    if (muxer == nullptr && !motion_jsonl_.active()) {
        return false;
    }

    std::string &json = json_scratch_;
    json.clear();
    char head[64];
    std::snprintf(head, sizeof(head), "{\"timestamp_ns\":%" PRId64 ",\"event_type\":",
                  p_timestamp_ns);
    json += head;
    append_json_string(json, p_event_type);
    json += ",\"event\":";
    append_json_safe_value(json, p_event);
    json += '}';

    bool wrote = false;
    emit_motion_json(muxer, p_timestamp_ns, wrote);
    if (wrote) {
        metric_motion_event_writes_ += 1;
    }
    return wrote;
}

Dictionary NativeBodyMotionWriter::pop_metrics() {
    Dictionary metrics;
    metrics["body_writes"] = static_cast<int64_t>(metric_body_writes_);
    metrics["body_joints"] = static_cast<int64_t>(metric_body_joints_);
    metrics["motion_writes"] = static_cast<int64_t>(metric_motion_writes_);
    metrics["motion_event_writes"] = static_cast<int64_t>(metric_motion_event_writes_);
    metrics["body_jsonl_lines"] = static_cast<int64_t>(body_jsonl_.pop_lines());
    metrics["body_jsonl_dropped"] = static_cast<int64_t>(body_jsonl_.pop_dropped());
    metrics["motion_jsonl_lines"] = static_cast<int64_t>(motion_jsonl_.pop_lines());
    metrics["motion_jsonl_dropped"] = static_cast<int64_t>(motion_jsonl_.pop_dropped());
    metric_body_writes_ = 0;
    metric_body_joints_ = 0;
    metric_motion_writes_ = 0;
    metric_motion_event_writes_ = 0;
    return metrics;
}

} // namespace godot
