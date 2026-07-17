// variant_json.h — serialize Godot Variants straight to a JSON string with
// the same semantics as session_spool_writer.gd's `_json_safe_value` +
// `JSON.stringify` pair, but in one pass without intermediate Variant trees:
//
//   Dictionary / Array      -> recurse (keys in insertion order)
//   PackedByteArray         -> "<bytes:N>"
//   Vector2                 -> {"x","y"}
//   Vector3                 -> {"x","y","z"}
//   Quaternion              -> {"x","y","z","w"}
//   Transform3D             -> {"position":{...},"rotation":{...}}
//   Packed{Int,Float,String}Array -> plain JSON arrays
//   bool/int/float/String   -> JSON scalars
//   anything else           -> Variant.stringify() as a JSON string

#ifndef HAND_CAPTURE_VARIANT_JSON_H
#define HAND_CAPTURE_VARIANT_JSON_H

#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <string>

namespace godot {

// Appends `v` to `out` as JSON (json-safe semantics above).
void append_json_safe_value(std::string &out, const Variant &v);

// Appends a JSON-escaped, quoted string.
void append_json_string(std::string &out, const String &s);

// Appends a float with float32-friendly precision (%.9g).
void append_json_float(std::string &out, double v);

// {"x":..,"y":..,"z":..} / {"x":..,"y":..,"z":..,"w":..}
void append_xyz_json(std::string &out, const Vector3 &v);
void append_xyzw_json(std::string &out, const Quaternion &q);

} // namespace godot

#endif // HAND_CAPTURE_VARIANT_JSON_H
