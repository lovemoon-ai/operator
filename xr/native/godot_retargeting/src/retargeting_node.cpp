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
	last_error_ = "";
	retargeter_.reset();

	retargeting::RetargetConfig cfg;
	cfg.robot_xml = std::string(robot_xml.utf8().get_data());
	cfg.ik_config_json = std::string(ik_config.utf8().get_data());
	cfg.human_height = human_height;
	// On Android the only available backend is MuJoCo (loads MJCF natively).
	cfg.backend = retargeting::KinematicsBackendKind::Mujoco;

	std::string s(scenario.utf8().get_data());
	try {
		if (s == "whole_body") {
			retargeter_ = retargeting::WholeBodyRetargeter::create(cfg);
		} else if (s == "upper_body") {
			std::vector<int> clamp;
			clamp.reserve(clamp_qpos_indices.size());
			for (int i = 0; i < clamp_qpos_indices.size(); ++i)
				clamp.push_back(clamp_qpos_indices[i]);
			retargeter_ = retargeting::UpperBodyRetargeter::create(
					cfg, locked_qpos_prefix, "gmr", freeze_locked, clamp);
		} else if (s == "hand") {
			retargeter_ = retargeting::HandRetargeter::create(cfg);
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

PackedFloat64Array GMRRetargeter::run(const retargeting::SkeletonFrame &frame) {
	PackedFloat64Array out;
	if (!retargeter_) {
		last_error_ = "not configured";
		return out;
	}
	try {
		Eigen::VectorXd qpos = retargeter_->step(frame);
		out.resize(qpos.size());
		for (int i = 0; i < qpos.size(); ++i) {
			out.set(i, qpos[i]);
		}
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
		out.clear();
	}
	return out;
}

PackedFloat64Array GMRRetargeter::step() {
	return run(frame_);
}

PackedFloat64Array GMRRetargeter::step_frame(const Dictionary &frame) {
	retargeting::SkeletonFrame sf;
	Array keys = frame.keys();
	for (int i = 0; i < keys.size(); ++i) {
		String name = keys[i];
		Transform3D xform = frame[keys[i]];
		sf[std::string(name.utf8().get_data())] = pose_from_xform(xform);
	}
	return run(sf);
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

void GMRRetargeter::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "scenario", "robot_xml", "ik_config", "human_height", "locked_qpos_prefix", "freeze_locked", "clamp_qpos_indices"),
			&GMRRetargeter::configure, DEFVAL(1.75), DEFVAL(0), DEFVAL(false), DEFVAL(PackedInt32Array()));
	ClassDB::bind_method(D_METHOD("set_pose", "name", "xform"), &GMRRetargeter::set_pose);
	ClassDB::bind_method(D_METHOD("set_pose_pq", "name", "pos", "quat"), &GMRRetargeter::set_pose_pq);
	ClassDB::bind_method(D_METHOD("clear_frame"), &GMRRetargeter::clear_frame);
	ClassDB::bind_method(D_METHOD("step"), &GMRRetargeter::step);
	ClassDB::bind_method(D_METHOD("step_frame", "frame"), &GMRRetargeter::step_frame);
	ClassDB::bind_method(D_METHOD("is_configured"), &GMRRetargeter::is_configured);
	ClassDB::bind_method(D_METHOD("get_nq"), &GMRRetargeter::get_nq);
	ClassDB::bind_method(D_METHOD("get_scenario"), &GMRRetargeter::get_scenario);
	ClassDB::bind_method(D_METHOD("get_last_error"), &GMRRetargeter::get_last_error);
}
