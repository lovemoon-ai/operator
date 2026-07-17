// native_body_motion_writer.h — native body-joint + motion-tracker capture
// writer for the Operator XR client.
//
// Why: the GDScript body path materialized up to 87 joints as ~261 nested
// Dictionaries per 30 Hz sample, then re-walked and JSON.stringify'd the
// whole record on the main thread. Motion trackers did the same dict-build
// work at 90 Hz × N.
//
// This class owns the write side in C++ (single-pass serialization) and, for
// the Godot/Meta XRBodyTracker runtime, the sampling too:
//
//   - sample_body_tracker(ts): reads XRBodyTracker at /user/body_tracker
//     directly (87 joints, no Variant dicts at all), packs the HJNT v1
//     payload -> muxer.writeBodyJointsPayload, builds the metadata record
//     JSON once -> muxer.writeBodyFrameMetadataJson.
//   - write_body_joints(...): PICO path — joints arrive as Variant dicts
//     from the pico_openxr bridge; packed + serialized here in one pass.
//   - write_motion_tracker_pose/_event(...): record JSON built once ->
//     muxer.writeMotionTrackerMetadataJson.
//
// Output shapes are byte/shape-identical to the old session_spool_writer.gd
// metadata records (_body_metadata_record / _motion_tracker_pose_record /
// _motion_tracker_event_record).

#ifndef HAND_CAPTURE_NATIVE_BODY_MOTION_WRITER_H
#define HAND_CAPTURE_NATIVE_BODY_MOTION_WRITER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include <cstdint>
#include <string>

namespace godot {

class Object;

class NativeBodyMotionWriter : public RefCounted {
    GDCLASS(NativeBodyMotionWriter, RefCounted)

public:
    NativeBodyMotionWriter() = default;
    ~NativeBodyMotionWriter() override;

    void configure(Object *p_muxer_plugin);
    void begin_session();
    void end_session();

    // Godot/Meta XRBodyTracker path — fully native sampling + write.
    // Returns {"status": String, "wrote": bool, "joint_count": int,
    // "body_flags": int} (+ "tracker_class" for "wrong_tracker_class").
    // status is one of: "wrote" | "no_muxer" | "no_tracker" |
    // "wrong_tracker_class" | "no_tracking_data" | "no_joints".
    // Self-describing strings on purpose — a numeric enum would be a second
    // copy of the contract that GDScript must keep in sync by hand.
    Dictionary sample_body_tracker(int64_t p_timestamp_ns);

    // PICO path — joints are Variant dicts from the pico_openxr bridge.
    bool write_body_joints(int64_t p_timestamp_ns, int64_t p_body_flags,
                           const Array &p_joints, const Dictionary &p_metadata);

    bool write_motion_tracker_pose(int64_t p_tracker_index, const String &p_source,
                                   int64_t p_timestamp_ns, const Transform3D &p_transform,
                                   bool p_tracking_valid, const Dictionary &p_metadata);
    bool write_motion_tracker_event(int64_t p_timestamp_ns, const String &p_event_type,
                                    const Dictionary &p_event);

    Dictionary pop_metrics();

protected:
    static void _bind_methods();

private:
    Object *resolve_muxer();
    bool metadata_supported(Object *p_muxer);
    void emit_body(Object *p_muxer, int64_t p_timestamp_ns);
    void emit_motion_json(Object *p_muxer, int64_t p_timestamp_ns, bool &r_wrote);

    uint64_t muxer_instance_id_ = 0;
    int contract_version_ = -1; // -1 = not probed yet.

    uint64_t metric_body_writes_ = 0;
    uint64_t metric_body_joints_ = 0;
    uint64_t metric_motion_writes_ = 0;
    uint64_t metric_motion_event_writes_ = 0;

    // Reused scratch buffers (main thread only). payload_scratch_ carries the
    // HJNT bytes; json_scratch_ carries the record JSON for the muxer metadata
    // tracks.
    PackedByteArray payload_scratch_;
    std::string json_scratch_;
};

} // namespace godot

#endif // HAND_CAPTURE_NATIVE_BODY_MOTION_WRITER_H
