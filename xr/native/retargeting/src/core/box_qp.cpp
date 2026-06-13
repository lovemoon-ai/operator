#include "box_qp.hpp"
#include <limits>
#include <vector>

namespace box_qp {

// Primal active-set method for strictly convex box-constrained QP.
// Finite termination given H positive definite.
Eigen::VectorXd solve(const Eigen::MatrixXd& H, const Eigen::VectorXd& c,
                      const Eigen::VectorXd& lb, const Eigen::VectorXd& ub) {
  const int n = static_cast<int>(c.size());
  const double kInf = std::numeric_limits<double>::infinity();
  const double kTol = 1e-12;

  // Feasible start: clip 0 into the box.
  Eigen::VectorXd x(n);
  for (int i = 0; i < n; ++i) {
    double v = 0.0;
    if (v < lb[i]) v = lb[i];
    if (v > ub[i]) v = ub[i];
    x[i] = v;
  }

  // active[i]: 0 = free, -1 = pinned at lower, +1 = pinned at upper.
  // Only permanently pin variables whose bounds coincide (lb == ub); set their
  // value exactly to the bound. We deliberately do NOT pre-pin variables merely
  // *near* a bound: doing so on a fuzzy tolerance leaves the variable stuck at
  // its starting value instead of the (possibly slightly different) bound,
  // introducing an error up to that tolerance. The line search below discovers
  // every active constraint exactly and snaps x onto the bound.
  std::vector<int> active(n, 0);
  for (int i = 0; i < n; ++i) {
    if (ub[i] <= lb[i]) {  // pinned (degenerate / equal bounds)
      active[i] = -1;
      x[i] = lb[i];
    }
  }

  const int kMaxIter = 4 * n + 50;
  for (int iter = 0; iter < kMaxIter; ++iter) {
    // Build free index set.
    std::vector<int> freeIdx;
    freeIdx.reserve(n);
    for (int i = 0; i < n; ++i)
      if (active[i] == 0) freeIdx.push_back(i);

    Eigen::VectorXd grad = H * x + c;  // gradient at x

    Eigen::VectorXd p = Eigen::VectorXd::Zero(n);
    if (!freeIdx.empty()) {
      const int nf = static_cast<int>(freeIdx.size());
      // Equality-constrained Newton step on the free block:
      //   H_FF p_F = -grad_F
      Eigen::MatrixXd Hff(nf, nf);
      Eigen::VectorXd gf(nf);
      for (int a = 0; a < nf; ++a) {
        gf[a] = grad[freeIdx[a]];
        for (int b = 0; b < nf; ++b) Hff(a, b) = H(freeIdx[a], freeIdx[b]);
      }
      Eigen::LLT<Eigen::MatrixXd> llt(Hff);
      Eigen::VectorXd pf = llt.solve(-gf);
      for (int a = 0; a < nf; ++a) p[freeIdx[a]] = pf[a];
    }

    double pnorm = p.lpNorm<Eigen::Infinity>();
    if (pnorm < 1e-12) {
      // Free variables optimal. Check KKT on active set; release the worst.
      int worst = -1;
      double worstVal = -1e-12;
      for (int i = 0; i < n; ++i) {
        if (active[i] == 0) continue;
        if (ub[i] - lb[i] <= kTol) continue;  // permanently pinned
        // Lagrange multiplier sign test. At lower bound need grad>=0; at upper
        // need grad<=0. Violation magnitude = how far into infeasible sign.
        double viol = (active[i] == -1) ? -grad[i] : grad[i];
        if (viol > worstVal) { worstVal = viol; worst = i; }
      }
      if (worst < 0) break;  // KKT satisfied -> optimal
      active[worst] = 0;     // release into free set
      continue;
    }

    // Max feasible step alpha in (0, 1] along p, keeping x in box.
    double alpha = 1.0;
    int blocking = -1;
    int blockingDir = 0;
    for (int i : freeIdx) {
      if (p[i] > kTol && ub[i] < kInf) {
        double a = (ub[i] - x[i]) / p[i];
        if (a < alpha) { alpha = a; blocking = i; blockingDir = 1; }
      } else if (p[i] < -kTol && lb[i] > -kInf) {
        double a = (lb[i] - x[i]) / p[i];
        if (a < alpha) { alpha = a; blocking = i; blockingDir = -1; }
      }
    }
    if (alpha < 0.0) alpha = 0.0;
    x += alpha * p;
    if (blocking >= 0 && alpha < 1.0 - 1e-15) {
      x[blocking] = (blockingDir == 1) ? ub[blocking] : lb[blocking];
      active[blocking] = blockingDir;
    }
  }
  return x;
}

}  // namespace box_qp
