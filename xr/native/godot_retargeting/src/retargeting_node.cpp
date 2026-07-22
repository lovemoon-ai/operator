#include "retargeting_node.h"

#include <godot_cpp/core/class_db.hpp>

#include <string>

#include "retargeting/scenario.hpp"

using namespace godot;

namespace {
retargeting::Pose pose_from_xform(const Transform3D &xform) {
	retargeting::Pose p;
	p.pos = Eigen::Vector3d(xform.origin.x, xform.origin.y, xform.origin.z);
	Quaternion q = xform.basis.get_quaternion();
	// Godot quaternion is (x, y, z, w); retargeting expects (w, x, y, z).
	p.quat = Eigen::Vector4d(q.w, q.x, q.y, q.z);
	return p;
}

retargeting::Pose pose_from_pq(const Vector3 &pos, const Quaternion &q) {
	retargeting::Pose p;
	p.pos = Eigen::Vector3d(pos.x, pos.y, pos.z);
	p.quat = Eigen::Vector4d(q.w, q.x, q.y, q.z);
	return p;
}
} // namespace

bool GMRRetargeter::configure(const String &scenario, const String &robot_xml,
		const String &ik_config, double human_height, int locked_qpos_prefix,
		bool freeze_locked, const PackedInt32Array &clamp_qpos_indices) {
	return configure_algorithm(scenario, robot_xml, ik_config, "gmr", human_height,
			locked_qpos_prefix, freeze_locked, clamp_qpos_indices);
}

bool GMRRetargeter::configure_algorithm(const String &scenario, const String &robot_xml,
		const String &ik_config, const String &algorithm, double human_height,
		int locked_qpos_prefix, bool freeze_locked,
		const PackedInt32Array &clamp_qpos_indices) {
	Dictionary options;
	return configure_algorithm_options(scenario, robot_xml, ik_config, algorithm,
			human_height, locked_qpos_prefix, freeze_locked, clamp_qpos_indices, options);
}

bool GMRRetargeter::configure_algorithm_options(const String &scenario, const String &robot_xml,
		const String &ik_config, const String &algorithm, double human_height,
		int locked_qpos_prefix, bool freeze_locked,
		const PackedInt32Array &clamp_qpos_indices, const Dictionary &options) {
	last_error_ = "";
	retargeter_.reset();

	retargeting::RetargetConfig cfg;
	cfg.robot_xml = std::string(robot_xml.utf8().get_data());
	cfg.ik_config_json = std::string(ik_config.utf8().get_data());
	cfg.human_height = human_height;
	// On Android the only available backend is MuJoCo (loads MJCF natively).
	cfg.backend = retargeting::KinematicsBackendKind::Mujoco;
	Array option_keys = options.keys();
	for (int i = 0; i < option_keys.size(); ++i) {
		String key = String(option_keys[i]);
		String value = String(options[option_keys[i]]);
		cfg.options[std::string(key.utf8().get_data())] =
				std::string(value.utf8().get_data());
	}

	std::string s(scenario.utf8().get_data());
	std::string algo(algorithm.utf8().get_data());
	try {
		if (s == "whole_body") {
			retargeter_ = retargeting::WholeBodyRetargeter::create(cfg, algo);
		} else if (s == "upper_body") {
			std::vector<int> clamp;
			clamp.reserve(clamp_qpos_indices.size());
			for (int i = 0; i < clamp_qpos_indices.size(); ++i)
				clamp.push_back(clamp_qpos_indices[i]);
			retargeter_ = retargeting::UpperBodyRetargeter::create(
					cfg, locked_qpos_prefix, algo, freeze_locked, clamp);
		} else if (s == "hand") {
			retargeter_ = retargeting::HandRetargeter::create(cfg, algo);
		} else {
			last_error_ = "unknown scenario: " + scenario;
			return false;
		}
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
		retargeter_.reset();
		return false;
	}
	return true;
}

void GMRRetargeter::set_pose(const String &name, const Transform3D &xform) {
	frame_[std::string(name.utf8().get_data())] = pose_from_xform(xform);
}

void GMRRetargeter::set_pose_pq(const String &name, const Vector3 &pos, const Quaternion &quat) {
	frame_[std::string(name.utf8().get_data())] = pose_from_pq(pos, quat);
}

void GMRRetargeter::clear_frame() {
	frame_.clear();
}

bool GMRRetargeter::set_configuration(const PackedFloat64Array &qpos) {
	if (!retargeter_) {
		last_error_ = "not configured";
		return false;
	}
	try {
		Eigen::VectorXd q(qpos.size());
		for (int i = 0; i < qpos.size(); ++i) {
			q[i] = qpos[i];
		}
		retargeter_->set_configuration(q);
		last_error_ = "";
		return true;
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
		return false;
	}
}

bool GMRRetargeter::run_to_qpos(const retargeting::SkeletonFrame &frame, Eigen::VectorXd &qpos) {
	if (!retargeter_) {
		last_error_ = "not configured";
		return false;
	}
	try {
		qpos = retargeter_->step(frame);
		last_error_ = "";
		return true;
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
		qpos.resize(0);
		return false;
	}
}

PackedFloat64Array GMRRetargeter::run(const retargeting::SkeletonFrame &frame) {
	PackedFloat64Array out;
	Eigen::VectorXd qpos;
	if (!run_to_qpos(frame, qpos)) {
		return out;
	}
	out.resize(qpos.size());
	for (int i = 0; i < qpos.size(); ++i) {
		out.set(i, qpos[i]);
	}
	return out;
}

PackedFloat64Array GMRRetargeter::step() {
	return run(frame_);
}

