#include "mujoco_native.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

using namespace godot;

namespace {
String mj_name_or_fallback(const mjModel *model, int object_type, int id, const char *fallback_prefix) {
	const char *name = mj_id2name(model, object_type, id);
	if (name && name[0] != '\0') {
		return String(name);
	}
	return String(fallback_prefix) + "_" + String::num_int64(id);
}

PackedFloat64Array vec3_to_array(const mjtNum *values) {
	PackedFloat64Array out;
	out.resize(3);
	out.set(0, values[0]);
	out.set(1, values[1]);
	out.set(2, values[2]);
	return out;
}

PackedFloat64Array mat3_to_array(const mjtNum *values) {
	PackedFloat64Array out;
	out.resize(9);
	for (int i = 0; i < 9; ++i) {
		out.set(i, values[i]);
	}
	return out;
}

PackedFloat64Array slice_to_array(const mjtNum *values, int count) {
	PackedFloat64Array out;
	out.resize(std::max(0, count));
	for (int i = 0; i < count; ++i) {
		out.set(i, values[i]);
	}
	return out;
}
} // namespace

MjNativeSimulation::~MjNativeSimulation() {
	release();
}

void MjNativeSimulation::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load_xml_string", "xml", "model_name"), &MjNativeSimulation::load_xml_string, DEFVAL("model.xml"));
	ClassDB::bind_method(D_METHOD("release"), &MjNativeSimulation::release);
	ClassDB::bind_method(D_METHOD("reset"), &MjNativeSimulation::reset);
	ClassDB::bind_method(D_METHOD("step", "dt"), &MjNativeSimulation::step, DEFVAL(-1.0));
	ClassDB::bind_method(D_METHOD("is_loaded"), &MjNativeSimulation::is_loaded);
	ClassDB::bind_method(D_METHOD("get_last_error"), &MjNativeSimulation::get_last_error);
	ClassDB::bind_method(D_METHOD("get_status"), &MjNativeSimulation::get_status);
	ClassDB::bind_method(D_METHOD("get_model_summary"), &MjNativeSimulation::get_model_summary);
	ClassDB::bind_method(D_METHOD("get_state"), &MjNativeSimulation::get_state);
	ClassDB::bind_method(D_METHOD("get_observation"), &MjNativeSimulation::get_observation);
	ClassDB::bind_method(D_METHOD("get_body_names"), &MjNativeSimulation::get_body_names);
	ClassDB::bind_method(D_METHOD("get_joint_names"), &MjNativeSimulation::get_joint_names);
	ClassDB::bind_method(D_METHOD("get_actuator_names"), &MjNativeSimulation::get_actuator_names);
	ClassDB::bind_method(D_METHOD("get_geom_names"), &MjNativeSimulation::get_geom_names);
	ClassDB::bind_method(D_METHOD("get_sensor_names"), &MjNativeSimulation::get_sensor_names);
	ClassDB::bind_method(D_METHOD("get_body_transform", "body_name"), &MjNativeSimulation::get_body_transform);
	ClassDB::bind_method(D_METHOD("get_body_transforms"), &MjNativeSimulation::get_body_transforms);
	ClassDB::bind_method(D_METHOD("set_qpos", "qpos"), &MjNativeSimulation::set_qpos);
	ClassDB::bind_method(D_METHOD("set_joint_positions", "joint_names", "values"), &MjNativeSimulation::set_joint_positions);
	ClassDB::bind_method(D_METHOD("set_actuator_control", "actuator_name", "value"), &MjNativeSimulation::set_actuator_control);
	ClassDB::bind_method(D_METHOD("set_control_by_index", "index", "value"), &MjNativeSimulation::set_control_by_index);
}

bool MjNativeSimulation::load_xml_string(const String &xml, const String &model_name) {
	release();
	last_error = "";
	mj_defaultVFS(&vfs);
	vfs_initialized = true;

	const CharString xml_utf8 = xml.utf8();
	const CharString name_utf8 = model_name.utf8();
	const int added = mj_addBufferVFS(&vfs, name_utf8.get_data(), xml_utf8.get_data(), xml_utf8.length());
	if (added != 0) {
		last_error = "mj_addBufferVFS failed: " + String::num_int64(added);
		clear_vfs();
		return false;
	}

	char error[2048] = {0};
	model = mj_loadXML(name_utf8.get_data(), &vfs, error, sizeof(error));
	if (!model) {
		last_error = String(error);
		clear_vfs();
		return false;
	}
	data = mj_makeData(model);
	if (!data) {
		last_error = "mj_makeData failed";
		release();
		return false;
	}
	step_index = 0;
	accumulated_step_usec = 0.0;
	max_step_usec = 0.0;
	return true;
}

void MjNativeSimulation::release() {
	if (data) {
		mj_deleteData(data);
		data = nullptr;
	}
	if (model) {
		mj_deleteModel(model);
		model = nullptr;
	}
	clear_vfs();
	step_index = 0;
	accumulated_step_usec = 0.0;
	max_step_usec = 0.0;
}

