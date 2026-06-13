// Abstract kinematics backend for the IK: forward kinematics, body-frame
// Jacobians, and configuration integration. Two implementations are provided:
//   - MujocoBackend   : uses libmujoco (mj_kinematics / mj_jacBody / mj_integratePos)
//   - PinocchioBackend: uses Pinocchio (forwardKinematics / getFrameJacobian)
//
// All quantities use the MuJoCo qpos convention (base = absolute world pose,
// quaternion wxyz at [3:7], hinge joints after). Frame poses are returned as
// wxyz_xyz[7] in the world frame; Jacobians are body-frame (LOCAL) 6 x nv, the
// convention mink's FrameTask expects.
#pragma once
#include <Eigen/Dense>
#include <string>
#include <vector>

class KinematicsBackend {
 public:
  // A limited single-DoF (hinge/slide) joint, for ConfigurationLimit bounds.
  struct LimitedDof {
    int qposadr;
    int dofadr;
    double lo;
    double hi;
  };

  virtual ~KinematicsBackend() = default;

  virtual int nq() const = 0;
  virtual int nv() const = 0;
  virtual double dt() const = 0;
  virtual Eigen::VectorXd qpos0() const = 0;

  // Resolve a robot body name to an opaque backend handle used by frame_*().
  virtual int body_handle(const std::string& name) const = 0;

  virtual const std::vector<LimitedDof>& limited_dofs() const = 0;

  // Set the configuration (MuJoCo-convention qpos) and run forward kinematics.
  virtual void set_qpos(const Eigen::VectorXd& qpos) = 0;

  // World pose of the body frame as wxyz_xyz[7].
  virtual void frame_pose(int handle, Eigen::Matrix<double, 7, 1>& out7) const = 0;

  // Body-frame (LOCAL) Jacobian, 6 x nv.
  virtual void frame_jacobian(int handle, Eigen::MatrixXd& jac6) const = 0;

  // Integrate qpos by tangent velocity v over dt (mj_integratePos semantics).
  virtual Eigen::VectorXd integrate(const Eigen::VectorXd& qpos,
                                    const Eigen::VectorXd& v, double dt) const = 0;
};
