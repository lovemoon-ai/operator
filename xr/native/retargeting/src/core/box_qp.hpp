// Box-constrained strictly-convex QP solver:
//   min 0.5 x^T H x + c^T x   s.t.  lb <= x <= ub
// H must be symmetric positive definite. Returns the unique minimizer.
//
// This replaces the daqp backend used by mink for this retargeting case, where
// every inequality reduces to a per-variable box bound (ConfigurationLimit rows
// are single-variable; FrozenTangentLimit fixes lower-body dofs to 0).
#pragma once
#include <Eigen/Dense>

namespace box_qp {

// Solve the box-constrained QP. lb/ub may contain +/- infinity for unbounded
// directions, and lb[i]==ub[i] is allowed (variable pinned).
Eigen::VectorXd solve(const Eigen::MatrixXd& H, const Eigen::VectorXd& c,
                      const Eigen::VectorXd& lb, const Eigen::VectorXd& ub);

}  // namespace box_qp
