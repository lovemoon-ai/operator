#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <mujoco/mujoco.h>

namespace godot {

class MjNativeSimulation : public RefCounted {
	GDCLASS(MjNativeSimulation, RefCounted)

public:
	MjNativeSimulation() = default;
	~MjNativeSimulation() override;

	bool load_xml_string(const String &xml, const String &model_name = "model.xml");
	void release();
	void reset();
	bool step(double dt = -1.0);
	bool is_loaded() const;
	String get_last_error() const;
	Dictionary get_status() const;
	Dictionary get_model_summary() const;
	Dictionary get_state() const;
	Dictionary get_observation() const;
	PackedStringArray get_body_names() const;
	PackedStringArray get_joint_names() const;
	PackedStringArray get_actuator_names() const;
	PackedStringArray get_geom_names() const;
	PackedStringArray get_sensor_names() const;
	Dictionary get_body_transform(const String &body_name) const;
	void set_actuator_control(const String &actuator_name, double value);
	void set_control_by_index(int index, double value);

protected:
	static void _bind_methods();

private:
	mjModel *model = nullptr;
	mjData *data = nullptr;
	mjVFS vfs;
	bool vfs_initialized = false;
	String last_error;
	int64_t step_index = 0;
	double accumulated_step_usec = 0.0;
	double max_step_usec = 0.0;

	PackedStringArray names_for_type(int object_type, int count) const;
	int id_for_name(int object_type, const String &name) const;
	Dictionary stable_ids() const;
	void clear_vfs();
};

} // namespace godot
