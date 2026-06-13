#pragma once

// Godot GDExtension binding for the retargeting toolkit (xr/native/retargeting).
//
// Exposes a single RefCounted class, GMRRetargeter, to GDScript. The intended
// per-frame use in VR is:
//
//   var rt := GMRRetargeter.new()
//   rt.configure("upper_body", robot_xml_path, ik_config_path, 1.75, 19)
//   # each frame, from headset body/hand tracking:
//   rt.set_pose("Hips", hips_xform)
//   rt.set_pose("Head", head_xform)
//   ... (all tracked joints) ...
//   var qpos: PackedFloat64Array = rt.step()   # robot configuration
//
// On Android the kinematics backend is MuJoCo (loads MJCF natively). Paths must
// be real filesystem paths — extract res:// assets to user:// first and pass
// those (res:// inside an APK is not a real path).
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <memory>

#include "retargeting/retargeter.hpp"
#include "retargeting/types.hpp"

namespace godot {

class GMRRetargeter : public RefCounted {
	GDCLASS(GMRRetargeter, RefCounted)

public:
	GMRRetargeter() = default;
	~GMRRetargeter() override = default;

	// scenario: "whole_body" | "upper_body" | "hand". locked_qpos_prefix is the
	// robot-specific count of leading qpos entries to hold fixed for upper_body
	// (e.g. 19 for a Unitree G1 = 7 base + 12 leg DoFs); ignored otherwise.
	bool configure(const String &scenario, const String &robot_xml,
			const String &ik_config, double human_height, int locked_qpos_prefix,
			bool freeze_locked);

	// Accumulate one source joint pose for the next step().
	void set_pose(const String &name, const Transform3D &xform);
	void set_pose_pq(const String &name, const Vector3 &pos, const Quaternion &quat);
	void clear_frame();

	// Run one retargeting step. step() uses the accumulated frame; step_frame()
	// takes a Dictionary {String name: Transform3D}. Returns the robot qpos, or
	// an empty array on error (see get_last_error()).
	PackedFloat64Array step();
	PackedFloat64Array step_frame(const Dictionary &frame);

	bool is_configured() const { return retargeter_ != nullptr; }
	int get_nq() const;
	String get_scenario() const;
	String get_last_error() const { return last_error_; }

protected:
	static void _bind_methods();

private:
	PackedFloat64Array run(const retargeting::SkeletonFrame &frame);

	std::unique_ptr<retargeting::Retargeter> retargeter_;
	retargeting::SkeletonFrame frame_;
	String last_error_;
};

} // namespace godot