void MjNativeSimulation::reset() {
	if (!model || !data) {
		return;
	}
	mj_resetData(model, data);
	mj_forward(model, data);
	step_index = 0;
	accumulated_step_usec = 0.0;
	max_step_usec = 0.0;
}

bool MjNativeSimulation::step(double dt) {
	if (!model || !data) {
		last_error = "step called before model load";
		return false;
	}
	if (dt > 0.0) {
		model->opt.timestep = dt;
	}
	const auto begin = std::chrono::steady_clock::now();
	mj_step(model, data);
	const auto end = std::chrono::steady_clock::now();
	const double elapsed_usec = std::chrono::duration<double, std::micro>(end - begin).count();
	accumulated_step_usec += elapsed_usec;
	max_step_usec = std::max(max_step_usec, elapsed_usec);
	step_index += 1;
	return true;
}

bool MjNativeSimulation::is_loaded() const {
	return model != nullptr && data != nullptr;
}

String MjNativeSimulation::get_last_error() const {
	return last_error;
}

Dictionary MjNativeSimulation::get_status() const {
	Dictionary status;
	status["backend"] = "native_mujoco";
	status["loaded"] = is_loaded();
	status["step_index"] = step_index;
	status["last_error"] = last_error;
	status["sim_time"] = data ? data->time : 0.0;
	status["mean_step_usec"] = step_index > 0 ? accumulated_step_usec / static_cast<double>(step_index) : 0.0;
	status["max_step_usec"] = max_step_usec;
	status["mujoco_version"] = mj_versionString();
	return status;
}

Dictionary MjNativeSimulation::get_model_summary() const {
	Dictionary summary;
	summary["backend"] = "native_mujoco";
	summary["loaded"] = is_loaded();
	if (!model) {
		return summary;
	}
	summary["nbody"] = model->nbody;
	summary["njnt"] = model->njnt;
	summary["nu"] = model->nu;
	summary["ngeom"] = model->ngeom;
	summary["nsensor"] = model->nsensor;
	summary["nq"] = model->nq;
	summary["nv"] = model->nv;
	summary["body_names"] = get_body_names();
	PackedStringArray body_parent_names;
	for (int body_id = 0; body_id < model->nbody; ++body_id) {
		const int parent_id = model->body_parentid[body_id];
		const char *parent_name = parent_id >= 0 ? mj_id2name(model, mjOBJ_BODY, parent_id) : nullptr;
		body_parent_names.append(parent_name ? String::utf8(parent_name) : String());
	}
	summary["body_parent_names"] = body_parent_names;
	summary["joint_names"] = get_joint_names();
	summary["actuator_names"] = get_actuator_names();
	summary["geom_names"] = get_geom_names();
	summary["sensor_names"] = get_sensor_names();
	summary["stable_ids"] = stable_ids();
	return summary;
}

Dictionary MjNativeSimulation::get_state() const {
	Dictionary state;
	state["step_index"] = step_index;
	state["sim_time"] = data ? data->time : 0.0;
	if (!model || !data) {
		return state;
	}
	state["qpos"] = slice_to_array(data->qpos, model->nq);
	state["qvel"] = slice_to_array(data->qvel, model->nv);
	state["ctrl"] = slice_to_array(data->ctrl, model->nu);
	state["actuator_force"] = slice_to_array(data->actuator_force, model->nu);
	return state;
}

Dictionary MjNativeSimulation::get_observation() const {
	Dictionary observation;
	observation["state"] = get_state();
	observation["contact"] = Dictionary();
	observation["force"] = Dictionary();
	if (!model || !data) {
		return observation;
	}
	Dictionary contact;
	contact["count"] = data->ncon;
	contact["capacity"] = model->nconmax;
	observation["contact"] = contact;
	Dictionary force;
	force["actuator_force"] = slice_to_array(data->actuator_force, model->nu);
	observation["force"] = force;
	return observation;
}

PackedStringArray MjNativeSimulation::get_body_names() const {
	return names_for_type(mjOBJ_BODY, model ? model->nbody : 0);
}

PackedStringArray MjNativeSimulation::get_joint_names() const {
	return names_for_type(mjOBJ_JOINT, model ? model->njnt : 0);
}

PackedStringArray MjNativeSimulation::get_actuator_names() const {
	return names_for_type(mjOBJ_ACTUATOR, model ? model->nu : 0);
}

PackedStringArray MjNativeSimulation::get_geom_names() const {
	return names_for_type(mjOBJ_GEOM, model ? model->ngeom : 0);
}

PackedStringArray MjNativeSimulation::get_sensor_names() const {
	return names_for_type(mjOBJ_SENSOR, model ? model->nsensor : 0);
}