retargeting::SkeletonFrame GMRRetargeter::skeleton_from_dictionary(const Dictionary &frame) {
	retargeting::SkeletonFrame sf;
	Array keys = frame.keys();
	for (int i = 0; i < keys.size(); ++i) {
		String name = keys[i];
		Transform3D xform = frame[keys[i]];
		sf[std::string(name.utf8().get_data())] = pose_from_xform(xform);
	}
	return sf;
}

PackedFloat64Array GMRRetargeter::step_frame(const Dictionary &frame) {
	retargeting::SkeletonFrame sf = skeleton_from_dictionary(frame);
	return run(sf);
}

Dictionary GMRRetargeter::make_robot_pose(const Eigen::VectorXd &qpos,
		const PackedStringArray &joint_names,
		const PackedInt32Array &qpos_indices) {
	Dictionary out;
	if (joint_names.size() != qpos_indices.size()) {
		last_error_ = "joint_names and qpos_indices size mismatch";
		return out;
	}

	PackedFloat64Array qpos_out;
	qpos_out.resize(qpos.size());
	for (int i = 0; i < qpos.size(); ++i) {
		qpos_out.set(i, qpos[i]);
	}

	PackedFloat64Array joint_q;
	joint_q.resize(joint_names.size());
	for (int i = 0; i < qpos_indices.size(); ++i) {
		const int qi = qpos_indices[i];
		if (qi < 0 || qi >= qpos.size()) {
			last_error_ = "qpos index out of range";
			Dictionary empty;
			return empty;
		}
		joint_q.set(i, qpos[qi]);
	}

	out["joint_names"] = joint_names;
	out["joint_q"] = joint_q;
	out["qpos"] = qpos_out;
	out["scenario"] = get_scenario();
	out["algorithm"] = get_algorithm_name();
	last_error_ = "";
	return out;
}

Dictionary GMRRetargeter::step_robot_pose(const PackedStringArray &joint_names,
		const PackedInt32Array &qpos_indices) {
	Eigen::VectorXd qpos;
	if (!run_to_qpos(frame_, qpos)) {
		return Dictionary();
	}
	return make_robot_pose(qpos, joint_names, qpos_indices);
}

Dictionary GMRRetargeter::step_frame_robot_pose(const Dictionary &frame,
		const PackedStringArray &joint_names,
		const PackedInt32Array &qpos_indices) {
	Eigen::VectorXd qpos;
	retargeting::SkeletonFrame sf = skeleton_from_dictionary(frame);
	if (!run_to_qpos(sf, qpos)) {
		return Dictionary();
	}
	return make_robot_pose(qpos, joint_names, qpos_indices);
}

int GMRRetargeter::get_nq() const {
	return retargeter_ ? retargeter_->nq() : 0;
}

String GMRRetargeter::get_scenario() const {
	if (!retargeter_) {
		return String();
	}
	return String(retargeting::to_string(retargeter_->scenario()));
}

String GMRRetargeter::get_algorithm_name() const {
	if (!retargeter_) {
		return String();
	}
	return String(retargeter_->algorithm_name());
}

void GMRRetargeter::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "scenario", "robot_xml", "ik_config", "human_height", "locked_qpos_prefix", "freeze_locked", "clamp_qpos_indices"),
			&GMRRetargeter::configure, DEFVAL(1.75), DEFVAL(0), DEFVAL(false), DEFVAL(PackedInt32Array()));
	ClassDB::bind_method(D_METHOD("configure_algorithm", "scenario", "robot_xml", "ik_config", "algorithm", "human_height", "locked_qpos_prefix", "freeze_locked", "clamp_qpos_indices"),
			&GMRRetargeter::configure_algorithm, DEFVAL("gmr"), DEFVAL(1.75), DEFVAL(0), DEFVAL(false), DEFVAL(PackedInt32Array()));
	ClassDB::bind_method(D_METHOD("configure_algorithm_options", "scenario", "robot_xml", "ik_config", "algorithm", "human_height", "locked_qpos_prefix", "freeze_locked", "clamp_qpos_indices", "options"),
			&GMRRetargeter::configure_algorithm_options, DEFVAL("gmr"), DEFVAL(1.75), DEFVAL(0), DEFVAL(false), DEFVAL(PackedInt32Array()), DEFVAL(Dictionary()));
	ClassDB::bind_method(D_METHOD("set_pose", "name", "xform"), &GMRRetargeter::set_pose);
	ClassDB::bind_method(D_METHOD("set_pose_pq", "name", "pos", "quat"), &GMRRetargeter::set_pose_pq);
	ClassDB::bind_method(D_METHOD("clear_frame"), &GMRRetargeter::clear_frame);
	ClassDB::bind_method(D_METHOD("set_configuration", "qpos"), &GMRRetargeter::set_configuration);
	ClassDB::bind_method(D_METHOD("step"), &GMRRetargeter::step);
	ClassDB::bind_method(D_METHOD("step_frame", "frame"), &GMRRetargeter::step_frame);
	ClassDB::bind_method(D_METHOD("step_robot_pose", "joint_names", "qpos_indices"), &GMRRetargeter::step_robot_pose);
	ClassDB::bind_method(D_METHOD("step_frame_robot_pose", "frame", "joint_names", "qpos_indices"), &GMRRetargeter::step_frame_robot_pose);
	ClassDB::bind_method(D_METHOD("is_configured"), &GMRRetargeter::is_configured);
	ClassDB::bind_method(D_METHOD("get_nq"), &GMRRetargeter::get_nq);
	ClassDB::bind_method(D_METHOD("get_scenario"), &GMRRetargeter::get_scenario);
	ClassDB::bind_method(D_METHOD("get_algorithm_name"), &GMRRetargeter::get_algorithm_name);
	ClassDB::bind_method(D_METHOD("get_last_error"), &GMRRetargeter::get_last_error);
}
