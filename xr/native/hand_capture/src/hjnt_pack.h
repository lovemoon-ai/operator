// hjnt_pack.h — single definition of the HJNT v1 wire format shared by the
// hand and body joint writers. Byte-identical to the legacy
// session_spool_writer.gd packer:
//
//   u32 magic "HJNT" (LE) | u16 version=1 | u16 joint_count
//   per joint: u16 joint | u16 flags | f32 radius_m | f32 px py pz
//              | f32 qx qy qz qw                     (36 bytes/joint)
//
// Any format change (version bump, field add, stride change) happens here
// and nowhere else — both producers must stay in lockstep or the mp4 mett
// tracks become unparseable.

#ifndef HAND_CAPTURE_HJNT_PACK_H
#define HAND_CAPTURE_HJNT_PACK_H

#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <cstring>

namespace godot {
namespace hjnt {

constexpr uint32_t kMagic = 0x544E4A48; // "HJNT" little-endian.
constexpr uint16_t kVersion = 1;
constexpr int kJointRecordBytes = 36;
constexpr int kHeaderBytes = 8;

inline void encode_u16(uint8_t *w, uint16_t v) {
    w[0] = static_cast<uint8_t>(v & 0xFF);
    w[1] = static_cast<uint8_t>((v >> 8) & 0xFF);
}

inline void encode_u32(uint8_t *w, uint32_t v) {
    w[0] = static_cast<uint8_t>(v & 0xFF);
    w[1] = static_cast<uint8_t>((v >> 8) & 0xFF);
    w[2] = static_cast<uint8_t>((v >> 16) & 0xFF);
    w[3] = static_cast<uint8_t>((v >> 24) & 0xFF);
}

inline void encode_f32(uint8_t *w, float v) {
    static_assert(sizeof(float) == 4, "float must be 32-bit");
    std::memcpy(w, &v, 4);
}

// Writes the 8-byte payload header.
inline void pack_header(uint8_t *w, uint16_t joint_count) {
    encode_u32(w, kMagic);
    encode_u16(w + 4, kVersion);
    encode_u16(w + 6, joint_count);
}

// Writes one 36-byte joint record at `w`.
inline void pack_joint(uint8_t *w, uint16_t joint, uint16_t flags, float radius,
                       const Vector3 &p, const Quaternion &q) {
    encode_u16(w, joint);
    encode_u16(w + 2, flags);
    encode_f32(w + 4, radius);
    encode_f32(w + 8, p.x);
    encode_f32(w + 12, p.y);
    encode_f32(w + 16, p.z);
    encode_f32(w + 20, q.x);
    encode_f32(w + 24, q.y);
    encode_f32(w + 28, q.z);
    encode_f32(w + 32, q.w);
}

} // namespace hjnt
} // namespace godot

#endif // HAND_CAPTURE_HJNT_PACK_H