Dictionary MjNativeSimulation::get_body_transform(const String &body_name) const {
	Dictionary transform;
	if (!model || !data) {
		return transform;
	}
	const int body_id = id_for_name(mjOBJ_BODY, body_name);
	if (body_id < 0) {
		return transform;
	}
	transform["position"] = vec3_to_array(data->xpos + 3 * body_id);
	transform["basis"] = mat3_to_array(data->xmat + 9 * body_id);
	return transform;
}

Dictionary MjNativeSimulation::get_body_transforms() const {
	Dictionary transforms;
	if (!model || !data) {
		return transforms;
	}
	for (int body_id = 0; body_id < model->nbody; ++body_id) {
		const char *name = mj_id2name(model, mjOBJ_BODY, body_id);
		if (!name) {
			continue;
		}
		Dictionary transform;
		transform["position"] = vec3_to_array(data->xpos + 3 * body_id);
		transform["basis"] = mat3_to_array(data->xmat + 9 * body_id);
		transforms[String::utf8(name)] = transform;
	}
	return transforms;
}

bool MjNativeSimulation::set_qpos(const PackedFloat64Array &qpos) {
	if (!model || !data || qpos.size() != model->nq) {
		last_error = "qpos size mismatch: expected " + String::num_int64(model ? model->nq : 0) +
				", got " + String::num_int64(qpos.size());
		return false;
	}
	for (int i = 0; i < model->nq; ++i) {
		data->qpos[i] = qpos[i];
	}
	mj_normalizeQuat(model, data->qpos);
	mj_forward(model, data);
	return true;
}

bool MjNativeSimulation::set_joint_positions(const PackedStringArray &joint_names, const PackedFloat64Array &values) {
	if (!model || !data || joint_names.size() != values.size()) {
		last_error = "joint position names/values size mismatch";
		return false;
	}
	for (int i = 0; i < joint_names.size(); ++i) {
		const int joint_id = id_for_name(mjOBJ_JOINT, joint_names[i]);
		if (joint_id < 0 || (model->jnt_type[joint_id] != mjJNT_HINGE && model->jnt_type[joint_id] != mjJNT_SLIDE)) {
			last_error = "unknown or non-scalar joint: " + joint_names[i];
			return false;
		}
		data->qpos[model->jnt_qposadr[joint_id]] = values[i];
	}
	mj_forward(model, data);
	return true;
}

void MjNativeSimulation::set_actuator_control(const String &actuator_name, double value) {
	if (!model || !data) {
		return;
	}
	const int actuator_id = id_for_name(mjOBJ_ACTUATOR, actuator_name);
	if (actuator_id >= 0 && actuator_id < model->nu) {
		data->ctrl[actuator_id] = value;
	}
}

void MjNativeSimulation::set_control_by_index(int index, double value) {
	if (!model || !data || index < 0 || index >= model->nu) {
		return;
	}
	data->ctrl[index] = value;
}

PackedStringArray MjNativeSimulation::names_for_type(int object_type, int count) const {
	PackedStringArray names;
	if (!model) {
		return names;
	}
	for (int i = 0; i < count; ++i) {
		const char *fallback = "object";
		switch (object_type) {
			case mjOBJ_BODY: fallback = "body"; break;
			case mjOBJ_JOINT: fallback = "joint"; break;
			case mjOBJ_ACTUATOR: fallback = "actuator"; break;
			case mjOBJ_GEOM: fallback = "geom"; break;
			case mjOBJ_SENSOR: fallback = "sensor"; break;
		}
		names.append(mj_name_or_fallback(model, object_type, i, fallback));
	}
	return names;
}

int MjNativeSimulation::id_for_name(int object_type, const String &name) const {
	if (!model) {
		return -1;
	}
	const CharString name_utf8 = name.utf8();
	return mj_name2id(model, object_type, name_utf8.get_data());
}

Dictionary MjNativeSimulation::stable_ids() const {
	Dictionary ids;
	if (!model) {
		return ids;
	}
	const PackedStringArray bodies = get_body_names();
	for (int i = 0; i < bodies.size(); ++i) {
		ids[String("body:") + bodies[i]] = i;
	}
	const PackedStringArray joints = get_joint_names();
	for (int i = 0; i < joints.size(); ++i) {
		ids[String("joint:") + joints[i]] = i;
	}
	const PackedStringArray actuators = get_actuator_names();
	for (int i = 0; i < actuators.size(); ++i) {
		ids[String("actuator:") + actuators[i]] = i;
	}
	const PackedStringArray geoms = get_geom_names();
	for (int i = 0; i < geoms.size(); ++i) {
		ids[String("geom:") + geoms[i]] = i;
	}
	const PackedStringArray sensors = get_sensor_names();
	for (int i = 0; i < sensors.size(); ++i) {
		ids[String("sensor:") + sensors[i]] = i;
	}
	return ids;
}

void MjNativeSimulation::clear_vfs() {
	if (vfs_initialized) {
		mj_deleteVFS(&vfs);
		vfs_initialized = false;
	}
}
