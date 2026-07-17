// variant_json.cpp — see header.

#include "variant_json.h"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cinttypes>
#include <cstdio>

namespace godot {

void append_json_float(std::string &out, double v) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%.9g", v);
    out += buf;
}

void append_json_string(std::string &out, const String &s) {
    out += '"';
    CharString utf8 = s.utf8();
    const char *data = utf8.get_data();
    for (int i = 0; i < utf8.length(); i++) {
        const unsigned char c = static_cast<unsigned char>(data[i]);
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out += static_cast<char>(c); // UTF-8 passthrough.
                }
        }
    }
    out += '"';
}

namespace {

inline void append_xy(std::string &out, double x, double y) {
    out += "{\"x\":";
    append_json_float(out, x);
    out += ",\"y\":";
    append_json_float(out, y);
    out += '}';
}

} // namespace

void append_xyz_json(std::string &out, const Vector3 &v) {
    out += "{\"x\":";
    append_json_float(out, v.x);
    out += ",\"y\":";
    append_json_float(out, v.y);
    out += ",\"z\":";
    append_json_float(out, v.z);
    out += '}';
}

void append_xyzw_json(std::string &out, const Quaternion &q) {
    out += "{\"x\":";
    append_json_float(out, q.x);
    out += ",\"y\":";
    append_json_float(out, q.y);
    out += ",\"z\":";
    append_json_float(out, q.z);
    out += ",\"w\":";
    append_json_float(out, q.w);
    out += '}';
}

void append_json_safe_value(std::string &out, const Variant &v) {
    switch (v.get_type()) {
        case Variant::NIL:
            out += "null";
            break;
        case Variant::BOOL:
            out += bool(v) ? "true" : "false";
            break;
        case Variant::INT: {
            char buf[32];
            std::snprintf(buf, sizeof(buf), "%" PRId64, int64_t(v));
            out += buf;
            break;
        }
        case Variant::FLOAT:
            append_json_float(out, double(v));
            break;
        case Variant::STRING:
        case Variant::STRING_NAME:
            append_json_string(out, String(v));
            break;
        case Variant::VECTOR2: {
            const Vector2 v2 = v;
            append_xy(out, v2.x, v2.y);
            break;
        }
        case Variant::VECTOR3:
            append_xyz_json(out, Vector3(v));
            break;
        case Variant::QUATERNION:
            append_xyzw_json(out, Quaternion(v));
            break;
        case Variant::TRANSFORM3D: {
            const Transform3D t = v;
            out += "{\"position\":";
            append_xyz_json(out, t.origin);
            out += ",\"rotation\":";
            append_xyzw_json(out, t.basis.get_rotation_quaternion());
            out += '}';
            break;
        }
        case Variant::PACKED_BYTE_ARRAY: {
            char buf[40];
            std::snprintf(buf, sizeof(buf), "\"<bytes:%" PRId64 ">\"",
                          int64_t(PackedByteArray(v).size()));
            out += buf;
            break;
        }
        case Variant::PACKED_INT32_ARRAY: {
            const PackedInt32Array arr = v;
            out += '[';
            for (int64_t i = 0; i < arr.size(); i++) {
                if (i > 0) out += ',';
                char buf[16];
                std::snprintf(buf, sizeof(buf), "%d", arr[i]);
                out += buf;
            }
            out += ']';
            break;
        }
        case Variant::PACKED_INT64_ARRAY: {
            const PackedInt64Array arr = v;
            out += '[';
            for (int64_t i = 0; i < arr.size(); i++) {
                if (i > 0) out += ',';
                char buf[32];
                std::snprintf(buf, sizeof(buf), "%" PRId64, arr[i]);
                out += buf;
            }
            out += ']';
            break;
        }
        case Variant::PACKED_FLOAT32_ARRAY: {
            const PackedFloat32Array arr = v;
            out += '[';
            for (int64_t i = 0; i < arr.size(); i++) {
                if (i > 0) out += ',';
                append_json_float(out, arr[i]);
            }
            out += ']';
            break;
        }
        case Variant::PACKED_FLOAT64_ARRAY: {
            const PackedFloat64Array arr = v;
            out += '[';
            for (int64_t i = 0; i < arr.size(); i++) {
                if (i > 0) out += ',';
                append_json_float(out, arr[i]);
            }
            out += ']';
            break;
        }
        case Variant::PACKED_STRING_ARRAY: {
            const PackedStringArray arr = v;
            out += '[';
            for (int64_t i = 0; i < arr.size(); i++) {
                if (i > 0) out += ',';
                append_json_string(out, arr[i]);
            }
            out += ']';
            break;
        }
        case Variant::ARRAY: {
            const Array arr = v;
            out += '[';
            for (int64_t i = 0; i < arr.size(); i++) {
                if (i > 0) out += ',';
                append_json_safe_value(out, arr[i]);
            }
            out += ']';
            break;
        }
        case Variant::DICTIONARY: {
            const Dictionary dict = v;
            const Array keys = dict.keys();
            out += '{';
            for (int64_t i = 0; i < keys.size(); i++) {
                if (i > 0) out += ',';
                append_json_string(out, String(keys[i]));
                out += ':';
                append_json_safe_value(out, dict[keys[i]]);
            }
            out += '}';
            break;
        }
        default:
            // Objects / RIDs / other engine types: stable string form, same
            // spirit as the GDScript fallback (never raw-embed engine types).
            append_json_string(out, v.stringify());
    }
}

} // namespace godot
